# LightMQTT

LightMQTT is a lightweight MQTT client, written in Swift. It's small and requires no other dependencies in your code. It should be able to cope with fragmentation of large MQTT messages. To keep everything running smooth at high loads, there is only a minimum amount of data mangling.

Contributions are totally welcome, feel free to use LightMQTT as you see fit.

LightMQTT was created for a journey planner app that I'm developing for iOS and watchOS, called [Transporter](https://freshbits.fi/apps/transporter/).

Installation
----

Just copy the LightMQTT.swift file into your project and you're ready to go.

CocoaPods support and all that needs to wait.

Usage
----

Initialize your MQTT client

```swift

let mqttClient = LightMQTT()

```

Set a delegate for the client, then establish a TCP connection to the MQTT server host and port and connect MQTT client. Start issuing ping messages to the server to prevent keepalive timer from expiring.

```swift

mqttClient.delegate = self
mqttClient.connectSocket("10.10.10.10", port: 1883)
mqttClient.connect()
mqttClient.beginKeepAliveTimer()

```

Subscribe to a topic that the MQTT server publishes

```swift

mqttClient.subscribe("/mytopic/")

```

One you are done using the client, you should unsubscribe and then disconnect

```swift

mqttClient.unsubscribe("/mytopic")
mqttClient.disconnect()

```

The delegate protocol is simple, as shown below

```swift

protocol LightMQTTDelegate {
   func didReceiveMessage(topic: String, message: String)
}

```

Just implement the delegate function to receive messages on subscribed topics. Currently only String data type is implemented.

```swift

func didReceiveMessage(topic: String, message: String) {
   let json = JSON(string: message)
   ...
}

```
