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

    private var host: String?
    private var port: Int?

    private var pingInterval: UInt16 = 10
    private var useTLS = false
    private var username:String?
    private var password:String?

    private var inputStream: InputStream?
    private var outputStream: OutputStream?

    private var topicLength: Int?

    private var messageId: UInt16 = 0

    private static let BUFFER_SIZE: Int = 4096

    init?(host: String, port: Int, pingInterval: UInt16 = 10, useTLS: Bool = false, username:String? = nil, password:String? = nil) {
        self.host = host
        self.port = port

        self.pingInterval = pingInterval
        self.useTLS = useTLS
        self.username = username
        self.password = password
    }

    func connect() -> Bool {
        guard
            let host = host, let port = port
            else { return false }

        if inputStream != nil || outputStream != nil {
            return false
        }

        guard let (input, output) = openStreams(host: host, port: port) else {
            return false
        }

        inputStream = input
        outputStream = output

        mqttConnect(keepalive: pingInterval)
        delayedPing(outputStream: output, interval: pingInterval)

        messageId = 0

        return true
    }

    func disconnect() {
        mqttDisconnect()
        closeStreams()
    }

    deinit {
        disconnect()
    }

    // MARK: - Public interface

    func subscribe(to topic: String) {
        mqttSubscribe(to: topic)
    }

    func unsubscribe(from topic: String) {
        mqttUnsubscribe(from: topic)
    }

    func publish(to topic: String, message: Data?) {
        mqttPublish(topic: topic, message: message ?? Data())
    }

    // MARK: - Keep alive timer

    private func delayedPing(outputStream: OutputStream, interval: UInt16) {
        let time = DispatchTime.now() + Double(interval / 2)
        DispatchQueue.main.asyncAfter(deadline: time) { [weak self] in
            if outputStream.streamStatus != .open {
                return
            }

            self?.mqttPing(outputStream: outputStream)
            self?.delayedPing(outputStream: outputStream, interval: interval)
        }
    }

    // MARK: - Socket connection

    private func openStreams(host: String, port: Int) -> (inputStream: InputStream, outputStream: OutputStream)? {
        var inputStream: InputStream?
        var outputStream: OutputStream?

        Stream.getStreamsToHost(withName: host, port: port, inputStream: &inputStream, outputStream: &outputStream)

        guard let input = inputStream, let output = outputStream else {
            return nil
        }

        if useTLS {
            input.setProperty(StreamSocketSecurityLevel.tlSv1, forKey: .socketSecurityLevelKey)
            output.setProperty(StreamSocketSecurityLevel.tlSv1, forKey: .socketSecurityLevelKey)
        }

        input.open()
        output.open()

        while input.streamStatus == .opening || output.streamStatus == .opening {
            usleep(1000)
        }

        if input.streamStatus != .open || output.streamStatus != .open {
            return nil
        }

        DispatchQueue.global(qos: .background).async {
            self.readStream(inputStream: input, outputStream: output)
        }

        return (input, output)
    }

    private func closeStreams() {
        inputStream?.close()
        outputStream?.close()

        inputStream = nil
        outputStream = nil
    }

    // MARK: - Stream reading

    private func readStream(inputStream: InputStream, outputStream: OutputStream) {
        var messageParserState: MQTTMessageParserState = .decodingHeader
        var messageType: MQTTMessage = .connack

        var messageLengthMultiplier = 1
        var messageLength = 0

        let messageBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: LightMQTT.BUFFER_SIZE)
        var byteCount = 0

        defer {
            messageBuffer.deinitialize(count: LightMQTT.BUFFER_SIZE)
            messageBuffer.deallocate(capacity: LightMQTT.BUFFER_SIZE)
        }

        while inputStream.streamStatus == .open {
            while messageParserState == .decodingHeader && inputStream.streamStatus == .open {
                let count = inputStream.read(messageBuffer, maxLength: 1)
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

            while messageParserState == .decodingLength && inputStream.streamStatus == .open {
                let count = inputStream.read(messageBuffer, maxLength: 1)
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

            while messageParserState == .decodingData && inputStream.streamStatus == .open {
                switch messageType {
                case .publish:
                    guard messageLength > 0 else {
                        messageParserState = .decodingHeader
                        break
                    }

                    let bytesToRead = min(LightMQTT.BUFFER_SIZE, messageLength - byteCount)
                    let count = inputStream.read(messageBuffer.advanced(by: byteCount), maxLength: bytesToRead)
                    if count == 0 {
                        break
                    } else if count < 0 {
                        return
                    }

                    byteCount += count

                    if byteCount == messageLength {
                        let topicLength = Int(messageBuffer.pointee) * 256 + Int(messageBuffer.advanced(by: 1).pointee)
                        guard byteCount > topicLength + 2 else {
                            messageParserState = .decodingHeader
                            break
                        }

                        let topicPointer = UnsafeBufferPointer(start: messageBuffer + 2, count: topicLength)
                        guard let topic = String(bytes: topicPointer, encoding: String.Encoding.utf8) else {
                            messageParserState = .decodingHeader
                            break
                        }

                        let pointer = UnsafeBufferPointer(start: messageBuffer + topicLength + 2,
                                                          count: byteCount - topicLength - 2)

                        if let closure = receivingMessage, let message = String(bytes: pointer, encoding: String.Encoding.utf8) {
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

    private func mqttConnect(keepalive: UInt16) {
        let baseIntA = Int(arc4random() % 65535)
        let baseIntB = Int(arc4random() % 65535)
        let client = "client_" + String(format: "%04X%04X", baseIntA, baseIntB)

        /**
         * |----------------------------------------------------------------------------------
         * |     7    |    6     |      5     |  4   3  |     2    |       1      |     0    |
         * | username | password | willretain | willqos | willflag | cleansession | reserved |
         * |----------------------------------------------------------------------------------
         */

        var remainingLength:Int = 10 // initial 10 bytes
        remainingLength += (2 + client.utf8.count) // 2 byte client id length + codepoints
        var connectFlags:UInt8 = 0b00000010 // clean session
        if let username = self.username {
            connectFlags |= 0b10000000
            remainingLength += (2 + username.utf8.count) // 2 byte username length + codepoints
        }
        if let password = self.password {
            connectFlags |= 0b01000000
            remainingLength += (2 + password.utf8.count) // 2 byte password length + codepoints
        }
        let remainingLengthBytes = encodeVariableLength(UInt(remainingLength))

        let headerBytes: [UInt8] = [
            0x10] +                             // FIXED BYTE 1   1 = CONNECT, 0 = DUP QoS RETAIN, not used in CONNECT
         remainingLengthBytes +                 // FIXED BYTE 2+   remaining length
         [
            0x00,                               // VARIA BYTE 1   length MSB
            0x04,                               // VARIA BYTE 2   length LSB is 4
            0x4d,                               // VARIA BYTE 3   M
            0x51,                               // VARIA BYTE 4   Q
            0x54,                               // VARIA BYTE 5   T
            0x54,                               // VARIA BYTE 6   T
            0x04,                               // VARIA BYTE 7   Version = 4
            0x02,                               // VARIA BYTE 8   Username Password RETAIN QoS Will Clean flags
            keepalive.highByte,                 // VARIA BYTE 9   Keep Alive MSB
            keepalive.lowByte                   // VARIA BYTE 10  Keep Alive LSB
        ]

        var messageBytes = headerBytes + encodeUTF8Length(client) + [UInt8](client.utf8)
        if let username = self.username {
            messageBytes += (encodeUTF8Length(username) + [UInt8](username.utf8))
        }
        if let password = self.password {
            messageBytes += (encodeUTF8Length(password) + [UInt8](password.utf8))
        }
        outputStream?.write(messageBytes, maxLength: messageBytes.count)
    }

    private func mqttDisconnect() {
        let messageBytes: [UInt8] = [
            0xe0,                               // FIXED BYTE 1   e = DISCONNECT, 0 = DUP QoS RETAIN (not used)
            0x00                                // FIXED BYTE 2   remaining length = 0
        ]

        outputStream?.write(messageBytes, maxLength: messageBytes.count)
    }

    private func mqttSubscribe(to topic: String) {
        messageId += 1

        let subscribeBytes: [UInt8] = [
            0x82,                               // FIXED BYTE 1   8 = SUBSCRIBE, 2 = DUP QoS RETAIN
            UInt8(topic.utf8.count + 5),        // FIXED BYTE 2   remaining length, msg id + topic length + topic
            messageId.highByte,                 // VARIA BYTE 1   message id MSB
            messageId.lowByte,                  // VARIA BYTE 2   message id LSB
            UInt16(topic.utf8.count).highByte,  // VARIA BYTE 3   topic length MSB
            UInt16(topic.utf8.count).lowByte    // VARIA BYTE 4   topic length LSB
        ]

        let requestedQosByte: [UInt8] = [
            0x00                                // Requested QoS
        ]

        let messageBytes = subscribeBytes + [UInt8](topic.utf8) + requestedQosByte
        outputStream?.write(messageBytes, maxLength: messageBytes.count)
    }

    private func mqttUnsubscribe(from topic: String) {
        messageId += 1

        let unsubscribeBytes: [UInt8] = [
            0xa2,                               // FIXED BYTE 1   a = UNSUBSCRIBE, 2 = DUP QoS RETAIN
            UInt8(topic.utf8.count + 4),        // FIXED BYTE 2   remaining length, topic id length + 4
            messageId.highByte,                 // VARIA BYTE 1   message id MSB
            messageId.lowByte,                  // VARIA BYTE 2   message id LSB
            UInt16(topic.utf8.count).highByte,  // VARIA BYTE 3   topic length MSB
            UInt16(topic.utf8.count).lowByte    // VARIA BYTE 4   topic length LSB
        ]

        let messageBytes = unsubscribeBytes + [UInt8](topic.utf8)
        outputStream?.write(messageBytes, maxLength: messageBytes.count)
    }

    // MQTT publish only handles QOS 0 for now
    private func mqttPublish(topic: String, message: Data) {
        messageId += 1

        // TODO: Add 2 (for messageId) if/when QOS > 0
        let remainingLengthBytes = encodeVariableLength(UInt(2 + topic.utf8.count + message.count))

        let publishBytes: [UInt8] = [
            0x30] +                             // FIXED BYTE 1   3 = PUBLISH, 0 = DUP QoS RETAIN

        remainingLengthBytes +                  // remaining length, variable

        [UInt16(topic.utf8.count).highByte,     // topic length MSB
            UInt16(topic.utf8.count).lowByte    // topic length LSB
        ]
        
        let messageBytes = publishBytes + [UInt8](topic.utf8) + [UInt8](message)
        outputStream?.write(messageBytes, maxLength: messageBytes.count)
    }
    
    @objc private func mqttPing(outputStream: OutputStream) {
        let messageBytes: [UInt8] = [
            0xc0,                               // FIXED BYTE 1   c = PINGREQ, 0 = DUP QoS RETAIN (not used)
            0x00                                // FIXED BYTE 2   remaining length = 0
        ]
        
        outputStream.write(messageBytes, maxLength: messageBytes.count)
    }

    // MARK: - Utils

    private func encodeVariableLength(_ length: UInt) -> [UInt8] {
        var remainingBytes: [UInt8] = []
        var workingLength = length

        while workingLength > 0 {
            var byte = UInt8(workingLength & 0x7F)
            workingLength >>= 7
            if workingLength > 0 {
                byte &= 0x80
            }
            remainingBytes.append(byte)
        }

        return remainingBytes
    }

    private func encodeUTF8Length(_ string:String) -> [UInt8] {
        return [UInt16(string.utf8.count).highByte, UInt16(string.utf8.count).lowByte]

    }

}
