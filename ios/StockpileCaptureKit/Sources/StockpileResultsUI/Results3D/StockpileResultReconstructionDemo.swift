import Foundation

public extension StockpileResultReconstruction {
    static let demoVerified = makeDemo(
        summary: "Start with the full shape, then confirm that the toe and surface remain clean enough for release.",
        footprintAreaM2: 782.4,
        peakHeightM: 5.1,
        profile: .verified
    )

    static let demoReview = makeDemo(
        summary: "Use focused inspection modes to review the weaker quadrant before this result is treated as final.",
        footprintAreaM2: 843.2,
        peakHeightM: 5.3,
        profile: .review
    )

    static let demoBlocked = makeDemo(
        summary: "Inspect the toe and surface gaps here, then plan a cleaner recapture before reporting.",
        footprintAreaM2: 801.6,
        peakHeightM: 4.7,
        profile: .blocked
    )

    private enum DemoProfile {
        case verified
        case review
        case blocked
    }

    private static func makeDemo(
        summary: String,
        footprintAreaM2: Double,
        peakHeightM: Double,
        profile: DemoProfile
    ) -> StockpileResultReconstruction {
        let defaultMode: StockpileResultViewerMode
        switch profile {
        case .verified:
            defaultMode = .threeD
        case .review:
            defaultMode = .surface
        case .blocked:
            defaultMode = .toe
        }

        let size = 18
        let spacing: Float = 0.9
        var vertices: [StockpileResultPoint3D] = []
        var pointCloud: [StockpileResultPoint3D] = []
        var toeMarkers: [StockpileResultPoint3D] = []
        var surfaceRiskMarkers: [StockpileResultPoint3D] = []

        for row in 0..<size {
            for column in 0..<size {
                let centeredX = (Float(column) - Float(size - 1) / 2) * spacing
                let centeredY = (Float(row) - Float(size - 1) / 2) * spacing
                let radialDistance = sqrt(centeredX * centeredX + centeredY * centeredY)
                let normalized = min(radialDistance / 7.5, 1.3)
                let ridge = max(0, 1.0 - pow(normalized, 1.8))

                let asymmetry: Float = switch profile {
                case .verified:
                    0.10 * sin(centeredX * 0.35) + 0.08 * cos(centeredY * 0.28)
                case .review:
                    0.18 * sin(centeredX * 0.45) - 0.14 * cos(centeredY * 0.38)
                case .blocked:
                    0.26 * sin(centeredX * 0.42) - 0.20 * cos(centeredY * 0.30)
                }

                var height = max(0, ridge * Float(peakHeightM) + asymmetry)
                if profile != .verified && centeredX > 1.8 && centeredY < -1.2 {
                    height *= 0.84
                }
                if profile == .blocked && centeredX < -2.0 && centeredY > 0.6 {
                    height *= 0.74
                }

                let point = StockpileResultPoint3D(x: centeredX, y: centeredY, z: height)
                vertices.append(point)

                if row.isMultiple(of: 2) && column.isMultiple(of: 2) {
                    pointCloud.append(point)
                }

                if radialDistance > 5.7 && radialDistance < 7.0 && (row + column).isMultiple(of: 3) {
                    toeMarkers.append(StockpileResultPoint3D(x: centeredX, y: centeredY, z: max(0.05, height * 0.12)))
                }

                switch profile {
                case .verified:
                    if centeredX > 3.2 && centeredY > 1.8 && radialDistance < 5.8 && (row + column).isMultiple(of: 7) {
                        surfaceRiskMarkers.append(StockpileResultPoint3D(x: centeredX, y: centeredY, z: height + 0.12))
                    }
                case .review:
                    if centeredX > 1.2 && centeredY < -0.8 && (row + column).isMultiple(of: 5) {
                        surfaceRiskMarkers.append(StockpileResultPoint3D(x: centeredX, y: centeredY, z: height + 0.18))
                    }
                case .blocked:
                    if centeredX < -1.0 && centeredY > 0.5 && (row + column).isMultiple(of: 4) {
                        surfaceRiskMarkers.append(StockpileResultPoint3D(x: centeredX, y: centeredY, z: height + 0.22))
                    }
                }
            }
        }

        var triangles: [StockpileResultTriangle] = []
        for row in 0..<(size - 1) {
            for column in 0..<(size - 1) {
                let topLeft = UInt32(row * size + column)
                let topRight = UInt32(row * size + column + 1)
                let bottomLeft = UInt32((row + 1) * size + column)
                let bottomRight = UInt32((row + 1) * size + column + 1)

                triangles.append(StockpileResultTriangle(a: topLeft, b: bottomLeft, c: topRight))
                triangles.append(StockpileResultTriangle(a: topRight, b: bottomLeft, c: bottomRight))
            }
        }

        return StockpileResultReconstruction(
            summary: summary,
            footprintAreaM2: footprintAreaM2,
            peakHeightM: peakHeightM,
            defaultMode: defaultMode,
            vertices: vertices,
            triangles: triangles,
            pointCloud: pointCloud,
            toeMarkers: toeMarkers,
            surfaceRiskMarkers: surfaceRiskMarkers
        )
    }
}
