# LightMQTT

LightMQTT is a lightweight MQTT client, written in Swift. It's small and should be easy to understand and tune for a specific use case. The client requires no other dependencies in your project. To keep everything running smooth at high loads, there is only a minimum amount of data copying from read buffer before actual message parsing and all reading from InputStream is done on a dispatched background queue.

Do note that the client offers quite basic functionality, i.e. it connects to server, subscribes to topics and receives messages. It is able to publish messages, but only using QoS 0. It should be able to cope with fragmentation of large MQTT messages, although this part has not been heavily tested.

Contributions are totally welcome, feel free to use LightMQTT as you see fit.

LightMQTT was created for the [Transporter](https://freshbits.fi/apps/transporter/) public transit journey planner app for iOS.

Installation
----

Just copy the LightMQTT.swift file into your project and you're ready to go.

CocoaPods support and all that needs to wait.

Usage
----

Initialize your MQTT client with the MQTT server host address

```swift

let client = LightMQTT(host: "10.10.10.10")

```

LightMQTT.Options can be used to specify optional client parameters.

Any % character in the clientId is converted to a hex byte encoded as two ascii hex characters. This lets you define simple templates for custom clientId strings.

Note that currently LightMQTT uses a static buffer for received message bytes. Its size is defined with `bufferSize` defaulting to 4096. Configure a large enough buffer for your use case, as messages larger than the buffer get silently discarded. Having this single read buffer greatly increases performance.

```swift

var options = LightMQTT.Options()
options.useTLS = true
options.port = 8883
options.username = "myuser"
options.password = "s3cr3t"
options.clientId = "myapp_%%%%"
options.pingInterval = 60
options.bufferSize = 4096
options.readQosClass = .background

let client = LightMQTT(host: "10.10.10.10", options: options)

```

Set up TCP socket and connect MQTT client to the server with `connect()`. Connecting is asynchronous so subscribe to topics only once the connection is ready, in the completion block. The block returns a `success` flag indicating if the client established a connection or not.

```swift

client.connect() { success in
    if success {
        // use the client to subscribe to topics here
        client.subscribe(to: "/mytopic/#")
    }
}

```

Unsubscribe from a topic

```swift

client.unsubscribe(to: "/mytopic/#")

```

Publish messages as Data as follows

```swift

client.publish(to: "/mytopic/#", message: someData)

```

One you are done using the client, you should disconnect. Unsubscribing is not necessary as the client connects with Clean Session set to 1, so the broker should remove all subscriptions at disconnect time anyway.

```swift

client.disconnect()

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

client.receivingBuffer = { (topic: String, buffer: UnsafeBufferPointer<UTF8.CodeUnit>) in
    // parse buffer to JSON here
    
    DispatchQueue.main.async {
        // update your UI safely here
    }
}

```
