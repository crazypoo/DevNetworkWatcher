import Foundation

/// PR43/44: a Foundation-only, one-pass projection of a bounded authorized
/// diagnostic reply. SwiftUI owns selection and collapse state; this helper
/// neither retains a bridge session nor performs any network/UI work.
struct StudioHierarchyRow: Identifiable {
    let entry: StudioDiagnosticEntry
    let depth: Int
    var id: String { entry.id }
}

struct StudioHierarchyProjection {
    let indexedEntries: [String: StudioDiagnosticEntry]
    let children: [String: [String]]
    let flatRows: [StudioHierarchyRow]
    let perspectiveEntries: [StudioDiagnosticEntry]

    init(entries: [StudioDiagnosticEntry]) {
        var indexed: [String: StudioDiagnosticEntry] = [:]
        var flat: [StudioHierarchyRow] = []
        var perspective: [StudioDiagnosticEntry] = []
        indexed.reserveCapacity(entries.count)
        flat.reserveCapacity(entries.count)
        perspective.reserveCapacity(min(70, entries.count))

        // Preserve the first occurrence of duplicate IDs, matching the
        // original Dictionary(uniquingKeysWith:) projection.
        for entry in entries {
            flat.append(StudioHierarchyRow(entry: entry, depth: 0))
            if indexed[entry.id] == nil { indexed[entry.id] = entry }
            if entry.frame != nil && perspective.count < 70 {
                perspective.append(entry)
            }
        }

        var nextChildren: [String: [String]] = [:]
        for entry in entries {
            if let parent = entry.parentID, indexed[parent] != nil {
                nextChildren[parent, default: []].append(entry.id)
            }
        }
        indexedEntries = indexed
        children = nextChildren
        flatRows = flat
        perspectiveEntries = perspective
    }

    /// Keep the original max-depth, max-row, collapse, root and cycle policy.
    /// Called on collapse toggles without rebuilding the index or preview.
    static func visibleRows(entries: [StudioDiagnosticEntry],
                            indexed: [String: StudioDiagnosticEntry],
                            children: [String: [String]],
                            collapsed: Set<String>,
                            limit: Int = 1_200) -> [StudioHierarchyRow] {
        guard limit > 0 else { return [] }
        var rows: [StudioHierarchyRow] = []
        rows.reserveCapacity(min(entries.count, limit))
        var visited = Set<String>()
        visited.reserveCapacity(min(entries.count, limit))
        func walk(_ entry: StudioDiagnosticEntry, _ depth: Int) {
            guard depth < 20, rows.count < limit,
                  visited.insert(entry.id).inserted else { return }
            rows.append(StudioHierarchyRow(entry: entry, depth: depth))
            guard !collapsed.contains(entry.id) else { return }
            for id in children[entry.id] ?? [] {
                if let child = indexed[id] { walk(child, depth + 1) }
            }
        }
        for entry in entries where entry.parentID == nil ||
                                  indexed[entry.parentID ?? ""] == nil {
            walk(entry, 0)
        }
        // Orphaned/cyclic nodes remain accessible instead of disappearing.
        for entry in entries where !visited.contains(entry.id) {
            walk(entry, 0)
        }
        return rows
    }
}
