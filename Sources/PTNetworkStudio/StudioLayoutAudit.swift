import Foundation

/// PR48: read-only geometry hints computed from the already-authorized,
/// sanitized Inspector v2 snapshot. No device edits, constraint enumeration,
/// additional transport, or false claim of detecting Auto Layout conflicts.
struct StudioLayoutFinding: Equatable {
    enum Kind: String { case emptySize, invalidSize, clippedByParent, mixedLayoutModes }
    let entryID: String
    let kind: Kind
    let summary: String
}

enum StudioLayoutAudit {
    static func analyze(_ entries: [StudioDiagnosticEntry]) -> [String: [StudioLayoutFinding]] {
        let indexed = Dictionary(entries.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
        var result: [String: [StudioLayoutFinding]] = [:]
        for entry in entries {
            // A view may legitimately own both mask-driven and explicit
            // constraints; only surface an advisory diagnostic, not a conflict.
            if entry.attributes["translatesAutoresizingMaskIntoConstraints"] == "true",
               let active = entry.attributes["ownActiveConstraints"].flatMap(Int.init),
               active > 0 {
                result[entry.id, default: []].append(.init(
                    entryID: entry.id, kind: .mixedLayoutModes,
                    summary: "Autoresizing mask and own active constraints coexist (review only)"))
            }
            guard let frame = entry.frame else { continue }
            let scalars = [frame.x, frame.y, frame.width, frame.height]
            if !scalars.allSatisfy(\.isFinite) || frame.width < 0 || frame.height < 0 {
                result[entry.id, default: []].append(.init(
                    entryID: entry.id, kind: .invalidSize,
                    summary: "Invalid frame dimensions"))
                continue
            }
            if frame.width == 0 || frame.height == 0 {
                // Avoid spurious warnings for deliberately hidden placeholders.
                if entry.attributes["isHidden"] != "true" {
                    result[entry.id, default: []].append(.init(
                        entryID: entry.id, kind: .emptySize,
                        summary: "Zero-sized visible view (may be intentional)"))
                }
                continue
            }
            // PTools provides screen-space frames (UIView.convert(..., to:nil)).
            // Overflow is relevant only when the parent explicitly clips.
            guard let parentID = entry.parentID, let parent = indexed[parentID],
                  parent.attributes["clipsToBounds"] == "true",
                  let bounds = parent.frame,
                  bounds.width > 0, bounds.height > 0 else { continue }
            let slack = 1.0
            if frame.x < bounds.x - slack || frame.y < bounds.y - slack ||
                frame.x + frame.width > bounds.x + bounds.width + slack ||
                frame.y + frame.height > bounds.y + bounds.height + slack {
                result[entry.id, default: []].append(.init(
                    entryID: entry.id, kind: .clippedByParent,
                    summary: "May be clipped by parent (screen-space frame)"))
            }
        }
        return result
    }
}
