import Foundation

#if os(iOS) && canImport(ARKit)
import ARKit
import SceneKit
import SwiftUI
import UIKit
import simd

/// Live LiDAR mesh preview. When an external `ARSession` is supplied, the view
/// renders the capture runtime's mesh anchors without taking over its delegate.
/// Without one, it owns a local preview session for standalone diagnostics.
public struct StockpileLiDARMeshARView: UIViewRepresentable {
    public let arSession: ARSession?

    public init(arSession: ARSession? = nil) {
        self.arSession = arSession
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeUIView(context: Context) -> StockpileLiDARMeshSceneView {
        let view = StockpileLiDARMeshSceneView(frame: .zero)
        view.delegate = context.coordinator
        context.coordinator.view = view
        if let arSession {
            context.coordinator.ownsSession = false
            view.session = arSession
            view.showExternalSessionHUD()
        } else {
            context.coordinator.ownsSession = true
            view.session.delegate = context.coordinator
            view.startSession()
        }
        return view
    }

    public func updateUIView(_ uiView: StockpileLiDARMeshSceneView, context: Context) {
        guard let arSession, uiView.session !== arSession else {
            return
        }
        uiView.session = arSession
        uiView.showExternalSessionHUD()
    }

    public static func dismantleUIView(_ uiView: StockpileLiDARMeshSceneView, coordinator: Coordinator) {
        if coordinator.ownsSession {
            uiView.session.pause()
        }
    }

    public final class Coordinator: NSObject, ARSCNViewDelegate, ARSessionDelegate, @unchecked Sendable {
        weak var view: StockpileLiDARMeshSceneView?
        var ownsSession = false

        public func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
            let node = SCNNode()
            node.geometry = makeStockpileLiDARWireframeGeometry(meshAnchor)
            publishMeshCount(from: renderer)
            return node
        }

        public func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return }
            node.geometry = makeStockpileLiDARWireframeGeometry(meshAnchor)
            publishMeshCount(from: renderer)
        }

        public func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let count = frame.anchors.compactMap { $0 as? ARMeshAnchor }.count
            let weakView = view
            DispatchQueue.main.async {
                weakView?.lastFrameAnchorCount = count
                weakView?.tickHUD()
            }
        }

        private func publishMeshCount(from renderer: SCNSceneRenderer) {
            let count = renderer.scene?.rootNode.childNodes.count ?? 0
            let weakView = view
            DispatchQueue.main.async {
                weakView?.lastFrameAnchorCount = max(weakView?.lastFrameAnchorCount ?? 0, count)
                weakView?.tickHUD()
            }
        }
    }
}

// MARK: - ARSCNView subclass with status HUD

public final class StockpileLiDARMeshSceneView: ARSCNView {
    fileprivate var lastFrameAnchorCount: Int = 0
    fileprivate var hudTickCount: Int = 0
    private var hudLabel: UILabel?

    public override init(frame: CGRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .black
        autoenablesDefaultLighting = false
        automaticallyUpdatesLighting = false
        rendersContinuously = true
        scene = SCNScene()
        installHUD()
    }

