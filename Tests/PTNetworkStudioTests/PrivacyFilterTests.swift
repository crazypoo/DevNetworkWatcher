import XCTest
@testable import PTNetworkStudio

final class PrivacyFilterTests: XCTestCase {
    func testSensitiveHeaders() {
        let result = PrivacyFilter.safeHeaders(["Authorization": "Bearer token", "Content-Type": "application/json", "X-API-Key": "123"])
        XCTAssertEqual(result["Authorization"], "<redacted>")
        XCTAssertEqual(result["X-API-Key"], "<redacted>")
        XCTAssertEqual(result["Content-Type"], "application/json")
    }

    func testNestedJSONRedaction() {
        let input = Data(#"{"name":"jax","nested":{"token":"secret"},"arr":[{"password":"p"}]}"#.utf8)
        let output = PrivacyFilter.safeBody(input, contentType: "application/json")
        XCTAssertTrue(output.contains("<redacted>"))
        XCTAssertFalse(output.contains("\"secret\""))
        XCTAssertFalse(output.contains("\"p\""))
        XCTAssertTrue(output.contains("jax"))
    }

    func testSensitiveURL() {
        let value = PrivacyFilter.safeURL("https://alice:pw@example.org/a?token=top&ok=1")
        XCTAssertFalse(value.contains("pw"))
        XCTAssertFalse(value.contains("top"))
        XCTAssertTrue(value.contains("ok=1"))
    }

    func testUnknownBodySuppressed() {
        XCTAssertTrue(PrivacyFilter.safeBody(Data("secretXYZ".utf8), contentType: "text/plain").contains("suppressed"))
    }
}
