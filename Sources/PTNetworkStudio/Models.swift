import Foundation
import Combine
import os

struct CaptureEntry: Identifiable, Codable, Equatable, Sendable {
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

/// Immutable statistics prepared only when a batched UI snapshot is published.
struct CaptureStatistics {
    let httpCount: Int
    let httpsCount: Int
    let errorCount: Int
    let hosts: [(name: String, count: Int)]
    static let empty = CaptureStatistics(httpCount: 0, httpsCount: 0,
                                         errorCount: 0, hosts: [])
}

struct StudioSession: Codable {
    var formatVersion: Int = 1
    var exportedAt: Date = .now
    var entries: [CaptureEntry]
}

@MainActor
final class CaptureStore: ObservableObject {
    @Published private(set) var entries: [CaptureEntry] = []
    @Published private(set) var statistics = CaptureStatistics.empty
    /// The source of truth is indexed by UUID, never a repeatedly copied SwiftUI array.
    private var recordsByID: [UUID: CaptureEntry] = [:]
    private var orderedIDs: [UUID] = []
    private var pendingPublish: Task<Void, Never>?
    private let signposter = OSSignposter(subsystem: "PToolsStudio", category: "CaptureStore")
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
                // Decode JSON outside MainActor: only value snapshots reach the UI.
                let entry: CaptureEntry? = {
                    guard let raw = message["entry"],
                          let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
                    return try? JSONDecoder().decode(CaptureEntry.self, from: data)
                }()
                Task { @MainActor in self?.handleMessage(message, parsedEntry: entry) }
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

    private func handleMessage(_ message: [String: Any], parsedEntry: CaptureEntry?) {
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
        if let entry = parsedEntry {
            upsert(entry)
            if type == "paused", let phase = message["phase"] as? String { paused[entry.id] = phase }
        }
    }

    func decide(_ id: UUID, action: String, changes: [String: Any] = [:]) {
        guard let phase = paused[id] else { return }
        do { try engine.decide(id, phase: phase, action: action, changes: changes) }
        catch { lastError = error.localizedDescription }
    }

    func entry(id: UUID?) -> CaptureEntry? {
        guard let id else { return nil }
        return recordsByID[id]
    }

    func upsert(_ entry: CaptureEntry) {
        if recordsByID.updateValue(entry, forKey: entry.id) == nil {
            orderedIDs.append(entry.id)
            if orderedIDs.count > 1000 {
                let removed = orderedIDs.removeFirst()
                recordsByID.removeValue(forKey: removed)
            }
        }
        schedulePublish()
    }

    func clear() {
        recordsByID.removeAll()
        orderedIDs.removeAll()
        publishNow()
    }

    func removeLiveRequest(_ id: UUID) {
        guard recordsByID[id]?.source == "PTools Live" else { return }
        recordsByID.removeValue(forKey: id)
        orderedIDs.removeAll { $0 == id }
        schedulePublish()
    }

    func resetLiveRequests() {
        let dropped = Set(recordsByID.values.filter { $0.source == "PTools Live" }.map(\.id))
        guard !dropped.isEmpty else { return }
        for id in dropped { recordsByID.removeValue(forKey: id) }
        orderedIDs.removeAll { dropped.contains($0) }
        publishNow()
    }

    func add(_ event: CaptureEntry) { upsert(event) }

    func finish(_ id: UUID, status: Int?, headers: [String: String], body: String, bytes: Int, error: String?, duration: TimeInterval) {
        guard var entry = recordsByID[id] else { return }
        entry.status = status
        entry.responseHeaders = headers
        entry.responseBody = body
        entry.responseSize = bytes
        entry.error = error
        entry.duration = duration
        recordsByID[id] = entry
        schedulePublish()
    }

    func replace(_ incoming: [CaptureEntry]) {
        recordsByID.removeAll()
        orderedIDs.removeAll()
        for item in incoming.suffix(1000) {
            if recordsByID.updateValue(item, forKey: item.id) == nil { orderedIDs.append(item.id) }
        }
        publishNow()
    }

    /// PR07/08: coalesce a burst of network updates into one SwiftUI invalidation.
    /// The pending task is cancelled for clears/replacements and never owns a window.
    private func schedulePublish() {
        guard pendingPublish == nil else { return }
        pendingPublish = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(75))
            guard !Task.isCancelled else { return }
            self?.publishNow()
        }
    }

    private func publishNow() {
        pendingPublish?.cancel()
        pendingPublish = nil
        let state = signposter.beginInterval("Publish capture snapshot")
        let snapshot = orderedIDs.compactMap { recordsByID[$0] }
        var domains: [String: Int] = [:]
        var http = 0, https = 0, failures = 0
        for entry in snapshot {
            domains[entry.host, default: 0] += 1
            if entry.url.hasPrefix("http://") { http += 1 }
            if entry.url.hasPrefix("https://") { https += 1 }
            if entry.error != nil || (entry.status ?? 0) >= 400 { failures += 1 }
        }
        statistics = CaptureStatistics(httpCount: http, httpsCount: https,
            errorCount: failures,
            hosts: domains.map { (name: $0.key, count: $0.value) }
                          .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count })
        entries = snapshot
        signposter.endInterval("Publish capture snapshot", state)
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
