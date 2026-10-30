import Foundation
import XCTest
@testable import PTNetworkStudio

final class StudioHierarchyProjectionTests: XCTestCase {
    private func entry(_ id: String, parent: String? = nil,
                       withFrame: Bool = false) -> StudioDiagnosticEntry {
        StudioDiagnosticEntry(
            id: id, parentID: parent, kind: "UIView", name: id,
            detail: nil,
            frame: withFrame ? StudioDiagnosticRect(x: 0, y: 0, width: 10, height: 10) : nil,
            attributes: [:], previewBase64: nil)
    }

    func testFirstDuplicateWinsWhileFlatRowsPreserveOriginalCount() {
        let projection = StudioHierarchyProjection(entries: [
            entry("root", withFrame: true), entry("root"), entry("child", parent: "root")
        ])
        XCTAssertEqual(projection.flatRows.count, 3)
        XCTAssertEqual(projection.indexedEntries.count, 2)
        XCTAssertEqual(projection.perspectiveEntries.count, 1)
        XCTAssertNotNil(projection.indexedEntries["root"]?.frame)
        XCTAssertEqual(projection.children["root"], ["child"])
    }

    func testCollapseAndReexpandDoNotLoseOrphansOrCycles() {
        let entries = [
            entry("root"), entry("leaf", parent: "root"),
            entry("orphan", parent: "missing"),
            entry("cycleA", parent: "cycleB"), entry("cycleB", parent: "cycleA")
        ]
        let projection = StudioHierarchyProjection(entries: entries)
        func visible(_ collapsed: Set<String>) -> [StudioHierarchyRow] {
            StudioHierarchyProjection.visibleRows(
                entries: entries, indexed: projection.indexedEntries,
                children: projection.children, collapsed: collapsed)
        }
        XCTAssertEqual(Set(visible(["root"]).map(\.id)),
                       Set(["root", "orphan", "cycleA", "cycleB", "leaf"]))
        // The original safety fallback presents hidden subtrees as orphan roots.
        XCTAssertEqual(visible([]).map(\.id).first, "root")
        XCTAssertEqual(Set(visible([]).map(\.id)).count, 5)
    }

    func testLargeHierarchyRemainsBoundedAndPerspectiveIsCapped() {
        let entries = (0..<1_300).map { entry("n\($0)", withFrame: true) }
        let projection = StudioHierarchyProjection(entries: entries)
        XCTAssertEqual(projection.perspectiveEntries.count, 70)
        XCTAssertEqual(projection.flatRows.count, 1_300)
        XCTAssertEqual(StudioHierarchyProjection.visibleRows(
            entries: entries, indexed: projection.indexedEntries,
            children: projection.children, collapsed: []).count, 1_200)
    }
}
