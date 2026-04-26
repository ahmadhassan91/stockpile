import Foundation
import SceneKit
import StockpileDesignSystem

#if canImport(UIKit)
import UIKit
private typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
private typealias PlatformColor = NSColor
#endif

enum StockpileResultSceneKitRenderer {
    static func makeScene(
        reconstruction: StockpileResultReconstruction,
        mode: StockpileResultViewerMode
    ) -> SCNScene {
        let bounds = SceneBounds(points: reconstruction.vertices.isEmpty ? reconstruction.pointCloud : reconstruction.vertices)
        let scene = SCNScene()
        scene.background.contents = PlatformColor(stockpile: StockpilePalette.elevatedSurface)

        scene.rootNode.addChildNode(makeCameraNode(bounds: bounds))
        scene.rootNode.addChildNode(makeAmbientLight())
        scene.rootNode.addChildNode(makeKeyLight())
        scene.rootNode.addChildNode(makeFillLight(bounds: bounds))
        scene.rootNode.addChildNode(makeStageNode(bounds: bounds))

        if let meshNode = makeMeshNode(reconstruction: reconstruction, mode: mode) {
            scene.rootNode.addChildNode(meshNode)
        }

        if mode == .all || mode == .threeD {
            scene.rootNode.addChildNode(makePointCloudNode(points: reconstruction.pointCloud))
        }

        if mode == .toe || mode == .all {
            reconstruction.toeMarkers.forEach { point in
                scene.rootNode.addChildNode(
                    makeMarkerNode(
                        point: point,
                        color: PlatformColor(stockpile: StockpilePalette.caution),
                        radius: 0.12,
                        baseZ: bounds.minZ
                    )
                )
            }
        }

        if mode == .surface || mode == .all {
            reconstruction.surfaceRiskMarkers.forEach { point in
                scene.rootNode.addChildNode(
                    makeMarkerNode(
                        point: point,
                        color: PlatformColor(stockpile: StockpilePalette.critical),
                        radius: 0.14,
                        baseZ: bounds.minZ
                    )
                )
            }
        }

        return scene
    }

    private static func makeCameraNode(bounds: SceneBounds) -> SCNNode {
        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.fieldOfView = 42
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.zNear = 0.1
        camera.zFar = Double(bounds.radius * 16)
        camera.automaticallyAdjustsZRange = true
        cameraNode.camera = camera
        cameraNode.position = vector(
            x: bounds.centerX + bounds.radius * 0.18,
            y: bounds.centerY - bounds.radius * 2.0,
            z: bounds.maxZ + bounds.radius * 0.92
        )
        cameraNode.look(
            at: vector(
                x: bounds.centerX,
                y: bounds.centerY,
                z: bounds.focusZ
            )
        )
        return cameraNode
    }

    private static func makeAmbientLight() -> SCNNode {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 760
        ambient.light?.color = PlatformColor.white.withAlphaComponent(0.92)
        return ambient
    }

    private static func makeKeyLight() -> SCNNode {
        let keyLight = SCNNode()
        keyLight.light = SCNLight()
        keyLight.light?.type = .directional
        keyLight.light?.intensity = 1380
        keyLight.light?.color = PlatformColor.white.withAlphaComponent(0.95)
        keyLight.eulerAngles = vector(
            x: Float(-Double.pi / 3.1),
            y: Float(Double.pi / 4.8),
            z: 0
        )
        return keyLight
    }

    private static func makeFillLight(bounds: SceneBounds) -> SCNNode {
        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .omni
        fillLight.light?.intensity = 420
        fillLight.light?.color = PlatformColor(stockpile: StockpilePalette.surface)
        fillLight.position = vector(
            x: bounds.centerX - bounds.radius * 1.1,
            y: bounds.centerY + bounds.radius * 0.4,
            z: bounds.maxZ + bounds.radius * 1.2
        )
        return fillLight
    }

