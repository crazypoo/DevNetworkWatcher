import Foundation

/// Internal Python-collector stdout format only, not part of the externally
/// authenticated Network v1 wire protocol. Keep decoding off MainActor.
enum StudioBridgeLocalDecoder {
    static let maximumBatchSize = 24

    static func entries(from message: [String: Any]) -> [CaptureEntry] {
        switch message["type"] as? String {
        case "entry":
            guard let raw = message["entry"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let entry = try? JSONDecoder().decode(CaptureEntry.self, from: data)
            else { return [] }
            return [entry]
        case "entryBatch":
            guard let raw = message["entries"] as? [[String: Any]],
                  !raw.isEmpty, raw.count <= maximumBatchSize,
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let entries = try? JSONDecoder().decode([CaptureEntry].self, from: data)
            else { return [] }
            return entries
        default:
            return []
        }
    }
}
