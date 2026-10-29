import SwiftUI
import AppKit

// The schema-v2 contract mirrors the Foundation-only PToolsStudioProtocolCore.
// It intentionally lives outside Network schema v1 and cannot alter proxy traffic.
struct StudioDiagnosticCommand: Encodable {
    let schemaVersion = 2
    let id: UUID
    let sessionID: UUID
    let domain: String
    let operation: String
    let targetID: String?
    let arguments: [String: String]
}

struct StudioDiagnosticRect: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct StudioDiagnosticEntry: Codable, Identifiable {
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
struct StudioDiagnosticsWorkspaceView: View {
    @EnvironmentObject private var bridge: StudioBridgeController
    let domain: String
    @State private var storageArea = "storage"
    @State private var selectedID: String?
    @State private var previousIDs: Set<String> = []
    @State private var presentIDs: Set<String> = []
    @State private var viewing3D = false
    @State private var alphaValue = 1.0
    @State private var lastMessage: String?

    private var targetDomain: String {
        domain == "storage" ? storageArea : domain == "console" ? "logging" : domain
    }
    private var reply: StudioDiagnosticReply? { bridge.diagnosticResults[targetDomain] }
    private var entries: [StudioDiagnosticEntry] { reply?.entries ?? [] }
    private var selected: StudioDiagnosticEntry? { entries.first(where: { $0.id == selectedID }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(domain.capitalized).font(.title2.bold())
                Spacer()
                if domain == "storage" {
                    Picker("Store", selection: $storageArea) {
                        Text("Files").tag("storage")
                        Text("Defaults").tag("defaults")
                        Text("Databases").tag("database")
                    }.frame(width: 165)
                }
                if domain == "inspector" {
                    Toggle("3D", isOn: $viewing3D).toggleStyle(.switch)
                        .help("Perspective representation of captured view frames")
                }
                Button("Refresh") {
                    previousIDs = presentIDs
                    request(domain == "storage" ? "list" : "snapshot")
                }
                .disabled(!bridge.isRunning)
                Button("Export JSON…") { export() }.disabled(reply == nil)
            }
            if !bridge.isRunning {
                ContentUnavailableView("Bridge stopped", systemImage: "iphone.slash",
                    description: Text("Start the secure Bridge in Network → iPhone."))
            } else if reply == nil {
                ContentUnavailableView("No diagnostic snapshot", systemImage: "network",
                    description: Text("Enable Diagnostics on the paired iPhone, then select Refresh."))
            } else {
                HStack(spacing: 0) {
                    List(selection: $selectedID) {
                        ForEach(entries) { entry in
                            HStack {
                                Text(entry.kind == "UIView" ? "▣" : "•")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).lineLimit(1)
                                    if let d = entry.detail {
                                        Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                if !previousIDs.isEmpty && !previousIDs.contains(entry.id) {
                                    Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                                }
                            }.tag(entry.id)
                        }
                    }
                    .frame(minWidth: 310)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let message = reply?.message {
                                Text(message).font(.caption).foregroundStyle(.secondary)
                            }
                            if domain == "inspector" {
                                if viewing3D { perspective }
                                if let entry = selected {
                                    Text(entry.name).font(.headline)
                                    if let frame = entry.frame {
                                        Text("x: \(Int(frame.x)), y: \(Int(frame.y)), w: \(Int(frame.width)), h: \(Int(frame.height))")
                                            .font(.system(.caption, design: .monospaced))
                                    }
                                    ForEach(entry.attributes.sorted(by: { $0.key < $1.key }), id: \.key) { pair in
                                        HStack {
                                            Text(pair.key).foregroundStyle(.secondary)
                                            Spacer()
                                            Text(pair.value).textSelection(.enabled)
                                        }.font(.caption)
                                    }
                                    HStack {
                                        Button("Highlight") { request("highlight", target: entry.id) }
                                        Button("Hide") { request("setHidden", target: entry.id, args: ["value": "true"]) }
                                        Button("Show") { request("setHidden", target: entry.id, args: ["value": "false"]) }
                                    }
                                    HStack {
                                        Slider(value: $alphaValue, in: 0.1...1.0)
                                        Button("Set Alpha") {
                                            request("setAlpha", target: entry.id, args: ["value": String(alphaValue)])
                                        }
                                    }
                                    Button("Undo last edit") { request("undo") }
                                    Text("Edits require a separate iPhone authorization. All actions are Debug-only.")
                                        .font(.caption2).foregroundStyle(.orange)
                                } else {
                                    Text("Select a view to inspect and highlight it.").foregroundStyle(.secondary)
                                }
                            } else {
                                if let entry = selected {
                                    Text(entry.name).font(.headline)
                                    Text(entry.detail ?? "").textSelection(.enabled)
                                    ForEach(entry.attributes.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                                        HStack { Text(item.key); Spacer(); Text(item.value) }
                                            .font(.caption)
                                    }
                                } else {
                                    Text("Select an entry to inspect its metadata.").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minWidth: 380)
                }
            }
            if let lastMessage {
                Text(lastMessage).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Text("\(entries.count) entries")
                if !previousIDs.isEmpty {
                    Text("• \(presentIDs.subtracting(previousIDs).count) added, \(previousIDs.subtracting(presentIDs).count) removed")
                }
                Spacer()
                Text("Read-only by default • TLS + authorized Debug Agent")
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18)
        .onChange(of: bridge.diagnosticRevision) { _ in
            if let data = reply {
                presentIDs = Set(data.entries.map(\.id))
                lastMessage = data.success ? nil : data.message ?? "Diagnostic command rejected"
            }
        }
        .onChange(of: storageArea) { _ in selectedID = nil; presentIDs = []; previousIDs = [] }
    }

    // Overview derived only from the actual view coordinates, not arbitrary script execution.
    private var perspective: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(.gray.opacity(0.10))
            ForEach(entries.filter { $0.frame != nil }.prefix(70)) { entry in
                if let rect = entry.frame {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(.blue.opacity(0.6), lineWidth: 1)
                        .frame(width: max(2, min(300, rect.width * 0.4)),
                               height: max(2, min(180, rect.height * 0.3)))
                        .offset(x: max(0, rect.x * 0.4), y: max(0, rect.y * 0.3))
                }
            }
        }
        .frame(height: 230)
        .rotation3DEffect(.degrees(42), axis: (x: 1, y: -0.4, z: 0))
        .padding(.vertical, 35)
        .accessibilityLabel("View hierarchy perspective preview")
    }

    private func request(_ operation: String, target: String? = nil, args: [String: String] = [:]) {
        guard bridge.sendDiagnostic(domain: targetDomain, operation: operation,
                                    targetID: target, arguments: args) else {
            lastMessage = "No authenticated session or the Bridge is stopped"
            return
        }
        lastMessage = nil
    }

    private func export() {
        guard let reply else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "PTools-\(targetDomain)-snapshot.json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                // Export only sanitized entries received from the authenticated Bridge.
                let data = try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 2, "domain": targetDomain,
                    "entries": reply.entries.map { entry in
                        ["id": entry.id, "kind": entry.kind, "name": entry.name,
                         "detail": entry.detail ?? "", "attributes": entry.attributes] as [String: Any]
                    }
                ], options: [.prettyPrinted, .sortedKeys])
                try data.write(to: url, options: .atomic)
            } catch { lastMessage = error.localizedDescription }
        }
    }
}
