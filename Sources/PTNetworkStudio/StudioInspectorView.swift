import SwiftUI

/// Read-only remote UIKit tree. A paired, opt-in agent must be running on the device.
@MainActor
struct StudioInspectorView: View {
    @ObservedObject var bridge: StudioBridgeController
    @ObservedObject var diagnostics: StudioDiagnosticStore
    @State private var selectedID: String?
    @State private var previewMode = "Tree"
    @State private var archiveError: String?
    @State private var editKey = "alpha"
    @State private var editValue = "1.0"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inspector").font(.title2.bold())
                Picker("Preview", selection: $previewMode) {
                    ForEach(["Tree", "2D", "3D"], id: \.self) { Text($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 180)
                Spacer()
                Button("Export Snapshot…") {
                    do { try StudioInspectorArchives.export(diagnostics.inspector) }
                    catch { archiveError = "Could not export the snapshot" }
                }.disabled(diagnostics.inspector.isEmpty)
                Text(bridge.diagnosticSessions.isEmpty ? "No Agent" : "Agent Connected")
                    .foregroundStyle(bridge.diagnosticSessions.isEmpty ? .secondary : .green)
                Button("Refresh Hierarchy") {
                    diagnostics.request("inspector", operation: "snapshot", bridge: bridge)
                }
                .disabled(bridge.diagnosticSessions.isEmpty)
            }.padding(14)
            Divider()
            if diagnostics.inspector.isEmpty {
                ContentUnavailableView(
                    "No hierarchy captured",
                    systemImage: "square.3.layers.3d",
                    description: Text("Start the secure Bridge in Network, enable the iOS diagnostic agent, then refresh the hierarchy.")
                )
            } else {
                HStack(spacing: 0) {
                    Group {
                    if previewMode == "2D" {
                        StudioHierarchy2DView(nodes: diagnostics.inspector, selectedID: selectedID)
                    } else if previewMode == "3D" {
                        StudioHierarchy3DView(nodes: diagnostics.inspector, selectedID: selectedID)
                    } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(diagnostics.inspector) { node in
                                Button {
                                    selectedID = node.id
                                } label: {
                                    HStack {
                                        Text(node.kind).font(.system(.caption, design: .monospaced))
                                        Spacer()
                                        if node.id == selectedID { Image(systemName: "checkmark") }
                                    }
                                    .padding(.leading, CGFloat(depth(for: node)) * 10)
                                    .padding(6)
                                    .background(node.id == selectedID ? Color.accentColor.opacity(0.2) : .clear)
                                }
                                .buttonStyle(.plain)
                            }
                        }.padding(8)
                    }
                    }
                    }.frame(minWidth: 260, maxWidth: .infinity)
                    Divider()
                    if let selected = diagnostics.inspector.first(where: { $0.id == selectedID }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(selected.kind).font(.headline)
                            Text(selected.name).foregroundStyle(.secondary)
                            ForEach(selected.attributes.keys.sorted(), id: \.self) { key in
                                HStack {
                                    Text(key).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(selected.attributes[key] ?? "")
                                        .textSelection(.enabled)
                                }.font(.caption)
                            }
                            if let rect = selected.frame {
                                Text("Frame: \(Int(rect.x)), \(Int(rect.y))  \(Int(rect.width))×\(Int(rect.height))")
                                    .font(.caption.monospacedDigit())
                            }
                            Divider()
                            Button("Highlight on iPhone") {
                                diagnostics.request("inspector", operation: "highlight",
                                                    targetID: selected.id, bridge: bridge)
                            }
                            .disabled(bridge.diagnosticSessions.isEmpty)
                            Text("Remote edit (must be permitted in the iOS Debug app)").font(.caption)
                            Picker("Property", selection: $editKey) {
                                Text("Alpha").tag("alpha")
                                Text("Hidden").tag("hidden")
                                Text("X").tag("frame.x")
                                Text("Y").tag("frame.y")
                                Text("Width").tag("frame.width")
                                Text("Height").tag("frame.height")
                            }.labelsHidden()
                            TextField("Value", text: $editValue)
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                Button("Apply") {
                                    diagnostics.request("inspector", operation: "setProperty",
                                                        targetID: selected.id,
                                                        arguments: ["key": editKey, "value": editValue],
                                                        bridge: bridge)
                                }
                                Button("Undo") {
                                    guard let undo = diagnostics.lastUndoID else { return }
                                    diagnostics.request("inspector", operation: "revert",
                                                        arguments: ["undoID": undo], bridge: bridge)
                                }.disabled(diagnostics.lastUndoID == nil)
                            }
                            .disabled(bridge.diagnosticSessions.isEmpty)
                            Spacer()
                        }.padding(16).frame(width: 330, alignment: .leading)
                    } else {
                        Text("Select a view").frame(width: 330)
                    }
                }
            }
            Text(diagnostics.diffSummary).font(.caption2).foregroundStyle(.secondary)
            if let archiveError {
                Text(archiveError).font(.caption).foregroundStyle(.red)
            }
            if let error = diagnostics.lastError {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            } else if let action = diagnostics.lastAction {
                Text(action).font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
    }

    private func depth(for node: StudioDiagnosticEntry) -> Int {
        let lookup = Dictionary(uniqueKeysWithValues: diagnostics.inspector.map { ($0.id, $0.parentID) })
        var parent = node.parentID
        var depth = 0
        while let current = parent, depth < 30 {
            depth += 1
            parent = lookup[current] ?? nil
        }
        return depth
    }
}
