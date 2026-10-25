import Foundation
import AppKit
import UniformTypeIdentifiers

enum SessionFiles {
    @MainActor
    static func exportSession(_ entries: [CaptureEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(StudioSession(entries: entries))
        try save(data, name: "PTNetworkStudio-session.json", ext: "json")
    }

    @MainActor
    static func importSession() throws -> [CaptureEntry]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let model = try decoder.decode(StudioSession.self, from: Data(contentsOf: url))
        guard model.formatVersion == 1 else { throw NSError(domain: "PTNetworkStudio", code: 1, userInfo: [NSLocalizedDescriptionKey:"Unsupported session version"]) }
        return model.entries.prefix(1000).map { original in
            var e = original
            e.url = PrivacyFilter.safeURL(e.url)
            e.requestHeaders = PrivacyFilter.safeHeaders(e.requestHeaders)
            e.responseHeaders = PrivacyFilter.safeHeaders(e.responseHeaders)
            let requestType = e.requestHeaders.first(where: { $0.key.lowercased() == "content-type" })?.value ?? ""
            let responseType = e.responseHeaders.first(where: { $0.key.lowercased() == "content-type" })?.value ?? ""
            e.requestBody = PrivacyFilter.safeBody(Data(e.requestBody.utf8), contentType: requestType)
            e.responseBody = PrivacyFilter.safeBody(Data(e.responseBody.utf8), contentType: responseType)
            return e
        }
    }

    @MainActor
    static func importHAR() throws -> [CaptureEntry]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .json, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let log = root["log"] as? [String: Any],
              let raw = log["entries"] as? [[String: Any]] else {
            throw NSError(domain: "PTNetworkStudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid HAR: expected log.entries"])
        }
        let dateParser = ISO8601DateFormatter()
        dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackDateParser = ISO8601DateFormatter()
        return Array(raw.prefix(1000)).compactMap { item in
            guard let req = item["request"] as? [String: Any],
                  let url = req["url"] as? String else { return nil }
            let response = item["response"] as? [String: Any] ?? [:]
            let reqHeaders = parseHARHeaders(req["headers"])
            let resHeaders = parseHARHeaders(response["headers"])
            let dateString = item["startedDateTime"] as? String ?? ""
            let meta = item["_ptools"] as? [String: Any]
            let responseContent = response["content"] as? [String: Any]
            let safeResponseBody = PrivacyFilter.safeBody(Data((responseContent?["text"] as? String ?? "").prefix(64 * 1024).utf8), contentType: responseContent?["mimeType"] as? String ?? "")
            let rawStatus = response["status"] as? Int ?? 0
            return CaptureEntry(startedAt: dateParser.date(from: dateString) ?? fallbackDateParser.date(from: dateString) ?? .now,
                                method: req["method"] as? String ?? "GET",
                                url: PrivacyFilter.safeURL(url),
                                host: URL(string: url)?.host ?? "(unknown)",
                                source: meta?["source"] as? String ?? "Imported HAR",
                                status: rawStatus > 0 ? rawStatus : nil,
                                duration: (item["time"] as? Double).map { $0 / 1000 },
                                requestHeaders: PrivacyFilter.safeHeaders(reqHeaders),
                                responseHeaders: PrivacyFilter.safeHeaders(resHeaders),
                                responseBody: safeResponseBody,
                                responseSize: responseContent?["size"] as? Int ?? 0)
        }
    }

    private static func parseHARHeaders(_ raw: Any?) -> [String: String] {
        guard let rows = raw as? [[String: Any]] else { return [:] }
        return rows.reduce(into: [String: String]()) { out, item in
            guard let name = item["name"] as? String, let value = item["value"] as? String else { return }
            out[name] = value
        }
    }

    @MainActor
    static func exportHAR(_ entries: [CaptureEntry]) throws {
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let list: [[String: Any]] = entries.filter { $0.method != "ERROR" }.map { entry in
            let reqHeaders = entry.requestHeaders.map { ["name": $0.key, "value": $0.value] }
            let resHeaders = entry.responseHeaders.map { ["name": $0.key, "value": $0.value] }
            return [
                "startedDateTime": time.string(from: entry.startedAt),
                "time": (entry.duration ?? 0) * 1000,
                "request": ["method": entry.method, "url": entry.url, "httpVersion": "HTTP/1.1", "headers": reqHeaders, "queryString": [], "cookies": [], "headersSize": -1, "bodySize": -1] as [String: Any],
                "response": ["status": entry.status ?? 0, "statusText": "", "httpVersion": "HTTP/1.1", "headers": resHeaders, "cookies": [], "content": ["size": entry.responseSize, "mimeType": entry.responseHeaders.first(where: { $0.key.lowercased() == "content-type" })?.value ?? "application/octet-stream", "text": entry.responseBody], "redirectURL": "", "headersSize": -1, "bodySize": entry.responseSize] as [String: Any],
                "cache": [:] as [String: String],
                "timings": ["send": 0, "wait": -1, "receive": -1],
                "_ptOpaqueTLS": entry.isTunnel,
                "_ptSource": entry.source
            ]
        }
        let payload: [String: Any] = ["log": ["version": "1.2", "creator": ["name":"PTNetwork Studio", "version":"0.1"], "entries": list]]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try save(data, name: "PTNetworkStudio-capture.har", ext: "har")
    }

    @MainActor
    private static func save(_ data: Data, name: String, ext: String) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }
}
