import Foundation
import XCTest
@testable import PTNetworkStudio

final class StudioDiagnosticCorrelationTests: XCTestCase {
    private func reply(id: UUID = UUID(), session: UUID, entries: [StudioDiagnosticEntry] = [])
    -> StudioDiagnosticReply {
        StudioDiagnosticReply(schemaVersion: 2, id: id, sessionID: session,
                              success: true, message: nil, entries: entries)
    }

    func testReplyRequiresExactRequestAndAuthenticatedSessionIdentity() {
        let id = UUID(), session = UUID()
        let accepted = reply(id: id, session: session)
        XCTAssertTrue(StudioDiagnosticCorrelation.accepts(
            requestID: id, requestSessionID: session, reply: accepted))
        XCTAssertFalse(StudioDiagnosticCorrelation.accepts(
            requestID: UUID(), requestSessionID: session, reply: accepted))
        XCTAssertFalse(StudioDiagnosticCorrelation.accepts(
            requestID: id, requestSessionID: UUID(), reply: accepted))
    }

    func testNoCrossDeviceTreeReuseOnEmptyAcknowledgement() {
        let firstSession = UUID(), secondSession = UUID()
        let entry = StudioDiagnosticEntry(
            id: "window", parentID: nil, kind: "window",
            name: "Window", detail: nil, frame: nil,
            attributes: [:], previewBase64: nil)
        let previous = reply(session: firstSession, entries: [entry])
        XCTAssertTrue(StudioDiagnosticCorrelation.mayReuseEntries(
            previous: previous, reply: reply(session: firstSession)))
        XCTAssertFalse(StudioDiagnosticCorrelation.mayReuseEntries(
            previous: previous, reply: reply(session: secondSession)))
    }
}