    private func installHUD() {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.textAlignment = .center
        label.layer.borderWidth = 2
        label.layer.borderColor = UIColor.cyan.cgColor
        label.layer.cornerRadius = 8
        label.layer.masksToBounds = true
        label.text = "LiDAR initializing…"
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 280)
        ])
        hudLabel = label
    }

    fileprivate func tickHUD() {
        hudTickCount &+= 1
        let supported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
        let status: String
        let color: UIColor
        if !supported {
            status = "❌ DEVICE LACKS LIDAR MESH"
            color = .red
        } else if lastFrameAnchorCount == 0 {
            status = "🟦 WAITING FOR MESH\ntick:\(hudTickCount)  meshC:Y"
            color = .cyan
        } else {
            status = "🟢 MESH LIVE\nanchors:\(lastFrameAnchorCount)  tick:\(hudTickCount)"
            color = UIColor(red: 0, green: 1, blue: 0.35, alpha: 1)
        }
        DispatchQueue.main.async { [weak self] in
            self?.hudLabel?.text = status
            self?.hudLabel?.layer.borderColor = color.cgColor
            self?.hudLabel?.textColor = color
            // Hide the HUD once mesh is live for >5 seconds so it stops
            // covering the wireframe.
            if let count = self?.lastFrameAnchorCount, count > 0,
               (self?.hudTickCount ?? 0) > 90 {
                self?.hudLabel?.isHidden = true
            }
        }
    }

    public func showExternalSessionHUD() {
        hudLabel?.isHidden = false
        hudLabel?.text = "Pile surface preview starting\nAim at the pile face"
        hudLabel?.layer.borderColor = UIColor.cyan.cgColor
        hudLabel?.textColor = .cyan
    }

    public func startSession() {
        guard ARWorldTrackingConfiguration.isSupported else {
            print("[LiDAR] ARWorldTrackingConfiguration unsupported")
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = []
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.environmentTexturing = .none
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

}

/// Builds an SCNGeometry that draws the mesh anchor's triangles as
/// neon-green wireframe lines.  Free function so it can be called off the
/// main actor (e.g. from `ARSCNViewDelegate` / `ARSessionDelegate`).
private func makeStockpileLiDARWireframeGeometry(_ anchor: ARMeshAnchor) -> SCNGeometry {
        let geo = anchor.geometry
        let verts = geo.vertices
        let faces = geo.faces

        // Copy ARKit's Metal buffer before SceneKit uploads it on its render
        // queue. ARKit can recycle the anchor buffer after this callback.
        let vData = Data(bytes: verts.buffer.contents(), count: verts.buffer.length)
        let vSource = SCNGeometrySource(
            data: vData,
            semantic: .vertex,
            vectorCount: verts.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: verts.offset,
            dataStride: verts.stride
        )

        // Index buffer: ARKit stores triangle indices.  We expand them to
        // line indices (3 edges × 2 indices per edge per triangle).
        let triCount = faces.count
        var lineIndices = [UInt32]()
        lineIndices.reserveCapacity(triCount * 6)
        let fPtr = faces.buffer.contents()
        let bytesPerIndex = faces.bytesPerIndex
        for i in 0 ..< triCount {
            if geo.stockpileCaptureClassificationOf(faceWithIndex: i)?.isGroundLikeForStockpilePreview == true {
                continue
            }

            var tri = [UInt32](repeating: 0, count: 3)
            for v in 0 ..< 3 {
                let off = (i * 3 + v) * bytesPerIndex
                let p = fPtr.advanced(by: off)
                if bytesPerIndex == 2 {
                    tri[v] = UInt32(p.assumingMemoryBound(to: UInt16.self).pointee)
                } else {
                    tri[v] = p.assumingMemoryBound(to: UInt32.self).pointee
                }
            }
            if geo.stockpileCaptureFaceIsFlatGroundLike(
                vertexIndices: tri,
                anchorTransform: anchor.transform
            ) {
                continue
            }

            lineIndices.append(tri[0]); lineIndices.append(tri[1])
            lineIndices.append(tri[1]); lineIndices.append(tri[2])
            lineIndices.append(tri[2]); lineIndices.append(tri[0])
        }
        let iData = lineIndices.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
        let element = SCNGeometryElement(
            data: iData,
            primitiveType: .line,
            primitiveCount: lineIndices.count / 2,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let scnGeo = SCNGeometry(sources: [vSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(red: 0, green: 1, blue: 0.35, alpha: 1)
        material.emission.contents = UIColor(red: 0, green: 1, blue: 0.35, alpha: 1)
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
    scnGeo.materials = [material]
    return scnGeo
}

private extension ARMeshGeometry {
    func stockpileCaptureClassificationOf(faceWithIndex index: Int) -> ARMeshClassification? {
        guard let classification else {
            return nil
        }

        let offset = classification.offset + classification.stride * index
        guard offset >= 0,
              offset < classification.buffer.length
        else {
            return nil
        }

        let rawValue = classification.buffer.contents()
            .advanced(by: offset)
            .assumingMemoryBound(to: UInt8.self)
            .pointee
        return ARMeshClassification(rawValue: Int(rawValue))
    }

    func stockpileCaptureFaceIsFlatGroundLike(
        vertexIndices: [UInt32],
        anchorTransform: simd_float4x4
    ) -> Bool {
        guard vertexIndices.count == 3,
              let a = stockpileCaptureWorldVertex(at: Int(vertexIndices[0]), anchorTransform: anchorTransform),
              let b = stockpileCaptureWorldVertex(at: Int(vertexIndices[1]), anchorTransform: anchorTransform),
              let c = stockpileCaptureWorldVertex(at: Int(vertexIndices[2]), anchorTransform: anchorTransform)
        else {
            return false
        }

        let edgeAB = b - a
        let edgeAC = c - a
        let normal = simd_cross(edgeAB, edgeAC)
        let normalLength = simd_length(normal)
        guard normalLength > 0.0001 else {
            return true
        }

        let unitNormal = normal / normalLength
        let mostlyHorizontal = abs(unitNormal.y) > 0.98
        let faceRise = max(a.y, max(b.y, c.y)) - min(a.y, min(b.y, c.y))
        return mostlyHorizontal && faceRise < 0.03
    }

    private func stockpileCaptureWorldVertex(
        at index: Int,
        anchorTransform: simd_float4x4
    ) -> SIMD3<Float>? {
        let source = vertices
        let offset = source.offset + source.stride * index
        guard index >= 0,
              offset >= 0,
              offset + MemoryLayout<Float>.stride * 3 <= source.buffer.length
        else {
            return nil
        }

        let pointer = source.buffer.contents()
            .advanced(by: offset)
            .assumingMemoryBound(to: Float.self)
        let local = SIMD4<Float>(pointer[0], pointer[1], pointer[2], 1)
        let world = anchorTransform * local
        return SIMD3<Float>(world.x, world.y, world.z)
    }
}

private extension ARMeshClassification {
    var isGroundLikeForStockpilePreview: Bool {
        switch self {
        case .floor:
            return true
        default:
            return false
        }
    }
}
#endif
