import SwiftUI

/// Read-only remote UIKit tree. A paired, opt-in agent must be running on the device.
@MainActor
struct StudioInspectorView: View {
    @ObservedObject var bridge: StudioBridgeController
    @ObservedObject var diagnostics: StudioDiagnosticStore
    @State private var selectedID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inspector").font(.title2.bold())
                Spacer()
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
                            Spacer()
                        }.padding(16).frame(width: 330, alignment: .leading)
                    } else {
                        Text("Select a view").frame(width: 330)
                    }
                }
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
