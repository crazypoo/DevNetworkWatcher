import SwiftUI

/// Storage scope is granted by the iOS host: a selected directory, defaults keys
/// and database URLs. The desktop never receives raw filesystem access.
@MainActor
struct StudioStorageView: View {
    @ObservedObject var bridge: StudioBridgeController
    @ObservedObject var diagnostics: StudioDiagnosticStore
    @State private var category: Category = .files
    @State private var relativePath = ""
    @State private var databaseIndex = "0"
    @State private var selectedEntry: String?
    @State private var newValue = ""
    @State private var newType = "string"

    enum Category: String, CaseIterable, Identifiable {
        case files = "Files"
        case defaults = "Defaults"
        case database = "Database"
        var id: String { rawValue }
        var domain: String {
            switch self {
            case .files: "storage"
            case .defaults: "defaults"
            case .database: "database"
            }
        }
        var operation: String {
            switch self {
            case .files: "list"
            case .defaults: "list"
            case .database: "schema"
            }
        }
    }

    private var entries: [StudioDiagnosticEntry] {
        diagnostics.latest[category.domain + "." + category.operation] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Storage").font(.title2.bold())
                Picker("Scope", selection: $category) {
                    ForEach(Category.allCases) { choice in Text(choice.rawValue).tag(choice) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 330)
                Spacer()
                Button("Refresh") { refresh() }
                    .disabled(bridge.diagnosticSessions.isEmpty)
            }.padding(14)
            HStack {
                if category == .files {
                    TextField("Relative path within approved root", text: $relativePath)
                        .textFieldStyle(.roundedBorder)
                } else if category == .database {
                    Text("Host-approved database index")
                    TextField("Index", text: $databaseIndex).frame(width: 50)
                } else {
                    Text("Only UserDefaults keys explicitly allowlisted by the app are visible.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 14).padding(.bottom, 10)
            Divider()
            HStack(spacing: 0) {
                List(entries, selection: $selectedEntry) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(item.name, systemImage: symbol(item.kind))
                        if let details = item.attributes["size"] {
                            Text(details + " bytes").font(.caption2).foregroundStyle(.secondary)
                        }
                    }.tag(item.id)
                }
                .frame(minWidth: 310)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if let entry = entries.first(where: { $0.id == selectedEntry }) {
                        Text(entry.name).font(.headline)
                        Text(entry.kind).font(.caption).foregroundStyle(.secondary)
                        ForEach(entry.attributes.keys.sorted(), id: \.self) { key in
                            HStack(alignment: .top) {
                                Text(key).foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.attributes[key] ?? "").textSelection(.enabled)
                            }.font(.caption)
                        }
                        if category == .files && entry.kind == "folder" {
                            Button("Open Directory") {
                                relativePath = entry.id
                                refresh()
                            }
                        }
                        if category == .defaults {
                            Divider()
                            Text("Edit only with explicit iOS host write permission")
                                .font(.caption).foregroundStyle(.secondary)
                            Picker("Type", selection: $newType) {
                                ForEach(["string", "bool", "integer", "double"], id: \.self) { Text($0) }
                            }
                            TextField("New value", text: $newValue)
                                .textFieldStyle(.roundedBorder)
                            Button("Apply") {
                                diagnostics.request("defaults", operation: "set", targetID: entry.id,
                                                    arguments: ["type": newType, "value": newValue],
                                                    bridge: bridge)
                            }
                            .disabled(bridge.diagnosticSessions.isEmpty)
                        }
                    } else {
                        Text("Select an item. Only explicitly approved sandbox resources are exposed.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = diagnostics.lastError {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
    }

    private func refresh() {
        var args: [String: String] = [:]
        if category == .files { args["path"] = relativePath }
        if category == .database { args["index"] = databaseIndex }
        selectedEntry = nil
        diagnostics.request(category.domain, operation: category.operation,
                            arguments: args, bridge: bridge)
    }

    private func symbol(_ kind: String) -> String {
        switch kind {
        case "folder": "folder"
        case "table": "tablecells"
        case "view": "eye"
        case "default": "slider.horizontal.3"
        default: "doc"
        }
    }
}
