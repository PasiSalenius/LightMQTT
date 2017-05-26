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

    var isConnected: Bool {
        return inputStream?.streamStatus == .open && outputStream?.streamStatus == .open
    }

    struct Options {
        var port: Int? = nil
        var pingInterval: UInt16 = 10
        var useTLS = false
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
    private var writeQueue = DispatchQueue(label: "mqtt_write")

    private var messageId: UInt16 = 0

    // MARK: - Public interface

    init(host: String, options: Options = Options()) {
        self.host = host
        self.options = options
    }

    deinit {
        disconnect()
    }

    func connect(completion: ((_ success: Bool) -> ())? = nil) {
        openStreams() { [weak self] streams in
            guard let strongSelf = self, let streams = streams else {
                completion?(false)
                return
            }

            strongSelf.disconnect()

            strongSelf.inputStream = streams.input
            strongSelf.outputStream = streams.output

            DispatchQueue.global(qos: strongSelf.options.readQosClass).async {
                strongSelf.readStream(input: streams.input, output: streams.output)
            }

            strongSelf.mqttConnect()
            strongSelf.delayedPing()

            strongSelf.messageId = 0

            completion?(true)
        }
    }

    func disconnect() {
        mqttDisconnect()
        closeStreams()
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
        let interval = options.pingInterval
        let time = DispatchTime.now() + Double(interval / 2)
        DispatchQueue.main.asyncAfter(deadline: time) { [weak self] in
            // stop pinging server if client deallocated or stream closed
            guard let output = self?.outputStream, output.streamStatus == .open else {
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
            input.setProperty(StreamSocketSecurityLevel.tlSv1, forKey: .socketSecurityLevelKey)
            output.setProperty(StreamSocketSecurityLevel.tlSv1, forKey: .socketSecurityLevelKey)
        }

        DispatchQueue.global(qos: .userInitiated).async {
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

    private func closeStreams() {
        inputStream?.close()
        outputStream?.close()

        inputStream = nil
        outputStream = nil
    }

    // MARK: - Stream reading

    private func readStream(input: InputStream, output: OutputStream) {
        var messageParserState: MQTTMessageParserState = .decodingHeader
        var messageType: PacketType = .connack

        var messageLengthMultiplier = 1
        var messageLength = 0

        let messageBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: options.bufferSize)
        var byteCount = 0

        defer {
            messageBuffer.deinitialize(count: options.bufferSize)
            messageBuffer.deallocate(capacity: options.bufferSize)
        }

        while input.streamStatus == .open {
            while messageParserState == .decodingHeader && input.streamStatus == .open {
                let count = input.read(messageBuffer, maxLength: 1)
                if count == 0 {
                    break
                } else if count < 0 {
                    return
                }

                if let message = PacketType(rawValue: messageBuffer.pointee & 0xf0) {
                    messageType = message
                    messageParserState = .decodingLength
                    messageLengthMultiplier = 1
                    messageLength = 0
                }
            }

            while messageParserState == .decodingLength && input.streamStatus == .open {
                let count = input.read(messageBuffer, maxLength: 1)
                if count == 0 {
                    break
                } else if count < 0 {
                    return
                }

                messageLength += Int(messageBuffer.pointee & 127) * messageLengthMultiplier
                if messageBuffer.pointee & 128 == 0x00 {
                    messageParserState = .decodingData
                    byteCount = 0
                } else {
                    messageLengthMultiplier *= 128
                }
            }

            while messageParserState == .decodingData && input.streamStatus == .open {
                switch messageType {
                case .publish:
                    guard messageLength > 0 else {
                        messageParserState = .decodingHeader
                        break
                    }

                    let bytesToRead = min(options.bufferSize - byteCount, messageLength - byteCount)
                    let count = input.read(messageBuffer.advanced(by: byteCount), maxLength: bytesToRead)
                    if count == 0 {
                        break
                    } else if count < 0 {
                        return
                    }

                    byteCount += count

                    if byteCount == options.bufferSize && byteCount < messageLength {
                        let drainBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
                        while byteCount < messageLength && input.streamStatus == .open {
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

                    if byteCount == messageLength {
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

                        if let closure = receivingBuffer {
                            closure(topic, pointer)
                        }

                        if let closure = receivingBytes {
                            closure(topic, Array(pointer))
                        }

                        if let closure = receivingData {
                            closure(topic, Data(bytesNoCopy: messageBuffer + topicLength + 2,
                                                count: byteCount - topicLength - 2,
                                                deallocator: .none))
                        }

                        messageParserState = .decodingHeader
                    }

                case .pingresp:
                    messageParserState = .decodingHeader

                case .suback:
                    messageParserState = .decodingHeader

                case .connack:
                    messageParserState = .decodingHeader

                case .unsuback:
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

    private func mqttDisconnect() {
        // http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718090

        let packet = ControlPacket(type: .disconnect)

        send(packet: packet)
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

    @objc private func mqttPing() {
        // http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718081

        let packet = ControlPacket(type: .pingreq)
        
        send(packet: packet)
    }

    private func send(packet: ControlPacket) {
        guard let output = outputStream else { return } 

        let serialized = packet.encoded
        var toSend = serialized.count
        var sent = 0

        writeQueue.sync {
            while toSend > 0 {
                let count = serialized.withUnsafeBytes {
                    output.write($0.advanced(by: sent), maxLength: toSend)
                }
                if count < 0 {
                    // print the output.error?
                    return
                }
                toSend -= count
                sent += count
            }
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
