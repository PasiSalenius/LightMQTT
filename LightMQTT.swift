//
//  LightMQTT.swift
//

import Foundation

enum MQTTMessage : UInt8 {
    case CONNECT = 0x10
    case CONNACK = 0x20
    case PUBLISH = 0x30
    case PUBACK = 0x40
    case PUBREC = 0x50
    case PUBREL = 0x60
    case PUBCOMP = 0x70
    case SUBSCRIBE = 0x80
    case SUBACK = 0x90
    case UNSUBSCRIBE = 0xa0
    case UNSUBACK = 0xb0
    case PINGREQ = 0xc0
    case PINGRESP = 0xd0
    case DISCONNECT = 0xe0
}

enum MQTTClientState {
    case ConnectionClosed
    case Initializing
    case DecodingHeader
    case DecodingLength
    case DecodingData
    case ConnectionError
}

protocol LightMQTTDelegate {
    func didReceiveMessage(topic: String, message: String)
}

final class LightMQTT: NSObject, NSStreamDelegate {

    private var clientState = MQTTClientState.ConnectionClosed

    private var inputStream: NSInputStream?
    private var outputStream: NSOutputStream?

    private var readBuffer = [UInt8](count: MQTT_BUFFER_SIZE, repeatedValue: 0)

    private var messageBuffer: [UInt8] = []

    private var messageLength = 0
    private var messageLengthMultiplier = 1

    private var topicLength: Int?

    private var keepAliveTimer: NSTimer?

    var delegate: LightMQTTDelegate?

    // MARK: - Keep alive timer

