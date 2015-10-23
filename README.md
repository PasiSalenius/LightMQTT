# LightMQTT

LightMQTT was created as a lightweight MQTT client, written in Swift, without the need to add other external dependencies in your code. It is a streaming parser and should be able to cope with fragmentation of large MQTT messages. To keep everything smooth at high loads, there is a minimum amount of data mangling and moving.

Contributions are totally welcome, you're free to use LightMQTT as you see fit.

Installation
----

Just copy the file into your project and you're ready to go.

CocoaPods support and all that needs to wait.

Usage
----

Initialize your MQTT client

    let mqttClient = LightMQTT()

Set a delegate for the client, then establish a TCP connection to the MQTT server host and port and connect MQTT client. Start issuing ping messages to the server to prevent keepalive timer from expiring.

    mqttClient.delegate = self
    mqttClient.connectSocket("10.10.10.10", port: 1883)
    mqttClient.connect()
    mqttClient.beginKeepAliveTimer()

Subscribe to a topic that the MQTT server publishes

    mqttClient.subscribe("/mytopic/")

One you are done using the client, you should unsubscribe and then disconnect

   mqttClient.unsubscribe("/mytopic")
   mqttClient.disconnect()

The delegate protocol is simple, as shown below

   protocol LightMQTTDelegate {
    func didReceiveMessage(topic: String, message: String)
   }

Just implement the delegate function to receive messages on subscribed topics. Currently only String data type is implemented.

   func didReceiveMessage(topic: String, message: String) {
    let json = JSON(string: message)

   }
