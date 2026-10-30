import Foundation
import XCTest
@testable import PTNetworkStudio

final class StudioProcessReaderBurstTests: XCTestCase {
    func testManyNewlineDelimitedMessagesAreDeliveredInOrder() {
        let complete = expectation(description: "all framed messages delivered")
        complete.expectedFulfillmentCount = 150
        let lock = NSLock()
        var delivered = [Int]()
        let reader = StudioProcessReader { object in
            guard object["type"] as? String == "notice",
                  let number = object["index"] as? Int else { return }
            lock.lock()
            delivered.append(number)
            lock.unlock()
            complete.fulfill()
        }
        let pipe = Pipe()
        reader.attach(pipe)
        let payload = (0..<150).map { index in
            "PTSTUDIO:{\"type\":\"notice\",\"index\":\(index)}\n"
        }.joined()
        pipe.fileHandleForWriting.write(Data(payload.utf8))
        wait(for: [complete], timeout: 5)
        pipe.fileHandleForWriting.closeFile()
        withExtendedLifetime(reader) {}
        lock.lock()
        let result = delivered
        lock.unlock()
        XCTAssertEqual(result, Array(0..<150))
    }

    func testLargeImmutableDiagnosticReplyCanDecodeOffMain() async throws {
        let entries: [[String: Any]] = (0..<900).map { index in
            ["id": "node-\(index)", "kind": "UIView", "name": "UIView",
             "attributes": ["alpha": "1.0"]]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "id": UUID().uuidString,
            "sessionID": UUID().uuidString,
            "success": true,
            "entries": entries
        ])
        let decoded = try await Task.detached(priority: .utility) {
            try JSONDecoder().decode(StudioDiagnosticReply.self, from: data)
        }.value
        XCTAssertEqual(decoded.entries.count, 900)
        XCTAssertEqual(decoded.entries.first?.name, "UIView")
    }
}