    func beginKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = NSTimer.scheduledTimerWithTimeInterval(
            Double(MQTT_KEEPALIVE) / 2.0,
            target: self,
            selector: "ping",
            userInfo: nil,
            repeats: true)
    }

    func endKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    // MARK: - Socket connection

    func connectSocket(host: String, port: Int) {
        NSStream.getStreamsToHostWithName(host, port: port, inputStream: &inputStream, outputStream: &outputStream)

        inputStream?.delegate = self
        outputStream?.delegate = self

        inputStream?.open()
        outputStream?.open()

        inputStream?.scheduleInRunLoop(.mainRunLoop(), forMode: NSDefaultRunLoopMode)
        outputStream?.scheduleInRunLoop(.mainRunLoop(), forMode: NSDefaultRunLoopMode)
    }

    func disconnectSocket() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil

        inputStream?.removeFromRunLoop(.mainRunLoop(), forMode: NSDefaultRunLoopMode)
        outputStream?.removeFromRunLoop(.mainRunLoop(), forMode: NSDefaultRunLoopMode)

        inputStream?.close()
        outputStream?.close()

        inputStream?.delegate = nil
        outputStream?.delegate = nil

        inputStream = nil;
        outputStream = nil;
    }

    // MARK: - MQTT messages

    func connect() {
        let baseIntA = Int(arc4random() % 65535)
        let baseIntB = Int(arc4random() % 65535)
        let clientId = "transporter_" + String(format: "%04X%04X", baseIntA, baseIntB)

        let connectBytes: [UInt8] = [
            0x10,                               // FIXED BYTE 1   1 = CONNECT, 0 = DUP QoS RETAIN, not used in CONNECT
            UInt8(clientId.utf8.count + 12),    // FIXED BYTE 2   remaining length, client id length + 12
            0x00,                               // VARIA BYTE 1   length MSB
            0x04,                               // VARIA BYTE 2   length LSB is 4
            0x4d,                               // VARIA BYTE 3   M
            0x51,                               // VARIA BYTE 4   Q
            0x54,                               // VARIA BYTE 5   T
            0x54,                               // VARIA BYTE 6   T
            0x04,                               // VARIA BYTE 7   Version = 4
            0x02,                               // VARIA BYTE 8   Username Password RETAIN QoS Will Clean flags
            0x00,                               // VARIA BYTE 9   Keep Alive MSB
            MQTT_KEEPALIVE,                     // VARIA BYTE 10  Keep Alive LSB
            0x00,                               // VARIA BYTE 11  client id length MSB
            UInt8(clientId.utf8.count)          // VARIA BYTE 12  client id length LSB
        ]

        let messageBytes = connectBytes + [UInt8](clientId.utf8)
        outputStream?.write(messageBytes, maxLength: messageBytes.count)

        clientState = MQTTClientState.Initializing
    }

    func subscribe(topic: String) {
        let subscribeBytes: [UInt8] = [
            0x82,                               // FIXED BYTE 1   8 = SUBSCRIBE, 2 = DUP QoS RETAIN
            UInt8(topic.utf8.count + 6),        // FIXED BYTE 2   remaining length, topic id length + 6
            0x00,                               // VARIA BYTE 1   message id MSB
            0x01,                               // VARIA BYTE 2   message id LSB
            0x00,                               // VARIA BYTE 3   topic length MSB
            UInt8(topic.utf8.count + 1)         // VARIA BYTE 4   topic length LSB (includes QoS byte)
        ]

        let requestedQosByte: [UInt8] = [
            0x23                                // Requested QoS
        ]

        let nullByte: [UInt8] = [
            0x00
        ]

        let messageBytes = subscribeBytes + [UInt8](topic.utf8) + requestedQosByte + nullByte
        outputStream?.write(messageBytes, maxLength: messageBytes.count)
    }

    func unsubscribe(topic: String) {
        let unsubscribeBytes: [UInt8] = [
            0xa2,                               // FIXED BYTE 1   a = UNSUBSCRIBE, 2 = DUP QoS RETAIN
            UInt8(topic.utf8.count + 6),        // FIXED BYTE 2   remaining length, topic id length + 6
            0x00,                               // VARIA BYTE 1   message id MSB
            0x01,                               // VARIA BYTE 2   message id LSB
            0x00,                               // VARIA BYTE 3   topic length MSB
            UInt8(topic.utf8.count + 1)         // VARIA BYTE 4   topic length LSB (includes QoS byte)
        ]

        let requestedQosByte: [UInt8] = [
            0x23                                // Requested QoS
        ]

        let nullByte: [UInt8] = [
            0x00
        ]

        let messageBytes = unsubscribeBytes + [UInt8](topic.utf8) + requestedQosByte + nullByte
        outputStream?.write(messageBytes, maxLength: messageBytes.count)
    }

    func ping() {
        let messageBytes: [UInt8] = [
            0xc0,                               // FIXED BYTE 1   c = PINGREQ, 0 = DUP QoS RETAIN (not used)
            0x00                                // FIXED BYTE 2   remaining length = 0
        ]

        outputStream?.write(messageBytes, maxLength: messageBytes.count)
    }

    func disconnect() {
        let messageBytes: [UInt8] = [
            0xe0,                               // FIXED BYTE 1   e = DISCONNECT, 0 = DUP QoS RETAIN (not used)
            0x00                                // FIXED BYTE 2   remaining length = 0
        ]

        outputStream?.write(messageBytes, maxLength: messageBytes.count)

        clientState = MQTTClientState.ConnectionClosed
    }

    // MARK: - Stream delegate

    func stream(aStream: NSStream, handleEvent eventCode: NSStreamEvent) {
        switch aStream {
        case inputStream!:
            switch (eventCode) {
            case NSStreamEvent.HasBytesAvailable:

                if clientState == .DecodingHeader {

                    let count = inputStream!.read(&readBuffer, maxLength: 1)

                    if count > 0 {
                        if let message = MQTTMessage(rawValue: readBuffer[0] & 0xf0) {
                            switch message {
                            case .PUBLISH:
                                clientState = .DecodingLength
                            default:
                                // no need to care about other messages from server but PUBLISH
                                break
                            }
                        }

                    } else {
                        clientState = .ConnectionError
                    }
                }

                while clientState == .DecodingLength {

                    let count = inputStream!.read(&readBuffer, maxLength: 1)

                    if count == 0 {
                        break
                    } else if count == -1 {
                        clientState = .ConnectionError
                    }

                    messageLength += Int(readBuffer[0] & 127) * messageLengthMultiplier
                    if readBuffer[0] & 128 == 0x00 {
                        clientState = .DecodingData
                    } else {
                        messageLengthMultiplier *= 128
                    }

                }

                if clientState == .DecodingData {

                    var bytesToRead = messageLength - messageBuffer.count
                    if bytesToRead > readBuffer.count {
                        bytesToRead = readBuffer.count
                    }

                    let count = inputStream!.read(&readBuffer, maxLength: bytesToRead)

                    if count == -1 {
                        clientState = .ConnectionError
                    } else {
                        messageBuffer += readBuffer[0 ..< count]
                    }

                    if messageBuffer.count == messageLength {
                        parseMessage()

                        messageBuffer = []
                        messageLength = 0
                        messageLengthMultiplier = 1
                        
                        clientState = MQTTClientState.DecodingHeader
                    }
                }
                
                
            case NSStreamEvent.OpenCompleted:
                clientState = MQTTClientState.DecodingHeader
            case NSStreamEvent.ErrorOccurred:
                clientState = MQTTClientState.ConnectionError
            case NSStreamEvent.EndEncountered:
                clientState = MQTTClientState.ConnectionClosed
            case NSStreamEvent.None:
                break
            default:
                break
            }
            
        default:
            break
        }
    }

    // MARK: - Message parsing

    private func parseMessage() {
        let topicLengthMSB = messageBuffer[0]
        let topicLengthLSB = messageBuffer[1]

        let topicLength = Int(topicLengthMSB) * 256 + Int(topicLengthLSB)

        let topic = String(bytes: messageBuffer[2 ..< topicLength + 2], encoding: NSUTF8StringEncoding)
        let message = String(bytes: messageBuffer[topicLength + 2 ..< messageBuffer.count], encoding: NSUTF8StringEncoding)

        if let topic = topic, let message = message {
            delegate?.didReceiveMessage(topic, message: message)
        }
    }
}
