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

Set a delegate for the client, then set up TCP socket and connect MQTT client to the server. LightMQTT begins sending ping messages to the server to prevent keepalive timer from expiring.

```swift

mqttClient.delegate = self
mqttClient.connect()

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

The delegate protocol is simple, as shown below

```swift

protocol LightMQTTDelegate: class {
    func didReceiveMessage(topic: String, message: String)
}

```

Just implement the delegate function to receive messages on subscribed topics. Currently only String data type is implemented.

```swift

func didReceiveMessage(topic: String, message: String) {
   ...
}

```
