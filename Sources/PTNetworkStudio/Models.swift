import Foundation
import Combine

struct CaptureEntry: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var startedAt: Date = .now
    var method: String
    var url: String
    var host: String
    var source: String = "Local Proxy"
    var status: Int?
    var duration: Double?
    var requestHeaders: [String: String] = [:]
    var responseHeaders: [String: String] = [:]
    var requestBody: String = ""
    var responseBody: String = ""
    var responseSize: Int = 0
    var error: String?

    var isTunnel: Bool { method == "CONNECT" }
    var statusText: String { status.map(String.init) ?? (error == nil ? "…" : "ERROR") }
}

struct StudioSession: Codable {
    var formatVersion: Int = 1
    var exportedAt: Date = .now
    var entries: [CaptureEntry]
}

@MainActor
final class CaptureStore: ObservableObject {
    @Published private(set) var entries: [CaptureEntry] = []
    @Published private(set) var isRunning = false
    @Published var lastError: String?
    private let engine = StudioMitmEngine()
    @Published private(set) var paused: [UUID: String] = [:]
    @Published var exposeToLAN = false
    @Published var proxyPassword = ""


    func start(port: UInt16) {
        guard !isRunning else { return }
        do {
            try engine.start(port: port, exposeToLAN: exposeToLAN, proxyPassword: proxyPassword) { [weak self] message in
                Task { @MainActor in self?.handleMessage(message) }
            }
            isRunning = true
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    func stop() {
        engine.stop()
        isRunning = false
        paused.removeAll()
    }

    private func handleMessage(_ message: [String: Any]) {
        let type = message["type"] as? String ?? ""
        if type == "notice" {
            if let text = message["text"] as? String { lastError = text }
            return
        }
        if type == "engineStopped" {
            guard let value = message["runID"] as? String,
                  UUID(uuidString: value) == engine.currentRunID else { return }
            let status = message["exitCode"] as? Int ?? -1
            engine.stop()
            isRunning = false
            paused.removeAll()
            if status != 0 { lastError = "HTTPS engine stopped (exit \(status)); check mitmdump installation and port 9090 availability." }
            return
        }
        if type == "resumed", let string = message["id"] as? String, let id = UUID(uuidString: string) {
            paused.removeValue(forKey: id)
            return
        }
        if let object = message["entry"],
           let data = try? JSONSerialization.data(withJSONObject: object),
           let entry = try? JSONDecoder().decode(CaptureEntry.self, from: data) {
            upsert(entry)
            if type == "paused", let phase = message["phase"] as? String { paused[entry.id] = phase }
        }
    }

    func decide(_ id: UUID, action: String, changes: [String: Any] = [:]) {
        guard let phase = paused[id] else { return }
        do { try engine.decide(id, phase: phase, action: action, changes: changes) }
        catch { lastError = error.localizedDescription }
    }

    func upsert(_ entry: CaptureEntry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) { entries[idx] = entry }
        else { add(entry) }
    }

    func clear() { entries.removeAll() }

    func removeLiveRequest(_ id: UUID) {
        entries.removeAll { $0.id == id && $0.source == "PTools Live" }
    }

    func resetLiveRequests() {
        entries.removeAll { $0.source == "PTools Live" }
    }

    func add(_ event: CaptureEntry) {
        entries.append(event)
        if entries.count > 1000 { entries.removeFirst(entries.count - 1000) }
    }

    func finish(_ id: UUID, status: Int?, headers: [String: String], body: String, bytes: Int, error: String?, duration: TimeInterval) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].status = status
        entries[index].responseHeaders = headers
        entries[index].responseBody = body
        entries[index].responseSize = bytes
        entries[index].error = error
        entries[index].duration = duration
    }

    func replace(_ entries: [CaptureEntry]) {
        self.entries = Array(entries.prefix(1000))
    }

    func appendManual(_ request: URLRequest, startedAt: Date, data: Data?, response: URLResponse?, error: Error?) {
        guard let url = request.url else { return }
        let http = response as? HTTPURLResponse
        add(CaptureEntry(startedAt: startedAt,
                         method: request.httpMethod ?? "GET",
                         url: PrivacyFilter.safeURL(url.absoluteString),
                         host: url.host ?? "",
                         source: "Composer",
                         status: http?.statusCode,
                         duration: Date().timeIntervalSince(startedAt),
                         requestHeaders: PrivacyFilter.safeHeaders(request.allHTTPHeaderFields ?? [:]),
                         responseHeaders: PrivacyFilter.safeHeaders(http?.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                             result[String(describing: pair.key)] = String(describing: pair.value)
                         } ?? [:]),
                         requestBody: PrivacyFilter.safeBody(request.httpBody ?? Data(), contentType: request.value(forHTTPHeaderField: "Content-Type") ?? ""),
                         responseBody: PrivacyFilter.safeBody(data ?? Data(), contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? ""),
                         responseSize: data?.count ?? 0,
                         error: error?.localizedDescription))
    }
}
