import Foundation
import XCTest
@testable import PTNetworkStudio

final class StudioFlowProjectionTests: XCTestCase {
    private func flow(_ id: Int, url: String, method: String = "GET",
                      status: Int? = 200, error: String? = nil) -> CaptureEntry {
        CaptureEntry(id: UUID(), method: method, url: url,
                     host: URL(string: url)?.host ?? "tunnel.example",
                     status: status, error: error)
    }

    func testScopesMatchLegacySemanticsAndKeepNewestFirst() {
        let entries = [
            flow(0, url: "http://example.test/a"),
            flow(1, url: "https://example.test/b", status: 404),
            flow(2, url: "tunnel.example:443", method: "CONNECT", status: nil),
            flow(3, url: "https://other.test/c", error: "timeout")
        ]
        XCTAssertEqual(StudioFlowProjection.filter(entries: entries, scope: .all, search: "").map(\.id),
                       entries.reversed().map(\.id))
        XCTAssertEqual(StudioFlowProjection.filter(entries: entries, scope: .http, search: "").count, 1)
        XCTAssertEqual(StudioFlowProjection.filter(entries: entries, scope: .https, search: "").count, 3)
        XCTAssertEqual(StudioFlowProjection.filter(entries: entries, scope: .failed, search: "").count, 2)
        XCTAssertEqual(StudioFlowProjection.filter(entries: entries, scope: .host("example.test"), search: "").count, 2)
        XCTAssertEqual(StudioFlowProjection.filter(entries: entries, scope: .all, search: "OTHER.TEST").count, 1)
    }

    func testThousandEntrySearchIsStableAndDoesNotMutateInput() {
        let entries = (0..<1_000).map { i in
            flow(i, url: "https://api.example.test/product/\(i)", status: i % 10 == 0 ? 500 : 200)
        }
        let result = StudioFlowProjection.filter(entries: entries, scope: .failed, search: "api.example")
        XCTAssertEqual(result.count, 100)
        XCTAssertEqual(result.first?.id, entries[990].id)
        XCTAssertEqual(entries.count, 1_000)
    }
}
