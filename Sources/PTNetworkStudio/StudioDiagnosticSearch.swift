import Foundation

/// PR49: one search policy for Inspector, Console, Storage and Metrics.
enum StudioDiagnosticSearch {
    static func filter(_ rows: [StudioHierarchyRow], query: String) -> [StudioHierarchyRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            let item = row.entry
            if item.name.localizedCaseInsensitiveContains(needle) ||
               item.kind.localizedCaseInsensitiveContains(needle) ||
               (item.detail?.localizedCaseInsensitiveContains(needle) ?? false) {
                return true
            }
            return item.attributes.contains { key, value in
                key.localizedCaseInsensitiveContains(needle) ||
                    value.localizedCaseInsensitiveContains(needle)
            }
        }
    }
}
