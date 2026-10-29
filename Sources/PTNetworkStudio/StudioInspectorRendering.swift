import SwiftUI
import AppKit
import SceneKit

/// Native macOS wireframe views, generated from authorized immutable snapshots.
/// 3D is a diagnostic exploded-layer representation, not a pixel-perfect UIKit renderer.
struct StudioHierarchy2DView: View {
    let nodes: [StudioDiagnosticEntry]
    let selectedID: String?

    var body: some View {
        GeometryReader { viewport in
            let rectangles = Array(nodes.filter { $0.frame != nil }.prefix(400))
            let extentX = max(1, rectangles.compactMap { $0.frame.map { $0.x + $0.width } }.max() ?? 1)
            let extentY = max(1, rectangles.compactMap { $0.frame.map { $0.y + $0.height } }.max() ?? 1)
            let scale = max(0.01, min((viewport.size.width - 24) / extentX,
                                     (viewport.size.height - 24) / extentY))
            ZStack(alignment: .topLeading) {
                Color(nsColor: .textBackgroundColor)
                ForEach(rectangles) { node in
                    if let rect = node.frame {
                        Rectangle()
                            .stroke(node.id == selectedID ? Color.orange : Color.accentColor.opacity(0.55),
                                    lineWidth: node.id == selectedID ? 2 : 0.7)
                            .frame(width: max(1, rect.width * scale),
                                   height: max(1, rect.height * scale))
                            .offset(x: 12 + rect.x * scale, y: 12 + rect.y * scale)
                    }
                }
            }.clipped()
        }
        .accessibilityLabel("2D wireframe hierarchy preview")
    }
}

struct StudioHierarchy3DView: NSViewRepresentable {
    let nodes: [StudioDiagnosticEntry]
    let selectedID: String?

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .windowBackgroundColor
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let scene = SCNScene()
        let frames = Array(nodes.filter { $0.frame != nil }.prefix(350))
        let width = max(1, frames.compactMap { $0.frame.map { $0.x + $0.width } }.max() ?? 1)
        let height = max(1, frames.compactMap { $0.frame.map { $0.y + $0.height } }.max() ?? 1)
        let parents = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, $0.parentID) })
        for node in frames {
            guard let rect = node.frame else { continue }
            var parent = node.parentID
            var depth = 0
            while let id = parent, depth < 35 {
                depth += 1
                parent = parents[id] ?? nil
            }
            let shape = SCNBox(width: max(1, rect.width), height: max(1, rect.height),
                               length: 1.5, chamferRadius: 0)
            let material = SCNMaterial()
            material.diffuse.contents = node.id == selectedID
                ? NSColor.systemOrange : NSColor.controlAccentColor
            material.fillMode = .lines
            shape.materials = [material]
            let item = SCNNode(geometry: shape)
            item.name = node.id
            item.position = SCNVector3(Float(rect.x + rect.width / 2),
                                       Float(height - rect.y - rect.height / 2),
                                       Float(depth * 18))
            scene.rootNode.addChildNode(item)
        }
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.position = SCNVector3(Float(width / 2),
                                     Float(height / 2),
                                     Float(max(width, height) * 2.5))
        camera.look(at: SCNVector3(Float(width / 2), Float(height / 2), 0))
        scene.rootNode.addChildNode(camera)
        view.scene = scene
        view.pointOfView = camera
    }
}

struct StudioInspectorArchive: Codable {
    let schemaVersion: Int
    let capturedAt: Date
    let entries: [StudioDiagnosticEntry]

    init(entries: [StudioDiagnosticEntry]) {
        self.schemaVersion = 1
        self.capturedAt = .now
        self.entries = entries
    }
}

@MainActor
enum StudioInspectorArchives {
    static func export(_ entries: [StudioDiagnosticEntry]) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PTools-Inspector.ptinspector.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let payload = StudioInspectorArchive(entries: entries)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: .atomic)
    }
}
