import XCTest
@testable import LightMQTT

class LightMQTTTests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        XCTAssertEqual(LightMQTT().text, "Hello, World!")
    }


    static var allTests = [
        ("testExample", testExample),
    ]
}
