import Foundation
import AppKit
import Combine


// Shared by the macOS bridge and proxy engine. The 0.1 socket proxy used
// to declare this as `private`, which made it invisible in this file.
struct StudioRuntimeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Runtime-backed HTTPS interception powered by mitmdump's maintained TLS stack.
/// HTTPS is decrypted only when the user has deliberately trusted the local mitmproxy CA.
enum StudioPaths {
    static var home: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PTNetworkStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    static var rules: URL { home.appendingPathComponent("rules.json") }
    static var gates: URL {
        let folder = home.appendingPathComponent("gates", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    static var maps: URL {
        let folder = home.appendingPathComponent("maps", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    static var certificates: URL { home.appendingPathComponent("mitmproxy", isDirectory: true) }
    static var bridge: URL { home.appendingPathComponent("bridge", isDirectory: true) }

    static func backend(_ filename: String) throws -> URL {
        // Do not eagerly initialize Bundle.module when running the custom .app bundle:
        // its SwiftPM resource bundle may not be located beside the executable.
        if let main = Bundle.main.resourceURL?.appendingPathComponent("Backend").appendingPathComponent(filename),
           FileManager.default.fileExists(atPath: main.path) { return main }
        let resource = Bundle.module.resourceURL?.appendingPathComponent("Backend").appendingPathComponent(filename)
        if let resource, FileManager.default.fileExists(atPath: resource.path) { return resource }
        let sources = [
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Backend").appendingPathComponent(filename),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/PTNetworkStudio/Backend").appendingPathComponent(filename)
        ]
        if let resolved = sources.first(where: { FileManager.default.fileExists(atPath: $0.path) }) { return resolved }
        throw StudioRuntimeError("Backend/\(filename) missing. Run from source tree or use Scripts/build-macos.sh.")
    }

    static func executable(env: String, choices: [String]) -> URL? {
        let override = ProcessInfo.processInfo.environment[env].map { [$0] } ?? []
        let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for path in override + choices + searchPaths.flatMap({ p in choices.map { URL(fileURLWithPath: $0).lastPathComponent }.map { p + "/" + $0 } }) {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }
}

struct StudioRule: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    var enabled = true
    var kind = "rewriteRequest"
    var pattern = "*://example.com/*"
    var field = "header"
    var headerName = "X-Studio-Debug"
    var search = ""
    var replacement = "1"
    var fileName = ""
    var mimeType = "application/json"
    var status = 200
}

@MainActor
final class StudioRuleStore: ObservableObject {
    @Published var rules: [StudioRule] = [] { didSet { save() } }

    init() {
        if let data = try? Data(contentsOf: StudioPaths.rules),
           let decoded = try? JSONDecoder().decode([StudioRule].self, from: data) {
            rules = decoded
        } else { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        try? data.write(to: StudioPaths.rules, options: .atomic)
    }

    func addMappedFile(_ source: URL) throws -> String {
        let name = UUID().uuidString + "-" + source.lastPathComponent.replacingOccurrences(of: "/", with: "_")
        let dest = StudioPaths.maps.appendingPathComponent(name)
        let bytes = try Data(contentsOf: source)
        guard bytes.count <= 10 * 1024 * 1024 else { throw StudioRuntimeError("Map Local file must be at most 10 MB") }
        try bytes.write(to: dest, options: .atomic)
        return name
    }
}

/// Newline-delimited events from helper processes. The UI never parses mitmproxy log lines.
final class StudioProcessReader {
    private var buffer = Data()
    private let lock = NSLock()
    private let callback: ([String: Any]) -> Void
    init(callback: @escaping ([String: Any]) -> Void) { self.callback = callback }

    func attach(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.consume(data)
        }
    }

    private func consume(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        if buffer.count > 4 * 1024 * 1024 { buffer.removeAll(keepingCapacity: true) }
        var messages = [Data]()
        while let end = buffer.firstIndex(of: 10) {
            messages.append(Data(buffer[..<end]))
            buffer.removeSubrange(...end)
        }
        lock.unlock()
        for line in messages {
            let prefix = Data("PTSTUDIO:".utf8)
            guard line.starts(with: prefix),
                  let object = try? JSONSerialization.jsonObject(with: line.dropFirst(prefix.count)) as? [String: Any] else { continue }
            callback(object)
        }
    }
}

final class StudioMitmEngine {
    private var process: Process?
    private var reader: StudioProcessReader?
    private var output: Pipe?
    private(set) var currentRunID: UUID?

    var isRunning: Bool { process?.isRunning == true }

    func start(port: UInt16, exposeToLAN: Bool = false, proxyPassword: String = "",
               onMessage: @escaping ([String: Any]) -> Void) throws {
        if process != nil {
            if process?.isRunning == true { return }
            stop()
        }
        guard let mitmdump = StudioPaths.executable(env: "PTSTUDIO_MITMDUMP", choices: [
            "/opt/homebrew/bin/mitmdump", "/usr/local/bin/mitmdump", "/usr/bin/mitmdump"
        ]) else { throw StudioRuntimeError("HTTPS engine missing: install mitmproxy using 'brew install --cask mitmproxy' (then reopen app).") }
        if exposeToLAN && proxyPassword.count < 12 { throw StudioRuntimeError("LAN proxy requires a password at least 12 characters long") }
        let script = try StudioPaths.backend("studio_addon.py")
        try FileManager.default.createDirectory(at: StudioPaths.certificates, withIntermediateDirectories: true)
        // Never place proxy credentials in argv (`ps` would expose them).
        // JSON string notation is valid YAML; config.yaml is restricted to the current user.
        let credentials = exposeToLAN ? "studio:" + proxyPassword : ""
        let encoded = try JSONEncoder().encode(credentials)
        let serialized = String(data: encoded, encoding: .utf8) ?? "\"\""
        let config = "proxyauth: " + (exposeToLAN ? serialized : "null") + "\n"
        let configURL = StudioPaths.certificates.appendingPathComponent("config.yaml")
        try Data(config.utf8).write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        let p = Process()
        p.executableURL = mitmdump
        p.arguments = ["--listen-host", exposeToLAN ? "0.0.0.0" : "127.0.0.1",
                       "--listen-port", String(port), "--set", "confdir=\(StudioPaths.certificates.path)",
                       "--set", "ssl_insecure=false", "--set", "block_global=\(!exposeToLAN)",
                       "-s", script.path, "--quiet"]
        var environment = ProcessInfo.processInfo.environment
        environment["PTSTUDIO_RULES"] = StudioPaths.rules.path
        environment["PTSTUDIO_GATES"] = StudioPaths.gates.path
        environment["PTSTUDIO_MAPS"] = StudioPaths.maps.path
        p.environment = environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let reader = StudioProcessReader(callback: onMessage)
        reader.attach(pipe)
        do { try p.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        self.reader = reader
        self.output = pipe
        self.process = p
        let runID = UUID()
        self.currentRunID = runID
        p.terminationHandler = { process in
            onMessage(["type": "engineStopped", "runID": runID.uuidString,
                       "exitCode": Int(process.terminationStatus)])
        }
    }

    func decide(_ id: UUID, phase: String, action: String, changes: [String: Any] = [:]) throws {
        guard ["request", "response"].contains(phase), ["continue", "abort"].contains(action) else {
            throw StudioRuntimeError("Invalid breakpoint decision")
        }
        let payload: [String: Any] = ["action": action, "changes": changes]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: StudioPaths.gates.appendingPathComponent(id.uuidString.lowercased() + "." + phase + ".json"), options: .atomic)
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        output?.fileHandleForReading.readabilityHandler = nil
        output = nil
        reader = nil
        process = nil
        currentRunID = nil
    }
}

@MainActor
final class StudioBridgeController: ObservableObject {
    @Published private(set) var isStarting = false
    @Published var isRunning = false
    @Published var token = ""
    @Published var fingerprint = ""
    @Published private(set) var tlsHost = ""
    @Published private(set) var lastAuthenticatedPeerAt: Date?
    /// Ephemeral session UUIDs only; never a device hardware identifier.
    @Published private(set) var authenticatedSessions: [UUID: Date] = [:]
    @Published private(set) var receivedBridgeEntries = 0
    @Published var error: String?
    @Published private(set) var diagnosticResults: [String: StudioDiagnosticReply] = [:]
    @Published private(set) var diagnosticRevision = 0
    private var pendingDiagnosticDomains: [UUID: (domain: String, created: Date)] = [:]
    private var diagnosticFingerprints: [String: String] = [:]
    private var input: Pipe?
    let port = 9453

    private var process: Process?
    private var reader: StudioProcessReader?
    private var output: Pipe?
    private var runID: UUID?
    private var advertiser: StudioBonjourAdvertiser?
    var onEntry: ((CaptureEntry) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onReset: (() -> Void)?

    func start(host: String) {
        // Startup is asynchronous: prevent a second click from spawning a
        // competing collector before the first bridgeReady message arrives.
        guard !isRunning, !isStarting, process == nil else { return }
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.error = "Enter a reachable Mac LAN IP before starting the bridge."
            return
        }
        self.error = nil
        self.isStarting = true
        self.token = ""
        self.fingerprint = ""
        self.authenticatedSessions = [:]
        self.receivedBridgeEntries = 0
        do {
            guard let python = StudioPaths.executable(env: "PTSTUDIO_PYTHON", choices: [
                "/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"
            ]) else { throw StudioRuntimeError("python3 is required for the secure bridge") }
            let script = try StudioPaths.backend("bridge_server.py")
            let p = Process()
            p.executableURL = python
            p.arguments = [script.path, StudioPaths.bridge.path, String(port), host.trimmingCharacters(in: .whitespacesAndNewlines)]
            let pipe = Pipe()
            let commandPipe = Pipe()
            p.standardInput = commandPipe
            p.standardOutput = pipe
            p.standardError = pipe
            self.input = commandPipe
            let launchedRunID = UUID()
            let reader = StudioProcessReader { [weak self] message in
                let decodedEntry: CaptureEntry? = {
                    guard message["type"] as? String == "entry",
                          let raw = message["entry"],
                          let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
                    return try? JSONDecoder().decode(CaptureEntry.self, from: data)
                }()
                // JSON serialization and a potentially 1,200-node Inspector decode
                // run on the pipe reader, not on MainActor/SwiftUI's render path.
                let decodedReply: StudioDiagnosticReply? = {
                    guard message["type"] as? String == "diagnosticReply",
                          let raw = message["reply"],
                          let data = try? JSONSerialization.data(withJSONObject: raw),
                          let value = try? JSONDecoder().decode(StudioDiagnosticReply.self, from: data),
                          value.schemaVersion == 2 else { return nil }
                    return value
                }()
                Task { @MainActor in
                    guard let self, self.runID == launchedRunID else { return }
                    if let type = message["type"] as? String, type == "bridgeReady" {
                        self.token = message["token"] as? String ?? ""
                        self.fingerprint = message["fingerprint"] as? String ?? ""
                        self.tlsHost = message["host"] as? String ?? ""
                        self.isStarting = false
                        self.isRunning = true
                        let advertiser = StudioBonjourAdvertiser(port: self.port, tlsHost: self.tlsHost)
                        advertiser.onFailure = { [weak self] reason in
                            self?.error = reason
                        }
                        self.advertiser = advertiser
                        advertiser.start()
                    } else if message["type"] as? String == "bridgePeer",
                              let raw = message["sessionID"] as? String,
                              let sessionID = UUID(uuidString: raw) {
                        // Collector emits this only on authenticated hello/heartbeat.
                        // A newly authenticated iPhone must never inherit another
                        // session's Inspector/Storage/Console cached snapshots.
                        if self.diagnosticResults.values.contains(where: { $0.sessionID != sessionID }) {
                            self.diagnosticResults.removeAll()
                            self.diagnosticFingerprints.removeAll()
                            self.pendingDiagnosticDomains.removeAll()
                            self.diagnosticRevision += 1
                        }
                        let now = Date()
                        self.lastAuthenticatedPeerAt = now
                        self.authenticatedSessions = self.authenticatedSessions.filter {
                            now.timeIntervalSince($0.value) < 120
                        }
                        self.authenticatedSessions[sessionID] = now
                    } else if message["type"] as? String == "entry",
                              let entry = decodedEntry {
                        self.receivedBridgeEntries += 1
                        self.onEntry?(entry)
                    } else if message["type"] as? String == "bridgeDelete",
                              let raw = message["requestID"] as? String,
                              let requestID = UUID(uuidString: raw) {
                        self.onDelete?(requestID)
                    } else if message["type"] as? String == "bridgeReset" {
                        self.onReset?()
                    } else if message["type"] as? String == "diagnosticReply",
                              let reply = decodedReply,
                              let pending = self.pendingDiagnosticDomains.removeValue(forKey: reply.id),
                              self.authenticatedSessions[reply.sessionID] != nil {
                        if reply.success, let message = reply.message {
                            if message.hasPrefix("fingerprint:") || message.hasPrefix("unchanged:") {
                                self.diagnosticFingerprints[pending.domain] =
                                    String(message.split(separator: ":", maxSplits: 1).last ?? "")
                            }
                        }
                        // Highlight/edit/undo and unchanged snapshots contain no new tree.
                        // Preserve the previous snapshot until the user selects Refresh.
                        if reply.entries.isEmpty,
                           let previous = self.diagnosticResults[pending.domain] {
                            self.diagnosticResults[pending.domain] = StudioDiagnosticReply(
                                schemaVersion: reply.schemaVersion, id: reply.id,
                                sessionID: reply.sessionID, success: reply.success,
                                message: reply.message, entries: previous.entries)
                        } else {
                            self.diagnosticResults[pending.domain] = reply
                        }
                        self.diagnosticRevision += 1
                    } else if message["type"] as? String == "diagnosticRejected" {
                        self.error = message["reason"] as? String ?? "Diagnostic request refused"
                    } else if let value = message["text"] as? String { self.error = value }
                }
            }
            reader.attach(pipe)
            self.reader = reader
            self.output = pipe
            self.process = p
            self.runID = launchedRunID
            // Register before run(): a fast Python exit (bad IP/occupied port)
            // must not leave the UI stuck in Starting.
            p.terminationHandler = { [weak self] ended in
                let exitCode = Int(ended.terminationStatus)
                Task { @MainActor in
                    guard let self, self.runID == launchedRunID else { return }
                    let reportedFailure = self.error
                    self.stop()
                    self.error = reportedFailure ?? "Bridge exited (code \(exitCode)). Check TCP 9453, the firewall, Python and the TLS certificate chain."
                }
            }
            try p.run()
        } catch {
            stop()
            self.error = error.localizedDescription
        }
    }

    func stop() {
        // Invalidate the run first so late stdout/termination callbacks cannot
        // restart or overwrite the state of a new bridge instance.
        runID = nil
        advertiser?.stop()
        advertiser = nil
        if let p = process, p.isRunning { p.terminate() }
        output?.fileHandleForReading.readabilityHandler = nil
        output = nil
        try? input?.fileHandleForWriting.close()
        input = nil
        reader = nil
        process = nil
        pendingDiagnosticDomains.removeAll()
        diagnosticFingerprints.removeAll()
        diagnosticResults.removeAll()
        diagnosticRevision += 1
        isStarting = false
        isRunning = false
        token = ""
        fingerprint = ""
        tlsHost = ""
        lastAuthenticatedPeerAt = nil
        authenticatedSessions = [:]
        receivedBridgeEntries = 0
    }

    /// Queue a bounded command to the local child process, not over an unauthenticated LAN port.
    @discardableResult
    func sendDiagnostic(domain: String, operation: String,
                        targetID: String? = nil, arguments: [String: String] = [:]) -> Bool {
        pendingDiagnosticDomains = pendingDiagnosticDomains.filter {
            Date().timeIntervalSince($0.value.created) < 50
        }
        let live = authenticatedSessions.filter { Date().timeIntervalSince($0.value) < 100 }
        // Do not guess which device to mutate when multiple Debug iPhones are paired.
        guard isRunning, let input, live.count == 1, let session = live.first?.key,
              pendingDiagnosticDomains.count < 32 else { return false }
        var effectiveArguments = arguments
        if operation == "snapshot", let fingerprint = diagnosticFingerprints[domain] {
            effectiveArguments["knownFingerprint"] = fingerprint
        }
        let request = StudioDiagnosticCommand(
            id: UUID(), sessionID: session, domain: domain,
            operation: operation, targetID: targetID, arguments: effectiveArguments)
        guard let data = try? JSONEncoder().encode(request),
              data.count < 8192 else { return false }
        do {
            try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
            pendingDiagnosticDomains[request.id] = (domain: domain, created: Date())
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Revoke a leaked or stale pairing token while no collector is listening.
    func rotatePairingToken() {
        guard !isRunning, !isStarting, process == nil else {
            self.error = "Stop the Bridge before rotating its pairing token."
            return
        }
        do {
            let tokenFile = StudioPaths.bridge.appendingPathComponent("bridge-token-v2")
            if FileManager.default.fileExists(atPath: tokenFile.path) {
                try FileManager.default.removeItem(at: tokenFile)
            }
            token = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
