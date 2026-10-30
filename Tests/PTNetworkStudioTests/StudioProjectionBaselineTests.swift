import Foundation
import XCTest
@testable import PTNetworkStudio

/// PR51: opt-in reproducible macOS baseline. This test protects semantic
/// invariants but intentionally does not assert device-specific timing limits.
final class StudioProjectionBaselineTests: XCTestCase {
    func testOneHundredFiveHundredThousandFlowFilterMatrix() {
        for count in [100, 500, 1_000] {
            let entries = (0..<count).map { index in
                CaptureEntry(method: index.isMultiple(of: 2) ? "GET" : "POST",
                             url: "https://api.example.test/products/\(index)",
                             host: "api.example.test",
                             status: index.isMultiple(of: 10) ? 500 : 200)
            }
            var timings: [Double] = []
            for _ in 0..<5 {
                let started = ProcessInfo.processInfo.systemUptime
                let rows = StudioFlowProjection.filter(
                    entries: entries, scope: .failed, search: "PRODUCTS")
                timings.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
                XCTAssertEqual(rows.count, count / 10)
                XCTAssertEqual(rows.first?.id, entries[count - 10].id)
            }
            let sorted = timings.sorted()
            print("PR51 Studio projection entries=\(count) medianMs=\(sorted[2]) p95Ms=\(sorted[4])")
        }
    }

    func testThousandInspectorRowsRemainBoundedAndSearchable() {
        let entries = (0..<1_000).map { i in
            StudioDiagnosticEntry(id: "node-\(i)", parentID: nil,
                                  kind: "UIView", name: i.isMultiple(of: 10) ? "UILabel" : "UIView",
                                  detail: "depth \(i % 20)", frame: nil,
                                  attributes: [:], previewBase64: nil)
        }
        let index = StudioHierarchyProjection(entries: entries)
        let visible = StudioHierarchyProjection.visibleRows(
            entries: entries, indexed: index.indexedEntries,
            children: index.children, collapsed: [])
        XCTAssertEqual(visible.count, 1_000)
        XCTAssertEqual(StudioDiagnosticSearch.filter(visible, query: "UILabel").count, 100)
    }
}
