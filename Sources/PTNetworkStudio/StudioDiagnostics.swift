import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

struct StudioDiagnosticRect: Codable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct StudioDiagnosticEntry: Codable, Identifiable, Sendable {
    let id: String
    let parentID: String?
    let kind: String
    let name: String
    let detail: String?
    let frame: StudioDiagnosticRect?
    let attributes: [String: String]
    let previewBase64: String?
}

struct StudioDiagnosticReply: Decodable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let sessionID: UUID
    let success: Bool
    let message: String?
    let entries: [StudioDiagnosticEntry]
}

/// Pure correlation rules shared by the transport and XCTest. An authenticated
/// peer alone is not enough: each request is bound to a specific iPhone session.
enum StudioDiagnosticCorrelation {
    static func accepts(requestID: UUID, requestSessionID: UUID,
                        reply: StudioDiagnosticReply) -> Bool {
        reply.schemaVersion == 2 &&
        reply.id == requestID &&
        reply.sessionID == requestSessionID
    }

    static func mayReuseEntries(previous: StudioDiagnosticReply,
                                reply: StudioDiagnosticReply) -> Bool {
        reply.entries.isEmpty && previous.sessionID == reply.sessionID
    }
}

@MainActor
struct StudioDiagnosticsWorkspaceView: View {
    @EnvironmentObject private var bridge: StudioBridgeController
    @EnvironmentObject private var captures: CaptureStore
    let domain: String
    @Binding var entryQuery: String
    let onSelectRelatedDomain: (String) -> Void
    @State private var storageArea = "storage"
    @State private var selectedID: String?
    @State private var previousIDs: Set<String> = []
    @State private var presentIDs: Set<String> = []
    @State private var viewing3D = false
    @State private var alphaValue = 1.0
    @State private var lastMessage: String?
    @State private var indexedEntries: [String: StudioDiagnosticEntry] = [:]
    @State private var children: [String: [String]] = [:]
    @State private var treeRows: [StudioHierarchyRow] = []
    @State private var flatRows: [StudioHierarchyRow] = []
    @State private var filteredRows: [StudioHierarchyRow] = []
    @State private var snapshotReceivedAt: Date?
    @State private var layoutFindings: [String: [StudioLayoutFinding]] = [:]
    @State private var collapsedIDs: Set<String> = []
    @State private var decodedPreview: NSImage?
    @State private var previewCache = NSCache<NSString, NSImage>()
    @State private var perspectiveEntries: [StudioDiagnosticEntry] = []
    @State private var lastIndexedReplyID: UUID?
    @State private var lastIndexedSessionID: UUID?
    @State private var lastIndexedFingerprint: String?

