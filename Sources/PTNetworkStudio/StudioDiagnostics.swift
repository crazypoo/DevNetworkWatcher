import Foundation
import SwiftUI

struct StudioDiagnosticCommand: Encodable {
    let schemaVersion = 2
    let id: UUID
    let sessionID: UUID
    let domain: String
    let operation: String
    let targetID: String?
    let arguments: [String: String]

    init(sessionID: UUID, domain: String, operation: String,
         targetID: String? = nil, arguments: [String: String] = [:]) {
        self.id = UUID(); self.sessionID = sessionID
        self.domain = domain; self.operation = operation
        self.targetID = targetID; self.arguments = arguments
    }
}

struct StudioDiagnosticRect: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct StudioDiagnosticEntry: Identifiable, Codable, Equatable {
    let id: String
    let parentID: String?
    let kind: String
    let name: String
    let detail: String?
    let frame: StudioDiagnosticRect?
    let attributes: [String: String]
    let previewBase64: String?
}

struct StudioDiagnosticReply: Decodable {
    let schemaVersion: Int
    let id: UUID
    let sessionID: UUID
    let success: Bool
    let message: String?
    let entries: [StudioDiagnosticEntry]
}

@MainActor
final class StudioDiagnosticStore: ObservableObject {
    @Published private(set) var inspector: [StudioDiagnosticEntry] = []
    @Published private(set) var previousInspector: [StudioDiagnosticEntry] = []
    @Published private(set) var diffSummary = "Capture two snapshots to compare"
    @Published private(set) var lastError: String?
    @Published private(set) var lastAction: String?
    @Published private(set) var lastUndoID: String?
    @Published private(set) var latest: [String: [StudioDiagnosticEntry]] = [:]
    private var pending: [UUID: String] = [:]

    func request(_ domain: String, operation: String,
                 targetID: String? = nil, arguments: [String: String] = [:],
                 bridge: StudioBridgeController) {
        guard let session = bridge.diagnosticSessions.keys.sorted(by: { $0.uuidString < $1.uuidString }).first else {
            lastError = "No paired diagnostic agent is connected. Enable it in the iOS Debug app."
            return
        }
        let command = StudioDiagnosticCommand(sessionID: session, domain: domain,
                                              operation: operation, targetID: targetID, arguments: arguments)
        guard bridge.sendDiagnostic(command) else {
            lastError = "Secure Bridge is not ready for diagnostic commands"
            return
        }
        pending[command.id] = domain + "." + operation
        lastAction = "Requested " + domain + "." + operation
        lastError = nil
    }

    func receive(_ reply: StudioDiagnosticReply) {
        guard reply.schemaVersion == 2, let action = pending.removeValue(forKey: reply.id) else { return }
        if reply.success {
            latest[action] = reply.entries
            if action == "inspector.snapshot" {
                if !inspector.isEmpty {
                    previousInspector = inspector
                    let old = Dictionary(uniqueKeysWithValues: inspector.map { ($0.id, $0) })
                    let new = Dictionary(uniqueKeysWithValues: reply.entries.map { ($0.id, $0) })
                    let added = new.keys.filter { old[$0] == nil }.count
                    let removed = old.keys.filter { new[$0] == nil }.count
                    let changed = new.filter { key, node in
                        guard let previous = old[key] else { return false }
                        return previous != node
                    }.count
                    diffSummary = "\(added) added · \(removed) removed · \(changed) changed"
                }
                inspector = reply.entries
            }
            if action == "inspector.setProperty" { lastUndoID = reply.id.uuidString }
            if action == "inspector.revert" { lastUndoID = nil }
            if action.hasPrefix("inspector."), action != "inspector.snapshot" {
                for entry in reply.entries {
                    if let index = inspector.firstIndex(where: { $0.id == entry.id }) {
                        inspector[index] = entry
                    }
                }
            }
            lastError = nil
            lastAction = action + " completed (" + String(reply.entries.count) + " entries)"
        } else {
            lastError = reply.message ?? (action + " was rejected by the iOS agent")
        }
    }
}
