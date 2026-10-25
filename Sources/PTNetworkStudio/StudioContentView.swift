import SwiftUI
import AppKit

private struct HostCount: Identifiable {
    var name: String
    var count: Int
    var id: String { name }
}

private enum Scope: Hashable {
    case all, http, https, failed, host(String)
}

@MainActor
struct StudioContentView: View {
    @EnvironmentObject private var store: CaptureStore
    @State private var scope: Scope = .all
    @State private var selectedID: UUID?
    @State private var search = ""
    @State private var port = "9090"
    @State private var showComposer = false
    @State private var inspectorTab = 0
    @State private var showGuide = false
    @State private var showRules = false
    @State private var showBridge = false
    @State private var showProxySettings = false
    @State private var showBreakpoint = false
    @StateObject private var ruleStore = StudioRuleStore()
    @StateObject private var bridge = StudioBridgeController()

    private var hosts: [HostCount] {
        let groups = Dictionary(grouping: store.entries, by: \.host)
        return groups.map { HostCount(name: $0.key, count: $0.value.count) }.sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    private var filteredEntries: [CaptureEntry] {
        store.entries.filter { item in
            let scopeMatches: Bool
            switch scope {
            case .all: scopeMatches = true
            case .http: scopeMatches = !item.isTunnel && item.url.hasPrefix("http://")
            case .https: scopeMatches = item.isTunnel || item.url.hasPrefix("https://")
            case .failed: scopeMatches = item.error != nil || (item.status ?? 0) >= 400
            case .host(let host): scopeMatches = item.host == host
            }
            let textMatches = search.isEmpty || [item.url, item.method, item.host, item.statusText].contains { $0.localizedCaseInsensitiveContains(search) }
            return scopeMatches && textMatches
        }.reversed()
    }

    private var selectedEntry: CaptureEntry? {
        store.entries.first(where: { $0.id == selectedID })
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 216)
            Divider()
            flowPane.frame(minWidth: 425, maxWidth: .infinity)
            Divider()
            inspector.frame(width: 395)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(.cyan)
                    Text("PTNetwork Studio").fontWeight(.semibold)
                    Text("1.0.2").font(.caption2).foregroundStyle(.secondary)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                TextField("Port", text: $port)
                    .frame(width: 52)
                    .textFieldStyle(.roundedBorder)
                    .disabled(store.isRunning)
                    .help("127.0.0.1 local proxy port")
                Button {
                    if store.isRunning { store.stop() }
                    else if let value = UInt16(port) { store.start(port: value) }
                    else { store.lastError = "Port must be 1...65535" }
                } label: {
                    Label(store.isRunning ? "Stop" : "Capture", systemImage: store.isRunning ? "stop.fill" : "play.fill")
                }
                .tint(store.isRunning ? .red : .green)
                Button { showComposer = true } label: { Label("Compose", systemImage: "square.and.pencil") }
                Button { store.clear(); selectedID = nil } label: { Label("Clear", systemImage: "trash") }
                Menu {
                    Button("Export Session JSON…") { doFileAction { try SessionFiles.exportSession(store.entries) } }
                    Button("Export HAR…") { doFileAction { try SessionFiles.exportHAR(store.entries) } }
                    Divider()
                    Button("Import Session JSON…") {
                        doFileAction { if let loaded = try SessionFiles.importSession() { store.replace(loaded); selectedID = nil } }
                    }
                    Button("Import HAR (including PTools)…") {
                        doFileAction { if let loaded = try SessionFiles.importHAR() { store.replace(loaded); selectedID = nil } }
                    }
                } label: { Label("Session", systemImage: "square.and.arrow.up") }
                Button { showProxySettings = true } label: { Label("Network", systemImage: "network") }
                Button { showRules = true } label: { Label("Rules", systemImage: "line.3.horizontal.decrease.circle") }
                Button { showBridge = true } label: { Label("iPhone", systemImage: "iphone.gen3.radiowaves.left.and.right") }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([StudioPaths.certificates.appendingPathComponent("mitmproxy-ca-cert.pem")])
                } label: { Label("CA", systemImage: "checkmark.shield") }
                Button { showGuide = true } label: { Label("Setup", systemImage: "questionmark.circle") }
            }
        }
        .onDisappear {
            store.stop()
            bridge.stop()
        }
        .sheet(isPresented: $showComposer) { ComposerSheet().environmentObject(store) }
        .sheet(isPresented: $showGuide) { SetupGuide() }
        .sheet(isPresented: $showRules) { RuleManagerSheet(rules: ruleStore) }
        .sheet(isPresented: $showProxySettings) { ProxySettingsSheet().environmentObject(store) }
        .sheet(isPresented: $showBridge) { BridgeSetupSheet(bridge: bridge).environmentObject(store) }
        .sheet(isPresented: $showBreakpoint) {
            if let entry = selectedEntry, let phase = store.paused[entry.id] {
                BreakpointSheet(entry: entry, phase: phase) { action, changes in
                    store.decide(entry.id, action: action, changes: changes)
                }
            }
        }
        .alert("PTNetwork Studio", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK", role: .cancel) { store.lastError = nil }
        } message: { Text(store.lastError ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(store.isRunning ? .green : .gray).frame(width: 7, height: 7)
                Text(store.isRunning ? "CAPTURING" : "STOPPED")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.entries.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 18)

            sidebarHeading("QUICK FILTERS")
            scopeRow("All Traffic", icon: "arrow.left.arrow.right", scope: .all, count: store.entries.count)
            scopeRow("HTTP", icon: "globe", scope: .http, count: store.entries.filter { $0.url.hasPrefix("http://") }.count)
            scopeRow("HTTPS (decrypted)", icon: "lock.shield", scope: .https, count: store.entries.filter { $0.url.hasPrefix("https://") }.count)
            if !store.paused.isEmpty {
                HStack {
                    Label("Paused: \(store.paused.count)", systemImage: "pause.circle.fill").foregroundStyle(.orange)
                    Spacer()
                }.font(.caption).padding(.horizontal, 15).padding(.vertical, 8)
            }
            scopeRow("Errors", icon: "exclamationmark.triangle", scope: .failed, count: store.entries.filter { $0.error != nil || ($0.status ?? 0) >= 400 }.count)
            Divider().padding(.vertical, 14)
            sidebarHeading("DOMAINS")
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(hosts) { pair in
                        scopeRow(pair.name, icon: "network", scope: .host(pair.name), count: pair.count)
                    }
                }.padding(.bottom, 18)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 7) {
                Label(store.exposeToLAN ? "LAN proxy: password required" : "Localhost proxy", systemImage: "lock.fill")
                    .foregroundStyle(.secondary).font(.caption)
                Text("127.0.0.1:\(port)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.12))
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(1.1).foregroundStyle(.tertiary)
            .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private func scopeRow(_ title: String, icon: String, scope target: Scope, count: Int) -> some View {
        Button { scope = target; selectedID = nil } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 17).foregroundStyle(scope == target ? Color.cyan : Color.secondary)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                Text("\(count)").foregroundStyle(.tertiary).font(.caption)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(scope == target ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 7)
    }

    private var flowPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Network Traffic").font(.title3.weight(.semibold))
                    Text("\(filteredEntries.count) flows • HTTP/HTTPS inspector • live rules")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter URL, host, method, status", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            .padding(15)
            Divider()
            HStack {
                Text("METHOD").frame(width: 65, alignment: .leading)
                Text("HOST / PATH").frame(maxWidth: .infinity, alignment: .leading)
                Text("STATUS").frame(width: 65, alignment: .trailing)
                Text("TIME").frame(width: 65, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 9)
            Divider()
            if filteredEntries.isEmpty {
                ContentUnavailableView("No traffic yet", systemImage: "network", description: Text("Start capture, then configure an app's HTTP/HTTPS proxy to 127.0.0.1:\(port)."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(filteredEntries) { entry in
                        FlowRow(entry: entry).tag(entry.id)
                    }
                }
                .listStyle(.plain)
            }
            Divider()
            HStack {
                Label("\(store.entries.count) requests", systemImage: "circle.grid.2x2")
                Spacer()
                Text("Sanitized previews • max 1,000 flows")
            }.foregroundStyle(.secondary).font(.caption2).padding(.horizontal, 15).padding(.vertical, 9)
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let entry = selectedEntry {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Inspector").font(.title3.weight(.semibold))
                        Text(entry.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let phase = store.paused[entry.id] {
                        Button("Paused: \(phase) — Resolve") { showBreakpoint = true }.tint(.orange)
                    }
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.curlCommand(), forType: .string) } label: {
                        Label("cURL", systemImage: "terminal")
                    }
                }.padding(16)
                Divider()
                Picker("", selection: $inspectorTab) {
                    Text("Request").tag(0)
                    Text("Response").tag(1)
                    Text("Summary").tag(2)
                }.pickerStyle(.segmented).padding(14)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if inspectorTab == 2 {
                            kv("Started", entry.startedAt.formatted(date: .abbreviated, time: .standard))
                            kv("Source", entry.source)
                            kv("Method", entry.method)
                            kv("URL", entry.url)
                            kv("Status", entry.statusText)
                            kv("Duration", entry.duration.map { String(format: "%.0f ms", $0 * 1000) } ?? "—")
                            kv("Received", ByteCountFormatter.string(fromByteCount: Int64(entry.responseSize), countStyle: .file))
                            if entry.isTunnel { info("HTTPS is opaque. Only the CONNECT destination is shown; no decrypted HTTPS content is available.") }
                            if let error = entry.error { info("Error: " + error) }
                        } else {
                            let headers = inspectorTab == 0 ? entry.requestHeaders : entry.responseHeaders
                            let body = inspectorTab == 0 ? entry.requestBody : entry.responseBody
                            if inspectorTab == 0 { kv("URL", entry.url) }
                            else { kv("Status", entry.statusText) }
                            sectionHeading("HEADERS")
                            if headers.isEmpty { info("No headers available") }
                            ForEach(headers.keys.sorted(), id: \.self) { key in
                                kv(key, headers[key] ?? "")
                            }
                            Divider().padding(.vertical, 4)
                            sectionHeading("BODY PREVIEW")
                            Text(body.isEmpty ? (entry.isTunnel ? "Encrypted tunnel: no plaintext payload" : "Empty / not captured") : body)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }.padding(15)
                }
            } else {
                ContentUnavailableView("Select a request", systemImage: "doc.text.magnifyingglass", description: Text("Inspect request headers, redacted bodies, response status and timing."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func sectionHeading(_ value: String) -> some View {
        Text(value).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).tracking(1)
    }
    private func kv(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func info(_ value: String) -> some View {
        Text(value).font(.caption).foregroundStyle(.secondary).padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }
    private func doFileAction(_ action: () throws -> Void) {
        do { try action() } catch { store.lastError = error.localizedDescription }
    }
}

private struct FlowRow: View {
    let entry: CaptureEntry
    private var methodColor: Color {
        switch entry.method {
        case "GET": .green
        case "POST": .blue
        case "CONNECT": .purple
        case "DELETE": .red
        default: .orange
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.method)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(methodColor)
                .frame(width: 65, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.host).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(entry.url).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.statusText).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle((entry.status ?? 0) >= 400 ? Color.red : Color.primary)
                .frame(width: 65, alignment: .trailing)
            Text(entry.duration.map { String(format: "%.0fms", $0 * 1000) } ?? "—")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 65, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .help(entry.url)
    }
}

private struct SetupGuide: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Proxy / HTTPS Decryption").font(.title2.bold())
            Text("1. Install official mitmproxy (brew install --cask mitmproxy). Launch Capture on port 9090.")
            Text("2. Configure the target app/browser proxy: 127.0.0.1:9090. HTTP and HTTPS will pass through mitmproxy.")
            Text("3. To decrypt HTTPS, open CA from the toolbar. Add mitmproxy-ca-cert.pem to your login Keychain and explicitly mark it trusted for SSL in Keychain Access. Trust this CA only on devices you control. It can intercept secure traffic.")
            Text("4. Rules → Add Rule for request/response Rewrite, Map Local or Breakpoint; select a paused request and use Resolve.")
            Text("5. iPhone → Start Bridge for an opt-in encrypted SDK capture stream (separate from HTTP proxy); copy the adapter into PTools DebugNetwork.")
            Text("6. A third-party iPhone HTTPS proxy requires a LAN-reachable listener, Wi-Fi proxy authentication, and device trust of the mitmproxy CA. This build defaults to loopback and does not change system proxy settings.")
            Text("Security: capture only traffic that you own or are authorized to inspect. Sensitive fields are redacted in UI and export. Certificate-pinned clients cannot be forced to trust interception.")
                .font(.caption).foregroundStyle(.orange)
            Spacer()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(27).frame(width: 710, height: 560)
    }
}