    private static func makeStageNode(bounds: SceneBounds) -> SCNNode {
        let root = SCNNode()

        let floor = SCNFloor()
        floor.reflectivity = 0
        floor.firstMaterial?.lightingModel = .physicallyBased
        floor.firstMaterial?.diffuse.contents = PlatformColor(stockpile: StockpilePalette.surface)
        floor.firstMaterial?.roughness.contents = 1.0
        floor.firstMaterial?.transparency = 0.96
        let floorNode = SCNNode(geometry: floor)
        floorNode.position = vector(x: bounds.centerX, y: bounds.centerY, z: bounds.minZ - 0.08)
        root.addChildNode(floorNode)

        let platform = SCNCylinder(radius: CGFloat(bounds.radius * 0.72), height: 0.05)
        platform.firstMaterial?.lightingModel = .physicallyBased
        platform.firstMaterial?.diffuse.contents = PlatformColor(stockpile: StockpilePalette.surface)
        platform.firstMaterial?.roughness.contents = 0.92
        let platformNode = SCNNode(geometry: platform)
        platformNode.position = vector(x: bounds.centerX, y: bounds.centerY, z: bounds.minZ - 0.025)
        root.addChildNode(platformNode)

        let ring = SCNTorus(ringRadius: CGFloat(bounds.radius * 0.9), pipeRadius: 0.03)
        ring.firstMaterial?.lightingModel = .constant
        ring.firstMaterial?.diffuse.contents = PlatformColor(stockpile: StockpilePalette.border)
        ring.firstMaterial?.emission.contents = PlatformColor(stockpile: StockpilePalette.border).withAlphaComponent(0.35)
        let ringNode = SCNNode(geometry: ring)
        ringNode.position = vector(x: bounds.centerX, y: bounds.centerY, z: bounds.minZ + 0.02)
        root.addChildNode(ringNode)

        return root
    }

    private static func makeMeshNode(
        reconstruction: StockpileResultReconstruction,
        mode: StockpileResultViewerMode
    ) -> SCNNode? {
        guard !reconstruction.vertices.isEmpty, !reconstruction.triangles.isEmpty else {
            return nil
        }

        let vertexFloats = reconstruction.vertices.flatMap { [$0.x, $0.y, $0.z] }
        let vertexData = vertexFloats.withUnsafeBufferPointer { Data(buffer: $0) }
        let source = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: reconstruction.vertices.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )

        let indexList = reconstruction.triangles.flatMap { [$0.a, $0.b, $0.c] }
        let indexData = indexList.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: reconstruction.triangles.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [makeMeshMaterial(for: mode)]

