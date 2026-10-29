import SwiftUI

/// Workspaces share one authenticated collector. Changing tabs must not tear down pairing.
@MainActor
struct StudioWorkspaceView: View {
    @EnvironmentObject private var store: CaptureStore
    @StateObject private var bridge = StudioBridgeController()
    @State private var workspace: Workspace = .network

    enum Workspace: String, CaseIterable, Identifiable {
        case network = "Network"
        case inspector = "Inspector"
        case storage = "Storage"
        case console = "Console"
        case performance = "Performance"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .network: "network"
            case .inspector: "square.3.layers.3d"
            case .storage: "externaldrive"
            case .console: "terminal"
            case .performance: "chart.xyaxis.line"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("PTools Studio")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                ForEach(Workspace.allCases) { item in
                    Button { workspace = item } label: {
                        HStack {
                            Image(systemName: item.icon).frame(width: 20)
                            Text(item.rawValue)
                            Spacer()
                        }
                        .padding(9)
                        .background(workspace == item ? Color.accentColor.opacity(0.18) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workspace.\(item.rawValue.lowercased())")
                }
                Spacer()
                Text(bridge.isRunning ? "Secure bridge active" : "Bridge not running")
                    .font(.caption2).foregroundStyle(.secondary).padding(12)
            }
            .frame(width: 176)
            Divider()
            Group {
                switch workspace {
                case .network:
                    StudioContentView()
                default:
                    ContentUnavailableView(
                        "\(workspace.rawValue) is not connected",
                        systemImage: workspace.icon,
                        description: Text("This workspace requires the opt-in PTools diagnostics agent. Network capture remains available without it.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environmentObject(bridge)
        .onDisappear {
            store.stop()
            bridge.stop()
        }
    }
}
