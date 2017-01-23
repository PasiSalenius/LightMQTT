# LightMQTT

LightMQTT is a lightweight MQTT client, written in Swift. It's small and requires no other dependencies in your code. It should be able to cope with fragmentation of large MQTT messages. To keep everything running smooth at high loads, there is only a minimum amount of data mangling.

Contributions are totally welcome, feel free to use LightMQTT as you see fit.

LightMQTT was created for the [Transporter](https://freshbits.fi/apps/transporter/) public transit journey planner app that I'm developing for iOS and watchOS.

Installation
----

Just copy the LightMQTT.swift file into your project and you're ready to go.

CocoaPods support and all that needs to wait.

Usage
----

Initialize your MQTT client with the MQTT server host and port

```swift

let mqttClient = LightMQTT(host: "10.10.10.10", port: 1883)

```

Set up TCP socket and connect MQTT client to the server with `connect()`. LightMQTT begins sending ping messages to the server to prevent keepalive timer from expiring.

```swift

let success = mqttClient.connect()

```

Subscribe to a topic that the MQTT server publishes

```swift

mqttClient.subscribe("/mytopic/#")

```

One you are done using the client, you should unsubscribe and then disconnect

```swift

mqttClient.unsubscribe("/mytopic/#")
mqttClient.disconnect()

```

There are currently four optional closures for receiving messages as different data types, as shown below

```swift

var receivingMessage: ((_ topic: String, _ message: String) -> ())?
var receivingBuffer: ((_ topic: String, _ buffer: UnsafeBufferPointer<UTF8.CodeUnit>) -> ())?
var receivingBytes: ((_ topic: String, _ bytes: [UTF8.CodeUnit]) -> ())?
var receivingData: ((_ topic: String, _ data: Data) -> ())?

```

Use one of these closures to read back received MQTT messages. Remember to dispatch back to main thread before updating UI after parsing MQTT message contents.

```swift

mqttClient.receivingBuffer = { (topic: String, buffer: UnsafeBufferPointer<UTF8.CodeUnit>) in
    // parse buffer to JSON here
    
    DispatchQueue.main.async {
        // update your UI safely here
    }
}

```