        return SCNNode(geometry: geometry)
    }

    private static func makeMeshMaterial(for mode: StockpileResultViewerMode) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.metalness.contents = 0.04
        material.roughness.contents = 0.72
        material.fresnelExponent = 1.1
        material.isDoubleSided = true
        material.specular.contents = PlatformColor.white.withAlphaComponent(0.12)

        switch mode {
        case .contour:
            material.fillMode = .lines
            material.diffuse.contents = PlatformColor(stockpile: StockpilePalette.accent)
            material.emission.contents = PlatformColor(stockpile: StockpilePalette.accent).withAlphaComponent(0.12)
            material.transparency = 0.92
        case .toe:
            material.diffuse.contents = PlatformColor(stockpile: StockpilePalette.accent)
            material.emission.contents = PlatformColor(stockpile: StockpilePalette.caution).withAlphaComponent(0.08)
            material.transparency = 0.54
        case .surface:
            material.diffuse.contents = PlatformColor(stockpile: StockpilePalette.surface)
            material.emission.contents = PlatformColor(stockpile: StockpilePalette.critical).withAlphaComponent(0.08)
            material.transparency = 0.86
        case .all:
            material.diffuse.contents = PlatformColor(stockpile: StockpilePalette.accent)
            material.emission.contents = PlatformColor(stockpile: StockpilePalette.accent).withAlphaComponent(0.06)
            material.transparency = 0.92
        case .threeD:
            material.diffuse.contents = PlatformColor(stockpile: StockpilePalette.accent)
            material.emission.contents = PlatformColor(stockpile: StockpilePalette.accent).withAlphaComponent(0.04)
        }

        return material
    }

    private static func makePointCloudNode(points: [StockpileResultPoint3D]) -> SCNNode {
        guard !points.isEmpty else {
            return SCNNode()
        }

        let sampled = stride(from: 0, to: points.count, by: max(1, points.count / 120)).map { points[$0] }
        let root = SCNNode()

        for point in sampled {
            let sphere = SCNSphere(radius: 0.045)
            sphere.firstMaterial?.lightingModel = .constant
            sphere.firstMaterial?.diffuse.contents = PlatformColor(
                red: CGFloat(StockpilePalette.ink.red),
                green: CGFloat(StockpilePalette.ink.green),
                blue: CGFloat(StockpilePalette.ink.blue),
                alpha: 0.42
            )
            let node = SCNNode(geometry: sphere)
            node.position = vector(point)
            root.addChildNode(node)
        }

        return root
    }

    private static func makeMarkerNode(
        point: StockpileResultPoint3D,
        color: PlatformColor,
        radius: CGFloat,
        baseZ: Float
    ) -> SCNNode {
        let root = SCNNode()
        let stemHeight = max(Float(radius) * 1.6, point.z - baseZ)

        let base = SCNCylinder(radius: radius * 0.7, height: 0.02)
        base.firstMaterial?.lightingModel = .constant
        base.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.22)
        let baseNode = SCNNode(geometry: base)
        baseNode.position = vector(x: point.x, y: point.y, z: baseZ + 0.01)
        root.addChildNode(baseNode)

        let stem = SCNCylinder(radius: radius * 0.16, height: CGFloat(stemHeight))
        stem.firstMaterial?.lightingModel = .constant
        stem.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.65)
        let stemNode = SCNNode(geometry: stem)
        stemNode.position = vector(x: point.x, y: point.y, z: baseZ + stemHeight / 2)
        root.addChildNode(stemNode)

        let sphere = SCNSphere(radius: radius)
        sphere.firstMaterial?.lightingModel = .physicallyBased
        sphere.firstMaterial?.diffuse.contents = color
        sphere.firstMaterial?.emission.contents = PlatformColor.white.withAlphaComponent(0.08)
        let node = SCNNode(geometry: sphere)
        node.position = vector(point)
        root.addChildNode(node)

        return root
    }

    private static func vector(_ point: StockpileResultPoint3D) -> SCNVector3 {
        vector(x: point.x, y: point.y, z: point.z)
    }

    private static func vector(x: Float, y: Float, z: Float) -> SCNVector3 {
        SCNVector3(x, y, z)
    }
}

private struct SceneBounds {
    let minX: Float
    let maxX: Float
    let minY: Float
    let maxY: Float
    let minZ: Float
    let maxZ: Float

    init(points: [StockpileResultPoint3D]) {
        guard let first = points.first else {
            minX = -6
            maxX = 6
            minY = -6
            maxY = 6
            minZ = 0
            maxZ = 4
            return
        }

        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        var minZ = first.z
        var maxZ = first.z

        for point in points.dropFirst() {
            minX = Swift.min(minX, point.x)
            maxX = Swift.max(maxX, point.x)
            minY = Swift.min(minY, point.y)
            maxY = Swift.max(maxY, point.y)
            minZ = Swift.min(minZ, point.z)
            maxZ = Swift.max(maxZ, point.z)
        }

        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
        self.minZ = minZ
        self.maxZ = maxZ
    }

    var centerX: Float {
        (minX + maxX) / 2
    }

    var centerY: Float {
        (minY + maxY) / 2
    }

    var height: Float {
        max(maxZ - minZ, 1)
    }

    var radius: Float {
        max(maxX - minX, maxY - minY) * 0.62 + 1.8
    }

    var focusZ: Float {
        minZ + max(height * 0.56, 1.5)
    }
}

private extension PlatformColor {
    convenience init(stockpile value: StockpileColorValue) {
        self.init(
            red: CGFloat(value.red),
            green: CGFloat(value.green),
            blue: CGFloat(value.blue),
            alpha: CGFloat(value.alpha)
        )
    }
}