    private var targetDomain: String {
        domain == "storage" ? storageArea : domain == "console" ? "logging" : domain
    }
    private var reply: StudioDiagnosticReply? { bridge.diagnosticResults[targetDomain] }
    private var entries: [StudioDiagnosticEntry] { reply?.entries ?? [] }
    private var relatedSnapshots: [StudioCorrelatedSnapshot] {
        guard let reply else { return [] }
        return StudioDiagnosticSessionCorrelation.relatedSnapshots(
            to: targetDomain, sessionID: reply.sessionID,
            available: bridge.diagnosticResults)
    }
    private var selected: StudioDiagnosticEntry? {
        guard let selectedID else { return nil }
        return indexedEntries[selectedID]
    }

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
                TextField("Search snapshot", text: $entryQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .accessibilityLabel("Filter Inspector, Console, Storage or Metrics entries")
                Button("Refresh") {
                    previousIDs = presentIDs
                    request(domain == "storage" ? "list" : "snapshot")
                }
                .disabled(!bridge.isRunning)
                Button("Export JSON…") { export() }.disabled(reply == nil)
            }
            if reply != nil {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        Button("Network (\(captures.entries.count) total flows)") {
                            onSelectRelatedDomain("network")
                        }
                        .buttonStyle(.link)
                        .help("Aggregate proxy and iPhone traffic; not scoped to the selected diagnostics session")
                        if !relatedSnapshots.isEmpty {
                            Text("Same-session snapshots:")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(relatedSnapshots) { item in
                            Button("\(item.domain.capitalized) (\(item.entryCount))") {
                                onSelectRelatedDomain(item.domain)
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .font(.caption)
                }
                .accessibilityLabel("Network aggregate and other authorized same-session diagnostic workspaces")
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
                        ForEach(filteredRows) { row in
                            let entry = row.entry
                            HStack {
                                if domain == "inspector" && children[entry.id] != nil {
                                    Button {
                                        if !collapsedIDs.insert(entry.id).inserted {
                                            collapsedIDs.remove(entry.id)
                                        }
                                        rebuildVisibleRows()
                                    } label: {
                                        Image(systemName: collapsedIDs.contains(entry.id) ? "chevron.right" : "chevron.down")
                                    }
                                    .buttonStyle(.plain).frame(width: 12)
                                } else {
                                    Image(systemName: "circle.fill").font(.system(size: 4))
                                        .frame(width: 12).foregroundStyle(.secondary)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).lineLimit(1)
                                    if let d = entry.detail {
                                        Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                if domain == "inspector", layoutFindings[entry.id] != nil {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                        .help("Read-only geometry hint; not a confirmed Auto Layout conflict")
                                }
                                if !previousIDs.isEmpty && !previousIDs.contains(entry.id) {
                                    Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                                }
                            }
                            .padding(.leading, CGFloat(min(14, row.depth) * 10))
                            .tag(entry.id)
                        }
                    }
                    .frame(minWidth: 310)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let message = reply?.message,
                               !message.hasPrefix("fingerprint:"),
                               !message.hasPrefix("unchanged:") {
                                Text(message).font(.caption).foregroundStyle(.secondary)
                            }
                            if domain == "inspector" {
                                perspective
                                if let entry = selected {
                                    Text(entry.name).font(.headline)
                                    if let findings = layoutFindings[entry.id] {
                                        ForEach(findings.indices, id: \.self) { index in
                                            Label(findings[index].summary, systemImage: "exclamationmark.triangle")
                                                .font(.caption).foregroundStyle(.orange)
                                        }
                                        Text("Geometry is advisory; constraints are not remotely enumerated.")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if let frame = entry.frame {
                                        Text("x: \(Int(frame.x)), y: \(Int(frame.y)), w: \(Int(frame.width)), h: \(Int(frame.height))")
                                            .font(.system(.caption, design: .monospaced))
                                    }
                                    ForEach(entry.attributes.keys.sorted(), id: \.self) { key in
                                        HStack {
                                            Text(key).foregroundStyle(.secondary)
                                            Spacer()
                                            Text(entry.attributes[key] ?? "").textSelection(.enabled)
                                        }.font(.caption)
                                    }
                                    if let image = decodedPreview {
                                        Image(nsImage: image).resizable().scaledToFit()
                                            .frame(maxHeight: 260)
                                            .accessibilityLabel("Explicitly authorized on-device screen preview")
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
                                    ForEach(entry.attributes.keys.sorted(), id: \.self) { key in
                                        HStack { Text(key); Spacer(); Text(entry.attributes[key] ?? "") }
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
                Text("\(filteredRows.count) / \(entries.count) entries")
                if let receivedAt = snapshotReceivedAt {
                    Text("• Snapshot \(receivedAt.formatted(date: .omitted, time: .standard))")
                }
                if domain == "inspector", !layoutFindings.isEmpty {
                    Text("• \(layoutFindings.count) geometry hints")
                        .foregroundStyle(.orange)
                }
                if !previousIDs.isEmpty {
                    Text("• \(presentIDs.subtracting(previousIDs).count) added, \(previousIDs.subtracting(presentIDs).count) removed")
                }
                Spacer()
                Text("Read-only by default • TLS + authorized Debug Agent")
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18)
        .onAppear { applyDiagnosticReply() }
        .onChange(of: bridge.diagnosticRevision) { _ in applyDiagnosticReply() }
        .onChange(of: selectedID) { _ in updatePreview() }
        .onChange(of: entryQuery) { _ in refreshFilteredRows() }
        .onChange(of: storageArea) { _ in resetDomainState(); applyDiagnosticReply() }
        .onChange(of: domain) { _ in resetDomainState(); applyDiagnosticReply() }
    }

    // Overview derived only from the actual view coordinates, not arbitrary script execution.
    private var perspective: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(.gray.opacity(0.10))
            ForEach(perspectiveEntries) { entry in
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
        .rotation3DEffect(.degrees(viewing3D ? 42 : 0), axis: (x: 1, y: -0.4, z: 0))
        .padding(.vertical, 35)
        .accessibilityLabel("View hierarchy perspective preview")
    }

    private func resetDomainState() {
        selectedID = nil
        previousIDs = []
        presentIDs = []
        indexedEntries = [:]
        children = [:]
        treeRows = []
        flatRows = []
        filteredRows = []
        snapshotReceivedAt = nil
        layoutFindings = [:]
        perspectiveEntries = []
        lastIndexedReplyID = nil
        lastIndexedFingerprint = nil
        lastIndexedSessionID = nil
        decodedPreview = nil
        previewCache.removeAllObjects()
    }

    /// Other workspaces and edit acknowledgements must not rebuild a 900-node
    /// Inspector tree or decode a preview again.
    private func applyDiagnosticReply() {
        guard let data = reply else {
            if lastIndexedReplyID != nil { resetDomainState() }
            return
        }
        guard data.id != lastIndexedReplyID else { return }
        if let previous = lastIndexedSessionID, previous != data.sessionID {
            resetDomainState()
        }
        lastIndexedSessionID = data.sessionID
        lastIndexedReplyID = data.id
        snapshotReceivedAt = Date()
        lastMessage = data.success ? nil : (data.message ?? "Diagnostic command rejected")
        let message = data.message ?? ""
        if message.hasPrefix("unchanged:") ||
           message == "Highlighted" || message == "Restored" ||
           message == "Applied (Debug only)" {
            return
        }
        if message.hasPrefix("fingerprint:"),
           lastIndexedFingerprint == String(message.dropFirst("fingerprint:".count)) {
            return
        }
        if message.hasPrefix("fingerprint:") {
            lastIndexedFingerprint = String(message.dropFirst("fingerprint:".count))
        }
        presentIDs = Set(data.entries.map(\.id))
        rebuildIndex()
    }

    private func rebuildIndex() {
        // Build all stable projections together instead of allocating three
        // independent mapped arrays on every authorized reply.
        let projection = StudioHierarchyProjection(entries: entries)
        flatRows = projection.flatRows
        perspectiveEntries = projection.perspectiveEntries
        indexedEntries = projection.indexedEntries
        children = projection.children
        layoutFindings = domain == "inspector" ? StudioLayoutAudit.analyze(entries) : [:]
        collapsedIDs = collapsedIDs.intersection(Set(indexedEntries.keys))
        rebuildVisibleRows()
        updatePreview()
    }

    private func rebuildVisibleRows() {
        treeRows = StudioHierarchyProjection.visibleRows(
            entries: entries, indexed: indexedEntries,
            children: children, collapsed: collapsedIDs)
        refreshFilteredRows()
    }

    private func refreshFilteredRows() {
        filteredRows = StudioDiagnosticSearch.filter(
            domain == "inspector" ? treeRows : flatRows, query: entryQuery)
    }

    private func updatePreview() {
        guard let entry = selected, let preview = entry.previewBase64,
              preview.count <= 320_000 else {
            decodedPreview = nil
            return
        }
        previewCache.countLimit = 12
        previewCache.totalCostLimit = 12 * 1024 * 1024
        let key = NSString(string: "\(lastIndexedSessionID?.uuidString ?? ""):\(entry.id):\(preview.hashValue)")
        if let cached = previewCache.object(forKey: key) {
            decodedPreview = cached
            return
        }
        guard let bytes = Data(base64Encoded: preview),
              let image = NSImage(data: bytes) else {
            decodedPreview = nil
            return
        }
        previewCache.setObject(image, forKey: key, cost: bytes.count)
        decodedPreview = image
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
