import XCTest
@testable import LightMQTT

class LightMQTTTests: XCTestCase {
    func testNotNil() {
        let host = "mqtt.foobar.com"
        let instance = LightMQTT(host: host)
        XCTAssertNotNil(instance)
    }


    static var allTests = [
        ("testNotNil", testNotNil),
    ]
}
