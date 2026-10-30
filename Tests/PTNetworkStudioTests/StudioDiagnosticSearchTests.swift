import Foundation
import XCTest
@testable import PTNetworkStudio

final class StudioDiagnosticSearchTests: XCTestCase {
    private func row(_ id: String, name: String,
                     detail: String? = nil, attributes: [String: String] = [:]) -> StudioHierarchyRow {
        StudioHierarchyRow(entry: StudioDiagnosticEntry(
            id: id, parentID: nil, kind: "UIView", name: name,
            detail: detail, frame: nil, attributes: attributes,
            previewBase64: nil), depth: 0)
    }

    func testOneSearchMatchesNameDetailKindAndAttributes() {
        let rows = [
            row("1", name: "UILabel"),
            row("2", name: "File", detail: "Cached 1688 product"),
            row("3", name: "Memory", attributes: ["usage": "42 MB"])
        ]
        XCTAssertEqual(StudioDiagnosticSearch.filter(rows, query: "uilabel").map(\.id), ["1"])
        XCTAssertEqual(StudioDiagnosticSearch.filter(rows, query: "PRODUCT").map(\.id), ["2"])
        XCTAssertEqual(StudioDiagnosticSearch.filter(rows, query: "usage").map(\.id), ["3"])
        XCTAssertEqual(StudioDiagnosticSearch.filter(rows, query: "  ").map(\.id), ["1", "2", "3"])
    }
}
