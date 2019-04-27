//
//  LightMQTT.swift
//

import Foundation

fileprivate enum PacketType: UInt8 {
    // http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718021
    case connect =     0x10
    case connack =     0x20
    case publish =     0x30
    case puback =      0x40
    case pubrec =      0x50
    case pubrel =      0x60
    case pubcomp =     0x70
    case subscribe =   0x80
    case suback =      0x90
    case unsubscribe = 0xa0
    case unsuback =    0xb0
    case pingreq =     0xc0
    case pingresp =    0xd0
    case disconnect =  0xe0
}

fileprivate enum PacketFlags: UInt8 {
    // http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718022
    case dup =           0b0000_1000
    case mostOnce =      0b0000_0000
    case leastOnce =     0b0000_0010
    case justOnce =      0b0000_0100
    case retain =        0b0000_0001
}

final class LightMQTT {
    
    enum MQTTMessageParserState {
        case decodingHeader
        case decodingLength
        case decodingData
    }
    
    var receivingMessage: ((_ topic: String, _ message: String) -> ())?
    var receivingBuffer: ((_ topic: String, _ buffer: UnsafeBufferPointer<UTF8.CodeUnit>) -> ())?
    var receivingBytes: ((_ topic: String, _ bytes: [UTF8.CodeUnit]) -> ())?
    var receivingData: ((_ topic: String, _ data: Data) -> ())?
    
    struct Options {
        var port: Int? = nil
        var pingInterval: UInt16 = 10
        var useTLS = false
        var securityLevel = StreamSocketSecurityLevel.tlSv1
        var networkServiceType = StreamNetworkServiceTypeValue.background
        var username: String? = nil
        var password: String? = nil
        var clientId: String? = nil
        var bufferSize: Int = 4096
        var readQosClass: DispatchQoS.QoSClass = .background
        
        var concretePort: Int {
            return port ?? (useTLS ? 8883 : 1883)
        }
        
        fileprivate var concreteClientId: String {
            var result = clientId ?? "%%%%"
            while let range = result.range(of: "%") {
                let hexNibbles = String(format: "%02X", Int(arc4random() & 0xFF))
                result.replaceSubrange(range, with: hexNibbles)
            }
            return result
        }
    }
    
    private var options: Options
    private var host: String
    
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var writeQueue = DispatchQueue(label: "mqtt_write", qos: .default)
    
    private var messageId: UInt16 = 0
    
    // MARK: - Public interface
    
    init(host: String, options: Options = Options()) {
        self.host = host
        self.options = options
    }
    
    deinit {
        disconnect()
    }
    
    var isConnected: Bool {
        if let input = inputStream, input.isConnected, let output = outputStream, output.isConnected {
            return true
        }
        
        return false
    }
    
    func connect(completion: ((_ success: Bool) -> ())? = nil) {
        openStreams() { [weak self] streams in
            guard let s = self, let streams = streams else {
                completion?(false)
                return
            }
            
            if s.isConnected {
                completion?(false)
                return
            }
            
            s.inputStream = streams.input
            s.outputStream = streams.output
            
            DispatchQueue.global(qos: s.options.readQosClass).async {
                s.readStream(input: streams.input)
                s.disconnect(streams: streams)
            }
            
            s.mqttConnect()
            s.delayedPing()
            
            s.messageId = 0
            
            completion?(true)
        }
    }
    
    func disconnect(streams: (input: InputStream, output: OutputStream)? = nil) {
        if let streams = streams {
            mqttDisconnect() { [weak self] success in
                self?.closeStreams(streams)
            }
            
        } else if let input = inputStream, let output = outputStream {
            mqttDisconnect() { [weak self] success in
                self?.closeStreams((input, output))
            }
        }
    }
    
    func subscribe(to topic: String) {
        mqttSubscribe(to: topic)
    }
    
    func unsubscribe(from topic: String) {
        mqttUnsubscribe(from: topic)
    }
    
    func publish(to topic: String, message: Data?) {
        mqttPublish(to: topic, message: message ?? Data())
    }
    
    // MARK: - Keep alive timer
    
    private func delayedPing() {
        let deadline = DispatchTime.now() + .seconds(Int(options.pingInterval / 2))
        DispatchQueue.global(qos: .default).asyncAfter(deadline: deadline) { [weak self] in
            // stop pinging server if client deallocated or stream closed
            guard let output = self?.outputStream, output.isConnected else {
                return
            }
            
            self?.mqttPing()
            self?.delayedPing()
        }
    }
    
    // MARK: - Socket connection
    
