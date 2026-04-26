import Foundation
import StockpileDesignSystem

public enum StockpileResultViewerMode: String, Codable, CaseIterable, Sendable {
    case contour
    case toe
    case surface
    case all
    case threeD = "3d"

    public static var inspectionModes: [Self] {
        [.threeD, .toe, .surface, .contour, .all]
    }

    public var title: String {
        switch self {
        case .contour:
            return "Contour"
        case .toe:
            return "Toe"
        case .surface:
            return "Surface"
        case .all:
            return "Context"
        case .threeD:
            return "Overview"
        }
    }

    public var headline: String {
        switch self {
        case .contour:
            return "Read the mesh support"
        case .toe:
            return "Check toe definition"
        case .surface:
            return "Review surface exceptions"
        case .all:
            return "Compare all inspection signals"
        case .threeD:
            return "Confirm the overall pile shape"
        }
    }

    public var detail: String {
        switch self {
        case .contour:
            return "Use the wireframe to judge mesh density, continuity, and where the reconstruction gets thin."
        case .toe:
            return "Inspect the outer edge and confirm the toe stays visible around the full footprint."
        case .surface:
            return "Focus on localized anomalies that may change the trusted surface before reporting."
        case .all:
            return "Overlay toe and surface signals together so you can compare geometry with attention points."
        case .threeD:
            return "Review the reconstructed form first to spot obvious lean, gaps, or unsupported shape."
        }
    }

    public var systemImage: String {
        switch self {
        case .contour:
            return "square.3.layers.3d.top.filled"
        case .toe:
            return "camera.metering.matrix"
        case .surface:
            return "exclamationmark.triangle.fill"
        case .all:
            return "square.stack.3d.up.fill"
        case .threeD:
            return "view.3d"
        }
    }

    public var tone: StockpileStatusTone {
        switch self {
        case .toe:
            return .caution
        case .surface:
            return .critical
        case .contour, .all, .threeD:
            return .info
        }
    }

    public var interactionHint: String {
        switch self {
        case .contour:
            return "Rotate around the mesh to inspect density and edge continuity."
        case .toe:
            return "Orbit the footprint and confirm the edge stays readable on every side."
        case .surface:
            return "Zoom into marked high points and compare them against the surrounding surface."
        case .all:
            return "Use this view when you need geometry, toe, and risk signals in one pass."
        case .threeD:
            return "Start here, then move into a focused mode if one area needs a closer review."
        }
    }

    public var metricLabel: String {
        switch self {
        case .contour:
            return "Mesh faces"
        case .toe:
            return "Toe markers"
        case .surface:
            return "Watch points"
        case .all:
            return "Attention"
        case .threeD:
            return "Sample points"
        }
    }

    public func metricValue(in reconstruction: StockpileResultReconstruction) -> String {
        switch self {
        case .contour:
            return "\(reconstruction.meshFaceCount)"
        case .toe:
            return "\(reconstruction.toeMarkerCount)"
        case .surface:
            return "\(reconstruction.surfaceRiskCount)"
        case .all:
            return "\(reconstruction.attentionCount)"
        case .threeD:
            return "\(reconstruction.sampledPointCount)"
        }
    }

    public func metricNote(in reconstruction: StockpileResultReconstruction) -> String {
        switch self {
        case .contour:
            return reconstruction.meshDensityLabel
        case .toe:
            return reconstruction.toeMarkerCount == 1 ? "edge checkpoint" : "edge checkpoints"
        case .surface:
            return reconstruction.surfaceRiskCount == 1 ? "surface watch point" : "surface watch points"
        case .all:
            return "toe + surface checks"
        case .threeD:
            return "points supporting mesh"
        }
    }
}

public struct StockpileResultPoint3D: Codable, Sendable, Equatable, Hashable {
    public let x: Float
    public let y: Float
    public let z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct StockpileResultTriangle: Codable, Sendable, Equatable, Hashable {
    public let a: UInt32
    public let b: UInt32
    public let c: UInt32

    public init(a: UInt32, b: UInt32, c: UInt32) {
        self.a = a
        self.b = b
        self.c = c
    }
}

public struct StockpileResultReconstruction: Codable, Sendable, Equatable {
    public let summary: String
    public let footprintAreaM2: Double
    public let peakHeightM: Double
    public let defaultMode: StockpileResultViewerMode
    public let vertices: [StockpileResultPoint3D]
    public let triangles: [StockpileResultTriangle]
    public let pointCloud: [StockpileResultPoint3D]
    public let toeMarkers: [StockpileResultPoint3D]
    public let surfaceRiskMarkers: [StockpileResultPoint3D]

    public init(
        summary: String,
        footprintAreaM2: Double,
        peakHeightM: Double,
        defaultMode: StockpileResultViewerMode = .threeD,
        vertices: [StockpileResultPoint3D],
        triangles: [StockpileResultTriangle],
        pointCloud: [StockpileResultPoint3D],
        toeMarkers: [StockpileResultPoint3D],
        surfaceRiskMarkers: [StockpileResultPoint3D]
    ) {
        self.summary = summary
        self.footprintAreaM2 = footprintAreaM2
        self.peakHeightM = peakHeightM
        self.defaultMode = defaultMode
        self.vertices = vertices
        self.triangles = triangles
        self.pointCloud = pointCloud
        self.toeMarkers = toeMarkers
        self.surfaceRiskMarkers = surfaceRiskMarkers
    }

    public var footprintLabel: String {
        String(format: "%.1f m²", footprintAreaM2)
    }

    public var peakHeightLabel: String {
        String(format: "%.1f m", peakHeightM)
    }

    public var meshFaceCount: Int {
        triangles.count
    }

    public var sampledPointCount: Int {
        pointCloud.count
    }

    public var toeMarkerCount: Int {
        toeMarkers.count
    }

    public var surfaceRiskCount: Int {
        surfaceRiskMarkers.count
    }

    public var attentionCount: Int {
        toeMarkerCount + surfaceRiskCount
    }

    public var meshDensityLabel: String {
        meshFaceCount == 1 ? "1 wireframe face" : "\(meshFaceCount) wireframe faces"
    }
}
