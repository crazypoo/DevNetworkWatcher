import Foundation
import XCTest
@testable import PTNetworkStudio

final class StudioDiagnosticSessionCorrelationTests: XCTestCase {
    private func reply(_ session: UUID, success: Bool = true,
                       count: Int = 1) -> StudioDiagnosticReply {
        StudioDiagnosticReply(
            schemaVersion: 2, id: UUID(), sessionID: session,
            success: success, message: nil,
            entries: (0..<count).map {
                StudioDiagnosticEntry(
                    id: "record-\($0)", parentID: nil, kind: "log",
                    name: "Sanitized", detail: nil, frame: nil,
                    attributes: [:], previewBase64: nil)
            })
    }

    func testOnlySameSessionSuccessfulDomainsAreVisibleAndSorted() {
        let authorizedSession = UUID()
        let otherPhone = UUID()
        let matched = StudioDiagnosticSessionCorrelation.relatedSnapshots(
            to: "inspector", sessionID: authorizedSession,
            available: [
                "inspector": reply(authorizedSession),
                "storage": reply(authorizedSession, count: 7),
                "performance": reply(authorizedSession, count: 3),
                "logging": reply(otherPhone),
                "database": reply(authorizedSession, success: false)
            ])
        XCTAssertEqual(matched.map(\.domain), ["performance", "storage"])
        XCTAssertEqual(matched.map(\.entryCount), [3, 7])
    }

    func testNoDeviceIdOrPersistentLinkIsNeededToCorrelate() {
        let session = UUID()
        XCTAssertTrue(StudioDiagnosticSessionCorrelation.relatedSnapshots(
            to: "inspector", sessionID: session,
            available: ["storage": reply(UUID())]).isEmpty)
    }
}