    private func openStreams(completion: @escaping (((input: InputStream, output: OutputStream)?) -> ())) {
        var inputStream: InputStream?
        var outputStream: OutputStream?
        
        Stream.getStreamsToHost(withName: host,
                                port: options.concretePort,
                                inputStream: &inputStream,
                                outputStream: &outputStream)
        
        guard let input = inputStream, let output = outputStream else {
            completion(nil)
            return
        }
        
        if options.useTLS {
            input.setProperty(options.securityLevel, forKey: .socketSecurityLevelKey)
            output.setProperty(options.securityLevel, forKey: .socketSecurityLevelKey)
        }
        
        input.setProperty(options.networkServiceType, forKey: .networkServiceType)
        output.setProperty(options.networkServiceType, forKey: .networkServiceType)

        DispatchQueue.global(qos: .default).async {
            input.open()
            output.open()
            
            while input.streamStatus == .opening || output.streamStatus == .opening {
                usleep(1000)
            }
            
            if input.streamStatus != .open || output.streamStatus != .open {
                completion(nil)
                return
            }
            
            completion((input, output))
        }
    }
    
    private func closeStreams(_ streams: (input: InputStream, output: OutputStream)) {
        streams.input.close()
        streams.output.close()
    }
    
    // MARK: - Stream reading
    
    private func readStream(input: InputStream) {
        var messageParserState: MQTTMessageParserState = .decodingHeader
        var messageType: PacketType = .connack
        
        var messageLengthMultiplier = 1
        var messageLength = 0
        
        let messageBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: options.bufferSize)
        var byteCount = 0
        
        defer {
            messageBuffer.deinitialize(count: options.bufferSize)
            messageBuffer.deallocate()
        }
        
        while input.isConnected {
            while messageParserState == .decodingHeader && input.isConnected {
                if !input.hasBytesAvailable {
                    usleep(1000)
                    continue
                }
                
                let count = input.read(messageBuffer, maxLength: 1)
                if count <= 0 {
                    return
                }
                
                if let message = PacketType(rawValue: messageBuffer.pointee & 0xf0) {
                    messageType = message
                    messageParserState = .decodingLength
                    messageLengthMultiplier = 1
                    messageLength = 0
                }
            }
            
            while messageParserState == .decodingLength && input.isConnected {
                if !input.hasBytesAvailable {
                    usleep(1000)
                    continue
                }
                
                let count = input.read(messageBuffer, maxLength: 1)
                if count <= 0 {
                    return
                }
                
                messageLength += Int(messageBuffer.pointee & 127) * messageLengthMultiplier
                if messageBuffer.pointee & 128 == 0x00 {
                    if messageLength > 0 {
                        messageParserState = .decodingData
                        byteCount = 0
                    } else {
                        messageParserState = .decodingHeader
                    }
                    
                } else {
                    messageLengthMultiplier *= 128
                }
            }
            
            while messageParserState == .decodingData && input.isConnected {
                if !input.hasBytesAvailable {
                    usleep(1000)
                    continue
                }
                
                let bytesToRead = min(options.bufferSize - byteCount, messageLength - byteCount)
                let count = input.read(messageBuffer.advanced(by: byteCount), maxLength: bytesToRead)
                if count <= 0 {
                    return
                }
                
                byteCount += count
                
                if byteCount == options.bufferSize && byteCount < messageLength {
                    let drainBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
                    while byteCount < messageLength && input.isConnected {
                        let count = input.read(drainBuffer, maxLength: min(1024, messageLength - byteCount))
                        if count > 0 {
                            byteCount += count
                        } else {
                            break
                        }
                    }
                    
                    messageParserState = .decodingHeader
                    break
                }
                
                if byteCount < messageLength {
                    continue
                }
                
                switch messageType {
                case .publish:
                    let topicLength = Int(messageBuffer.pointee) * 256 + Int(messageBuffer.advanced(by: 1).pointee)
                    guard byteCount > topicLength + 2 else {
                        messageParserState = .decodingHeader
                        break
                    }
                    
                    let topicPointer = UnsafeBufferPointer(start: messageBuffer + 2, count: topicLength)
                    guard let topic = String(bytes: topicPointer, encoding: .utf8) else {
                        messageParserState = .decodingHeader
                        break
                    }
                    
                    let pointer = UnsafeBufferPointer(start: messageBuffer + topicLength + 2,
                                                      count: byteCount - topicLength - 2)
                    
                    if let closure = receivingMessage, let message = String(bytes: pointer, encoding: .utf8) {
                        closure(topic, message)
                    }
                    
                    receivingBuffer?(topic, pointer)
                    
                    receivingBytes?(topic, Array(pointer))
                    
                    receivingData?(topic, Data(bytesNoCopy: messageBuffer + topicLength + 2,
                                               count: byteCount - topicLength - 2,
                                               deallocator: .none))
                    
                    messageParserState = .decodingHeader
                    
                case .connack:
                    messageParserState = .decodingHeader
                case .suback:
                    messageParserState = .decodingHeader
                case .unsuback:
                    messageParserState = .decodingHeader
                case .pingresp:
                    messageParserState = .decodingHeader
                default:
                    messageParserState = .decodingHeader
                }
            }
        }
    }
    
    private func nextMessageId() -> UInt16 {
        messageId = messageId &+ 1
        return messageId
    }
    
    // MARK: - MQTT messages
    
    /**
     * |--------------------------------------
     * | 7 6 5 4 |     3    |  2 1  | 0      |
     * |  Type   | DUP flag |  QoS  | RETAIN |
     * |--------------------------------------
     */
    
    private func mqttConnect() {
        // http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718028
        
        var packet = ControlPacket(type: .connect)
        packet.payload += options.concreteClientId
        
        // section 3.1.2.3
        var connectFlags: UInt8 = 0b00000010 // clean session
        
        if let username = options.username {
            connectFlags |= 0b10000000
            packet.payload += username
        }
        
        if let password = options.password {
            connectFlags |= 0b01000000
            packet.payload += password
        }
        
        packet.variableHeader += "MQTT"            // section 3.1.2.1
        packet.variableHeader += UInt8(0b00000100) // section 3.1.2.2
        packet.variableHeader += connectFlags
        packet.variableHeader += options.pingInterval // section 3.1.2.10
        
        send(packet: packet)
    }
    
    private func mqttDisconnect(completion: ((_ success: Bool) -> ())? = nil) {
        // http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718090
        
        let packet = ControlPacket(type: .disconnect)
        
        send(packet: packet) { success in
            completion?(success)
        }
    }
    
    private func mqttSubscribe(to topic: String) {
        // http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718063
        
        var packet = ControlPacket(type: .subscribe, flags: .leastOnce)
        packet.variableHeader += nextMessageId()
        packet.payload += topic    // section 3.8.3
        packet.payload += UInt8(0) // QoS = 0
        
        send(packet: packet)
    }
    
    private func mqttUnsubscribe(from topic: String) {
        // http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718072
        
        var packet = ControlPacket(type: .unsubscribe, flags: .leastOnce)
        packet.variableHeader += nextMessageId()
        packet.payload += topic
        
        send(packet: packet)
    }
    
    // MQTT publish only handles QOS 0 for now
    private func mqttPublish(to topic: String, message: Data) {
        // http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718037
        
        var packet = ControlPacket(type: .publish, flags: .mostOnce)
        packet.variableHeader += topic // section 3.3.2
        // TODO: Add 2 (for messageId) if/when QOS > 0
        packet.payload += message      // section 3.3.3
        
        send(packet: packet)
    }
    
    private func mqttPing() {
        // http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718081
        
        let packet = ControlPacket(type: .pingreq)
        
        send(packet: packet)
    }
    
    private func send(packet: ControlPacket, completion: ((_ success: Bool) -> ())? = nil) {
        guard let output = outputStream else { return }
        
        let serialized = packet.encoded
        var toSend = serialized.count
        var sent = 0
        
        writeQueue.async {
            while toSend > 0 {
                if !output.isConnected {
                    completion?(false)
                    return
                }
                
                let count = serialized.withUnsafeBytes {
                    output.write($0.advanced(by: sent), maxLength: toSend)
                }
                if count == 0 {
                    usleep(1000)
                } else if count < 0 {
                    completion?(false)
                    return
                }
                
                toSend -= count
                sent += count
            }
            
            completion?(true)
        }
    }
}

