import SwiftUI
import AppKit

struct RuleManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var rules: StudioRuleStore
    @State private var editing = StudioRule()
    @State private var showEditor = false
    @State private var editIndex: Int?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Traffic Rules").font(.title2.bold())
                    Text("Glob URL matching • first Map Local response wins • ordered evaluation")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Rule") { editing = StudioRule(); editIndex = nil; showEditor = true }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(20)
            Divider()
            List {
                ForEach(rules.rules.indices, id: \.self) { idx in
                    let rule = rules.rules[idx]
                    HStack {
                        Toggle("", isOn: Binding(get: { rules.rules[idx].enabled }, set: { rules.rules[idx].enabled = $0 }))
                            .labelsHidden()
                        VStack(alignment: .leading) {
                            Text(rule.kind).font(.body.weight(.medium))
                            Text(rule.pattern).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editing = rule; editIndex = idx; showEditor = true }
                        Button(role: .destructive) { rules.rules.remove(at: idx) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }.padding(.vertical, 3)
                }
                .onMove { source, destination in rules.rules.move(fromOffsets: source, toOffset: destination) }
            }
            if rules.rules.isEmpty {
                Text("No rules configured. Add Map Local, Rewrite, or Breakpoint rules.")
                    .font(.caption).foregroundStyle(.secondary).padding(16)
            }
        }
        .frame(width: 700, height: 490)
        .sheet(isPresented: $showEditor) {
            RuleEditorSheet(rule: $editing, rules: rules) {
                if let idx = editIndex { rules.rules[idx] = editing }
                else { rules.rules.append(editing) }
                showEditor = false
            }
        }
    }
}

struct RuleEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var rule: StudioRule
    @ObservedObject var rules: StudioRuleStore
    let save: () -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Edit Traffic Rule").font(.title2.bold())
            Form {
                Toggle("Enabled", isOn: $rule.enabled)
                Picker("Action", selection: $rule.kind) {
                    Text("Rewrite Request").tag("rewriteRequest")
                    Text("Rewrite Response").tag("rewriteResponse")
                    Text("Map Local").tag("mapLocal")
                    Text("Breakpoint Request").tag("breakRequest")
                    Text("Breakpoint Response").tag("breakResponse")
                }
                TextField("URL wildcard", text: $rule.pattern)
                    .help("Example: *://api.example.com/*; wildcard * or ?")
                if rule.kind == "rewriteRequest" || rule.kind == "rewriteResponse" {
                    Picker("Field", selection: $rule.field) {
                        Text("Header").tag("header")
                        Text("Body literal replace").tag("body")
                        if rule.kind == "rewriteRequest" { Text("URL literal replace").tag("url") }
                    }
                    if rule.field == "header" { TextField("Header name", text: $rule.headerName) }
                    else { TextField("Find (literal)", text: $rule.search) }
                    TextField("Value / Replace with", text: $rule.replacement)
                }
                if rule.kind == "mapLocal" {
                    HStack {
                        Text("Local response file")
                        Spacer()
                        Text(rule.fileName.isEmpty ? "Not selected" : rule.fileName)
                            .lineLimit(1).foregroundStyle(.secondary)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = false
                            if panel.runModal() == .OK, let url = panel.url {
                                do { rule.fileName = try rules.addMappedFile(url) }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                    TextField("Content-Type", text: $rule.mimeType)
                    TextField("HTTP Status", value: $rule.status, format: .number)
                }
                if rule.kind.hasPrefix("break") {
                    Text("Matched flows pause for up to 60 seconds. Continue, modify, or abort from the inspector. After timeout, traffic resumes without changes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.pattern.isEmpty || (rule.kind == "mapLocal" && rule.fileName.isEmpty))
            }
        }.padding(22).frame(width: 570, height: 490)
    }
}

struct BreakpointSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: CaptureEntry
    let phase: String
    let decide: (String, [String: Any]) -> Void
    @State private var changedURL = ""
    @State private var changedBody = ""
    @State private var changedStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("Paused \(phase.capitalized)", systemImage: "pause.circle.fill").font(.title2.bold())
            Text(entry.url).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("Leave a field blank to keep the original. Secret headers are never surfaced to this editor.")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                if phase == "request" { TextField("Override URL (optional)", text: $changedURL) }
                TextField("Override body as UTF-8 (optional)", text: $changedBody, axis: .vertical)
                    .lineLimit(3...6)
                if phase == "response" { TextField("Override HTTP status (optional)", text: $changedStatus) }
            }.formStyle(.grouped)
            HStack {
                Button("Abort (HTTP 418)", role: .destructive) { decide("abort", [:]); dismiss() }
                Spacer()
                Button("Continue") {
                    var changes: [String: Any] = [:]
                    if !changedURL.isEmpty { changes["url"] = changedURL }
                    if !changedBody.isEmpty { changes["body"] = changedBody }
                    if let code = Int(changedStatus) { changes["status"] = code }
                    decide("continue", changes)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 590, height: 365)
    }
}

