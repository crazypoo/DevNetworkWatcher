import Foundation

/// PR53: a correlation view over already-authorized, already-redacted v2
/// snapshots. Never correlate by device name, URL, token or persistent identity.
struct StudioCorrelatedSnapshot: Identifiable, Equatable {
    let domain: String
    let entryCount: Int
    var id: String { domain }
}

enum StudioDiagnosticSessionCorrelation {
    static func relatedSnapshots(
        to domain: String, sessionID: UUID,
        available: [String: StudioDiagnosticReply]
    ) -> [StudioCorrelatedSnapshot] {
        available.compactMap { key, reply in
            guard key != domain, reply.schemaVersion == 2,
                  reply.success, reply.sessionID == sessionID else { return nil }
            return StudioCorrelatedSnapshot(
                domain: key, entryCount: reply.entries.count)
        }.sorted { $0.domain < $1.domain }
    }
}
