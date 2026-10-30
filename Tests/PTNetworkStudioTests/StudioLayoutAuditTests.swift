import Foundation
import XCTest
@testable import PTNetworkStudio

final class StudioLayoutAuditTests: XCTestCase {
    private func node(_ id: String, parent: String? = nil,
                      x: Double = 0, y: Double = 0,
                      width: Double = 100, height: Double = 100,
                      clipping: Bool = false) -> StudioDiagnosticEntry {
        StudioDiagnosticEntry(
            id: id, parentID: parent, kind: "UIView", name: id,
            detail: nil,
            frame: StudioDiagnosticRect(x: x, y: y, width: width, height: height),
            attributes: ["clipsToBounds": String(clipping)],
            previewBase64: nil)
    }

    func testOnlyClippedParentsWarnAboutOffscreenDescendants() {
        let clipped = node("parent", width: 100, height: 100, clipping: true)
        let overflowing = node("child", parent: "parent", x: 90, width: 50)
        let findings = StudioLayoutAudit.analyze([clipped, overflowing])
        XCTAssertEqual(findings["child"]?.map(\.kind), [.clippedByParent])
        let notClipped = node("parent", clipping: false)
        XCTAssertNil(StudioLayoutAudit.analyze([notClipped, overflowing])["child"])
    }

    func testZeroSizeIsAdvisoryAndOrdinaryFrameHasNoWarnings() {
        let findings = StudioLayoutAudit.analyze([
            node("ordinary"), node("hidden", width: 0)
        ])
        XCTAssertNil(findings["ordinary"])
        XCTAssertEqual(findings["hidden"]?.first?.kind, .emptySize)
    }
    func testMixedAutoresizingAndConstraintsAreOnlyAdvisory() {
        let entry = StudioDiagnosticEntry(
            id: "mixed", parentID: nil, kind: "UIView", name: "UIView",
            detail: nil, frame: StudioDiagnosticRect(x: 0, y: 0, width: 80, height: 30),
            attributes: ["translatesAutoresizingMaskIntoConstraints": "true",
                         "ownActiveConstraints": "3"],
            previewBase64: nil)
        let findings = StudioLayoutAudit.analyze([entry])
        XCTAssertEqual(findings["mixed"]?.map(\.kind), [.mixedLayoutModes])
        XCTAssertTrue(findings["mixed"]?.first?.summary.contains("review only") == true)
    }

    func testHiddenZeroSizeIsNotReportedAsVisibleLayoutFailure() {
        let hidden = StudioDiagnosticEntry(
            id: "hidden", parentID: nil, kind: "UIView", name: "Placeholder",
            detail: nil, frame: StudioDiagnosticRect(x: 0, y: 0, width: 0, height: 0),
            attributes: ["isHidden": "true"], previewBase64: nil)
        XCTAssertNil(StudioLayoutAudit.analyze([hidden])["hidden"])
    }

}