struct BridgeSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var bridge: StudioBridgeController
    @EnvironmentObject var store: CaptureStore
    @AppStorage("PTStudio.autoStartBridge") private var autoStartBridge = false
    @State private var macIP = UserDefaults.standard.string(forKey: "PTStudio.bridgeHost")
        ?? StudioBonjourAdvertiser.defaultHost

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("PTools → Mac Live Bridge").font(.title2.bold())
            Text("TLS 1.2+ • SHA-256 certificate pinning • 256-bit pairing token • redacted events")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(bridge.isRunning ? "Listening on port \(bridge.port)" : (bridge.isStarting ? "Starting secure collector…" : "Stopped"))
                Spacer()
                Button(bridge.isRunning ? "Stop Bridge" : (bridge.isStarting ? "Starting…" : "Start Bridge")) {
                    if bridge.isRunning { bridge.stop() }
                    else {
                        bridge.onEntry = { [weak store] entry in store?.upsert(entry) }
                        bridge.onDelete = { [weak store] id in store?.removeLiveRequest(id) }
                        bridge.onReset = { [weak store] in store?.resetLiveRequests() }
                        UserDefaults.standard.set(macIP, forKey: "PTStudio.bridgeHost")
                        bridge.start(host: macIP)
                    }
                }
                .disabled(bridge.isStarting)
            }
            Divider()
            Toggle("Start secure Bridge automatically when Studio opens", isOn: $autoStartBridge)
            TextField("TLS hostname (.local preferred), or manual LAN IP", text: $macIP)
                .textFieldStyle(.roundedBorder)
                .disabled(bridge.isRunning || bridge.isStarting)
            Text("Bonjour advertises _ptstudio._tcp on local Wi-Fi after the TLS collector is ready. Use the Mac's stable .local hostname for automatic reconnection across IP changes; a hostname change renews the leaf pin and requires re-pairing.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Bonjour ID: \(StudioBonjourAdvertiser.installationID) (public, not a secret)")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            if let lastPeer = bridge.lastAuthenticatedPeerAt {
                Text("Last authenticated PTools session: \(lastPeer.formatted())")
                    .font(.caption).foregroundStyle(.green)
            }
            Text("PToolsDebugStudioBridge configuration (schema v1):")
                .font(.callout.weight(.medium))
            VStack(alignment: .leading, spacing: 10) {
                parameter("endpoint", "https://\(macIP):\(bridge.port)/v1/events")
                parameter("bearerToken", bridge.token)
                parameter("leafCertificateSHA256 (hex)", bridge.fingerprint)
            }.padding(15).background(.black.opacity(0.17), in: RoundedRectangle(cornerRadius: 9))
            HStack {
                Button("Reveal Development CA (.cer)") {
                    NSWorkspace.shared.activateFileViewerSelecting([StudioPaths.bridge.appendingPathComponent("bridge-root-ca.cer")])
                }.disabled(!bridge.isRunning)
                Spacer()
                Button("Rotate Pairing Token") { bridge.rotatePairingToken() }
                    .disabled(bridge.isRunning || bridge.isStarting)
            }
            Text("Rotate after any token exposure, then restart Bridge and enter the new token on the iPhone. Existing pairings are revoked.")
                .font(.caption).foregroundStyle(.secondary)
            Text("On your authorized iPhone, install the generated CA profile and explicitly enable full trust in Settings → General → About → Certificate Trust Settings. Only then will PTools pass BOTH system trust and SHA-256 pinning. Never ship the CA or pairing token in an App Store build.")
                .font(.caption).foregroundStyle(.orange)
            if let error = bridge.error { Text(error).foregroundStyle(.red).font(.caption) }
            Spacer()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(23).frame(width: 680, height: 640)
    }
    private func parameter(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
            Text(value.isEmpty ? "Start bridge to generate" : value)
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }.disabled(value.isEmpty)
        }
    }
}

struct ProxySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: CaptureStore
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Proxy Network Settings").font(.title2.bold())
            Toggle("Allow authenticated LAN proxy clients", isOn: $store.exposeToLAN)
                .disabled(store.isRunning)
            if store.exposeToLAN {
                SecureField("Proxy password (minimum 12 characters)", text: $store.proxyPassword)
                    .disabled(store.isRunning)
                Text("iPhone Wi-Fi HTTP proxy: Mac LAN IP and port 9090; username studio + password above. Install and explicitly trust the mitmproxy CA on the device to see HTTPS payloads. Do not expose the listener to the Internet.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("By default Capture binds only to 127.0.0.1. The PTools Live Bridge uses a separate authenticated TLS listener on port 9453.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 540, height: 310)
    }
}
