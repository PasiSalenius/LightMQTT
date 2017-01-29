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

private let MQTT_BUFFER_SIZE: Int = 4096

final class LightMQTT: NSObject, StreamDelegate {

    var host: String?
    var port: Int?

    var pingInterval: UInt16 = 10

    var receivingMessage: ((_ topic: String, _ message: String) -> ())?
    var receivingBuffer: ((_ topic: String, _ buffer: UnsafeBufferPointer<UTF8.CodeUnit>) -> ())?
    var receivingBytes: ((_ topic: String, _ bytes: [UTF8.CodeUnit]) -> ())?
    var receivingData: ((_ topic: String, _ data: Data) -> ())?

    fileprivate var inputStream: InputStream?
    fileprivate var outputStream: OutputStream?

    fileprivate var serialQueue: DispatchQueue?

    fileprivate var messageBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: MQTT_BUFFER_SIZE)
    fileprivate var byteCount = 0

    fileprivate var messageParserState = MQTTMessageParserState.decodingHeader
    fileprivate var messageType = MQTTMessage.connack

    fileprivate var messageLengthMultiplier = 1
    fileprivate var messageLength = 0

    fileprivate var topicLength: Int?

    fileprivate var messageId: UInt16 = 0

    init?(host: String, port: Int, pingInterval: UInt16 = 10) {
        super.init()

        self.host = host
        self.port = port

        self.pingInterval = pingInterval
    }

    func connect() -> Bool {
        guard let host = host, let port = port else {
            return false
        }

        if connectSocket(host: host, port: port) {
            clearMessageParserState()
            messageId = 0

            mqttConnect(keepalive: pingInterval)
            delayedPing(interval: pingInterval)
            
            return true

        } else {
            return false
        }
    }

    func disconnect() {
        mqttDisconnect()
        disconnectSocket()
    }

    deinit {
        disconnect()

        messageBuffer.deinitialize(count: MQTT_BUFFER_SIZE)
        messageBuffer.deallocate(capacity: MQTT_BUFFER_SIZE)
    }

    // MARK: - Public interface

    func subscribe(to topic: String) {
        mqttSubscribe(to: topic)
    }

    func unsubscribe(from topic: String) {
        mqttUnsubscribe(from: topic)
    }

    // MARK: - MQTT messages

    /**
     * |--------------------------------------
     * | 7 6 5 4 |     3    |  2 1  | 0      |
     * |  Type   | DUP flag |  QoS  | RETAIN |
     * |--------------------------------------
     */

    fileprivate func mqttConnect(keepalive: UInt16) {
        let baseIntA = Int(arc4random() % 65535)
        let baseIntB = Int(arc4random() % 65535)
        let client = "client_" + String(format: "%04X%04X", baseIntA, baseIntB)

        /**
         * |----------------------------------------------------------------------------------
         * |     7    |    6     |      5     |  4   3  |     2    |       1      |     0    |
         * | username | password | willretain | willqos | willflag | cleansession | reserved |
         * |----------------------------------------------------------------------------------
         */

        let connectBytes: [UInt8] = [
            0x10,                               // FIXED BYTE 1   1 = CONNECT, 0 = DUP QoS RETAIN, not used in CONNECT
            UInt8(client.utf8.count + 12),      // FIXED BYTE 2   remaining length, client id length + 12
            0x00,                               // VARIA BYTE 1   length MSB
            0x04,                               // VARIA BYTE 2   length LSB is 4
            0x4d,                               // VARIA BYTE 3   M
            0x51,                               // VARIA BYTE 4   Q
            0x54,                               // VARIA BYTE 5   T
            0x54,                               // VARIA BYTE 6   T
            0x04,                               // VARIA BYTE 7   Version = 4
            0x02,                               // VARIA BYTE 8   Username Password RETAIN QoS Will Clean flags
            keepalive.highByte,                 // VARIA BYTE 9   Keep Alive MSB
            keepalive.lowByte,                  // VARIA BYTE 10  Keep Alive LSB
            UInt16(client.utf8.count).highByte, // VARIA BYTE 11  client id length MSB
            UInt16(client.utf8.count).lowByte   // VARIA BYTE 12  client id length LSB
        ]

        let messageBytes = connectBytes + [UInt8](client.utf8)
        outputStream?.write(messageBytes, maxLength: messageBytes.count)
    }

    fileprivate func mqttDisconnect() {
        let messageBytes: [UInt8] = [
            0xe0,                               // FIXED BYTE 1   e = DISCONNECT, 0 = DUP QoS RETAIN (not used)
            0x00                                // FIXED BYTE 2   remaining length = 0
        ]

        outputStream?.write(messageBytes, maxLength: messageBytes.count)
    }
    
    fileprivate func mqttSubscribe(to topic: String) {
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

    fileprivate func mqttUnsubscribe(from topic: String) {
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

    @objc fileprivate func mqttPing() {
        let messageBytes: [UInt8] = [
            0xc0,                               // FIXED BYTE 1   c = PINGREQ, 0 = DUP QoS RETAIN (not used)
            0x00                                // FIXED BYTE 2   remaining length = 0
        ]

        outputStream?.write(messageBytes, maxLength: messageBytes.count)
    }

    // MARK: - Keep alive timer

    fileprivate func delayedPing(interval: UInt16) {
        let delayTime = DispatchTime.now() + Double(interval / 2)
        DispatchQueue.main.asyncAfter(deadline: delayTime) { [weak self] in
            guard let _ = self?.outputStream else { return }

            self?.mqttPing()
            self?.delayedPing(interval: interval)
        }
    }

    // MARK: - Socket connection

    fileprivate func connectSocket(host: String, port: Int) -> Bool {
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &inputStream, outputStream: &outputStream)

        if inputStream == nil || outputStream == nil { return false }

        serialQueue = DispatchQueue(label: "readQueue", qos: .background, target: nil)

        inputStream?.delegate = self
        outputStream?.delegate = self

        inputStream?.open()
        outputStream?.open()

        inputStream?.schedule(in: .current, forMode: .defaultRunLoopMode)
        outputStream?.schedule(in: .current, forMode: .defaultRunLoopMode)

        return true
    }

    fileprivate func disconnectSocket() {
        inputStream?.remove(from: .current, forMode: .defaultRunLoopMode)
        outputStream?.remove(from: .current, forMode: .defaultRunLoopMode)

        inputStream?.close()
        outputStream?.close()

        inputStream?.delegate = nil
        outputStream?.delegate = nil

        inputStream = nil
        outputStream = nil

        serialQueue = nil
    }

    // MARK: - Stream delegate

    @objc internal func stream(_ stream: Stream, handle eventCode: Stream.Event) {
        switch stream {
        case let val where val == inputStream:
            switch (eventCode) {
            case Stream.Event.hasBytesAvailable:
                serialQueue?.async { [weak self] in
                    self?.read(stream: stream)
                }

            case Stream.Event.openCompleted:
                messageParserState = .decodingHeader
            case Stream.Event.errorOccurred:
                break
            case Stream.Event.endEncountered:
                break
            case Stream.Event():
                break
            default:
                break
            }

        default:
            break
        }
    }

    fileprivate func read(stream: Stream) {
        guard
            let inputStream = inputStream, inputStream == stream
            else { return }

        if messageParserState == .decodingHeader {
            if inputStream.read(messageBuffer, maxLength: 1) > 0 {
                if let message = MQTTMessage(rawValue: messageBuffer.pointee & 0xf0) {
                    messageType = message
                    messageParserState = .decodingLength
                }
            }
        }

        while messageParserState == .decodingLength {
            if inputStream.read(messageBuffer, maxLength: 1) == 0 {
                break
            }

            messageLength += Int(messageBuffer.pointee & 127) * messageLengthMultiplier
            if messageBuffer.pointee & 128 == 0x00 {
                messageParserState = .decodingData
            } else {
                messageLengthMultiplier *= 128
            }
        }

        if messageParserState == .decodingData {
            guard messageLength > 0 else {
                clearMessageParserState()
                return
            }

            let bytesToRead = min(MQTT_BUFFER_SIZE, messageLength - byteCount)
            byteCount += inputStream.read(messageBuffer.advanced(by: byteCount), maxLength: bytesToRead)

            if byteCount == messageLength {
                switch messageType {
                case .publish:
                    let topicLength = Int(messageBuffer.pointee) * 256 + Int(messageBuffer.advanced(by: 1).pointee)
                    let topicPointer = UnsafeBufferPointer(start: messageBuffer + 2, count: topicLength)
                    guard let topic = String(bytes: topicPointer, encoding: String.Encoding.utf8) else {
                        break
                    }

                    let pointer = UnsafeBufferPointer(start: messageBuffer + topicLength + 2,
                                                      count: byteCount - topicLength - 2)

                    if  let closure = receivingMessage,
                        let message = String(bytes: pointer, encoding: String.Encoding.utf8) {
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

                default:
                    break
                }

                clearMessageParserState()
            }
        }
    }

    // MARK: - Housekeeping

    fileprivate func clearMessageParserState() {
        byteCount = 0
        messageLength = 0
        messageLengthMultiplier = 1

        messageParserState = .decodingHeader
    }
}
