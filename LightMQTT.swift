//
//  LightMQTT.swift
//

import Foundation

extension UInt16 {
    var lowByte: UInt8 {
        return UInt8(self & 0x00FF)
    }

    var highByte: UInt8 {
        return UInt8((self & 0xFF00) >> 8)
    }
}

final class LightMQTT {

    enum MQTTMessage: UInt8 {
        case connect = 0x10
        case connack = 0x20
        case publish = 0x30
        case puback = 0x40
        case pubrec = 0x50
        case pubrel = 0x60
        case pubcomp = 0x70
        case subscribe = 0x80
        case suback = 0x90
        case unsubscribe = 0xa0
        case unsuback = 0xb0
        case pingreq = 0xc0
        case pingresp = 0xd0
        case disconnect = 0xe0
    }

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
        disconnect()

        openStreams() { streams in
            guard let streams = streams else {
                completion?(false)
                return
            }

            self.inputStream = streams.input
            self.outputStream = streams.output

            DispatchQueue.global(qos: self.options.readQosClass).async {
                self.readStream(input: streams.input, output: streams.output)
            }

            self.mqttConnect(output: streams.output, keepalive: self.options.pingInterval)
            self.delayedPing(output: streams.output, interval: self.options.pingInterval)

            self.messageId = 0

            completion?(true)
        }
    }

    func disconnect() {
        if let output = outputStream {
            mqttDisconnect(output: output)
            closeStreams()
        }
    }

    func subscribe(to topic: String) {
        if let output = outputStream {
            mqttSubscribe(output: output, to: topic)
        }
    }

    func unsubscribe(from topic: String) {
        if let output = outputStream {
            mqttUnsubscribe(output: output, from: topic)
        }
    }

    func publish(to topic: String, message: Data?) {
        if let output = outputStream {
            mqttPublish(output: output, topic: topic, message: message ?? Data())
        }
    }

    // MARK: - Keep alive timer

    private func delayedPing(output: OutputStream, interval: UInt16) {
        let time = DispatchTime.now() + Double(interval / 2)
        DispatchQueue.main.asyncAfter(deadline: time) { [weak self] in
            if output.streamStatus != .open {
                return
            }

            self?.mqttPing(output: output)
            self?.delayedPing(output: output, interval: interval)
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
        var messageType: MQTTMessage = .connack

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

                if let message = MQTTMessage(rawValue: messageBuffer.pointee & 0xf0) {
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

    // MARK: - MQTT messages

    /**
     * |--------------------------------------
     * | 7 6 5 4 |     3    |  2 1  | 0      |
     * |  Type   | DUP flag |  QoS  | RETAIN |
     * |--------------------------------------
     */

    private func mqttConnect(output: OutputStream, keepalive: UInt16) {
        /**
         * |----------------------------------------------------------------------------------
         * |     7    |    6     |      5     |  4   3  |     2    |       1      |     0    |
         * | username | password | willretain | willqos | willflag | cleansession | reserved |
         * |----------------------------------------------------------------------------------
         */

        let clientId = options.concreteClientId

        var connectFlags: UInt8 = 0b00000010 // clean session

        var remainingLength: Int = 10 // initial 10 bytes
        remainingLength += (2 + clientId.utf8.count) // 2 byte client id length + codepoints

        if let username = options.username {
            connectFlags |= 0b10000000
            remainingLength += (2 + username.utf8.count) // 2 byte username length + codepoints
        }

        if let password = options.password {
            connectFlags |= 0b01000000
            remainingLength += (2 + password.utf8.count) // 2 byte password length + codepoints
        }

        let remainingLengthBytes = encodeVariableLength(remainingLength)

        let headerBytes: [UInt8] = [
            0x10] +                             // FIXED BYTE 1   1 = CONNECT, 0 = DUP QoS RETAIN, not used in CONNECT
            remainingLengthBytes +              // FIXED BYTE 2+  remaining length
        [   0x00,                               // VARIA BYTE 1   length MSB
            0x04,                               // VARIA BYTE 2   length LSB is 4
            0x4d,                               // VARIA BYTE 3   M
            0x51,                               // VARIA BYTE 4   Q
            0x54,                               // VARIA BYTE 5   T
            0x54,                               // VARIA BYTE 6   T
            0x04,                               // VARIA BYTE 7   Version = 4
            connectFlags,                       // VARIA BYTE 8   Username Password RETAIN QoS Will Clean flags
            keepalive.highByte,                 // VARIA BYTE 9   Keep Alive MSB
            keepalive.lowByte                   // VARIA BYTE 10  Keep Alive LSB
        ]

        var messageBytes = headerBytes + encode(string: clientId)

        if let username = options.username {
            messageBytes += encode(string: username)
        }

        if let password = options.password {
            messageBytes += encode(string: password)
        }

        output.write(messageBytes, maxLength: messageBytes.count)
    }

    private func mqttDisconnect(output: OutputStream) {
        let messageBytes: [UInt8] = [
            0xe0,                               // FIXED BYTE 1   e = DISCONNECT, 0 = DUP QoS RETAIN (not used)
            0x00                                // FIXED BYTE 2   remaining length = 0
        ]

        output.write(messageBytes, maxLength: messageBytes.count)
    }

    private func mqttSubscribe(output: OutputStream, to topic: String) {
        messageId += 1

        var remainingLength: Int = 3 // initial 3 bytes (messageID and QoS)
        remainingLength += (2 + topic.utf8.count) // 2 byte topic length + codepoints

        let remainingLengthBytes = encodeVariableLength(remainingLength)

        let headerBytes: [UInt8] = [
            0x82] +                             // FIXED BYTE 1   8 = SUBSCRIBE, 2 = DUP QoS RETAIN
            remainingLengthBytes +              // FIXED BYTE 2+  remaining length
        [   messageId.highByte,                 // VARIA BYTE 1   message id MSB
            messageId.lowByte                   // VARIA BYTE 2   message id LSB
        ]

        let requestedQosByte: [UInt8] = [
            0x00                                // Requested QoS
        ]

        let messageBytes = headerBytes + encode(string: topic) + requestedQosByte
        output.write(messageBytes, maxLength: messageBytes.count)
    }

    private func mqttUnsubscribe(output: OutputStream, from topic: String) {
        messageId += 1

        var remainingLength: Int = 2 // initial 2 bytes (messageID)
        remainingLength += (2 + topic.utf8.count) // 2 byte topic length + codepoints

        let remainingLengthBytes = encodeVariableLength(remainingLength)

        let headerBytes: [UInt8] = [
            0xa2] +                             // FIXED BYTE 1   a = UNSUBSCRIBE, 2 = DUP QoS RETAIN
            remainingLengthBytes +              // FIXED BYTE 2+  remaining length
        [   messageId.highByte,                 // VARIA BYTE 1   message id MSB
            messageId.lowByte                   // VARIA BYTE 2   message id LSB
        ]

        let messageBytes = headerBytes + encode(string: topic)
        output.write(messageBytes, maxLength: messageBytes.count)
    }

    // MQTT publish only handles QOS 0 for now
    private func mqttPublish(output: OutputStream, topic: String, message: Data) {
        messageId += 1

        // TODO: Add 2 (for messageId) if/when QOS > 0
        let remainingLengthBytes = encodeVariableLength(2 + topic.utf8.count + message.count)

        let headerBytes: [UInt8] = [
            0x30] +                             // FIXED BYTE 1   3 = PUBLISH, 0 = DUP QoS RETAIN
        remainingLengthBytes                    // remaining length, variable

        let messageBytes = headerBytes + encode(string: topic) + [UInt8](message)
        output.write(messageBytes, maxLength: messageBytes.count)
    }

    @objc private func mqttPing(output: OutputStream) {
        let messageBytes: [UInt8] = [
            0xc0,                               // FIXED BYTE 1   c = PINGREQ, 0 = DUP QoS RETAIN (not used)
            0x00                                // FIXED BYTE 2   remaining length = 0
        ]
        
        output.write(messageBytes, maxLength: messageBytes.count)
    }
    
    // MARK: - Utils
    
    private func encodeVariableLength(_ length: Int) -> [UInt8] {
        var remainingBytes: [UInt8] = []
        var workingLength = UInt(length)
        
        while workingLength > 0 {
            var byte = UInt8(workingLength & 0x7F)
            workingLength >>= 7
            if workingLength > 0 {
                byte |= 0x80
            }
            remainingBytes.append(byte)
        }
        
        return remainingBytes
    }
    
    private func encode(string: String) -> [UInt8] {
        // http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718016
        let encoded = string.utf8
        return [UInt16(encoded.count).highByte, UInt16(encoded.count).lowByte] + [UInt8](encoded)
    }
    
}