fileprivate struct AppendableData {
    var data = Data()
    
    static func += (block: inout AppendableData, byte: UInt8) {
        block.data.append(byte)
    }
    
    static func += (block: inout AppendableData, short: UInt16) {
        block += UInt8(short >> 8)
        block += UInt8(short & 0xFF)
    }
    
    static func += (block: inout AppendableData, data: Data) {
        block.data += data
    }
    
    static func += (block: inout AppendableData, string: String) {
        block += UInt16(string.utf8.count)
        block += string.data(using: .utf8)!
    }
}

fileprivate struct ControlPacket {
    var type: PacketType
    var flags: PacketFlags
    var variableHeader = AppendableData()
    var payload = AppendableData()
    
    var remainingLength: Data {
        // http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718023
        var workingLength = UInt(variableHeader.data.count + payload.data.count)
        var encoded = Data()
        
        while true {
            var byte = UInt8(workingLength & 0x7F)
            workingLength >>= 7
            if workingLength > 0 {
                byte |= 0x80
            }
            encoded.append(byte)
            if workingLength == 0 {
                return encoded
            }
        }
    }
    
    var encoded: Data {
        var bytes = Data()
        bytes.append(type.rawValue | flags.rawValue)
        bytes += remainingLength
        bytes += variableHeader.data
        bytes += payload.data
        return bytes
    }
    
    init(type: PacketType, flags: PacketFlags = .mostOnce) {
        self.type = type
        self.flags = flags
    }
}

fileprivate extension Stream {
    var isConnected: Bool {
        switch streamStatus {
        case .notOpen, .opening, .closed, .error, .atEnd:
            return false
        default:
            return true
        }
    }
}
