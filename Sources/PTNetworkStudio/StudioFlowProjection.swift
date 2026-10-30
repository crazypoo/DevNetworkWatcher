import Foundation

/// PR47: pure, Sendable filtering across immutable capture snapshots.
/// The live store remains the only owner of flow ordering, retention and IDs.
enum StudioFlowScope: Hashable, Sendable {
    case all, http, https, failed, host(String)
}

enum StudioFlowProjection {
    static func filter(entries: [CaptureEntry], scope: StudioFlowScope,
                       search: String) -> [CaptureEntry] {
        var result: [CaptureEntry] = []
        result.reserveCapacity(entries.count)
        // Match the legacy reversed display order, without intermediate arrays.
        for entry in entries.reversed() {
            let included: Bool
            switch scope {
            case .all: included = true
            case .http: included = !entry.isTunnel && entry.url.hasPrefix("http://")
            case .https: included = entry.isTunnel || entry.url.hasPrefix("https://")
            case .failed: included = entry.error != nil || (entry.status ?? 0) >= 400
            case .host(let host): included = entry.host == host
            }
            guard included else { continue }
            if !search.isEmpty,
               !entry.url.localizedCaseInsensitiveContains(search),
               !entry.method.localizedCaseInsensitiveContains(search),
               !entry.host.localizedCaseInsensitiveContains(search),
               !entry.statusText.localizedCaseInsensitiveContains(search) {
                continue
            }
            result.append(entry)
        }
        return result
    }
}
