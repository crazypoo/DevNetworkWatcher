import Foundation

enum PrivacyFilter {
    static let sensitive: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "api_key", "apikey", "token", "access_token", "refresh_token", "password", "passwd", "secret", "session", "code", "client_secret"]

    static func isSensitive(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return sensitive.contains(key.lowercased()) || sensitive.contains(normalized)
    }

    static func safeHeaders(_ headers: [String: String]) -> [String: String] {
        headers.mapValues { $0 }.reduce(into: [String: String]()) { out, pair in
            out[pair.key] = isSensitive(pair.key) ? "<redacted>" : pair.value
        }
    }

    static func safeURL(_ value: String) -> String {
        guard var c = URLComponents(string: value) else { return value }
        if c.user != nil { c.user = "<redacted>" }
        if c.password != nil { c.password = "<redacted>" }
        guard let items = c.queryItems else { return c.string ?? value }
        c.queryItems = items.map { URLQueryItem(name: $0.name, value: isSensitive($0.name) ? "<redacted>" : $0.value) }
        return c.string ?? value
    }

    private static func sanitizeJSON(_ value: Any) -> Any {
        if let map = value as? [String: Any] {
            return map.mapValues { $0 }.reduce(into: [String: Any]()) { out, pair in
                out[pair.key] = isSensitive(pair.key) ? "<redacted>" : sanitizeJSON(pair.value)
            }
        }
        if let items = value as? [Any] { return items.map(sanitizeJSON) }
        return value
    }

    static func safeBody(_ data: Data, contentType: String) -> String {
        if data.isEmpty { return "" }
        let preview = Data(data.prefix(64 * 1024))
        if contentType.lowercased().contains("json") || preview.first == 123 || preview.first == 91 {
            if let object = try? JSONSerialization.jsonObject(with: preview, options: [.fragmentsAllowed]),
               let redacted = try? JSONSerialization.data(withJSONObject: sanitizeJSON(object), options: [.prettyPrinted, .fragmentsAllowed, .sortedKeys]),
               let text = String(data: redacted, encoding: .utf8) {
                return text + (data.count > preview.count ? "\n[truncated]" : "")
            }
        }
        if contentType.lowercased().contains("x-www-form-urlencoded"), let s = String(data: preview, encoding: .utf8),
           let items = URLComponents(string: "http://localhost/?" + s)?.queryItems {
            return items.map { "\($0.name)=\(isSensitive($0.name) ? "<redacted>" : ($0.value ?? ""))" }.joined(separator: "&")
        }
        // Unknown text/binary might contain secrets. Fail closed instead of persisting the payload.
        return "[Preview suppressed: only valid JSON and form bodies are retained]"
    }
}

extension CaptureEntry {
    func curlCommand() -> String {
        func shell(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var parts = ["curl", "-X", shell(method), shell(url)]
        for (name, value) in requestHeaders.sorted(by: { $0.key < $1.key }) {
            parts += ["-H", shell("\(name): \(value)")]
        }
        // Intentionally does not reproduce raw credentials or bodies.
        return parts.joined(separator: " ")
    }
}
