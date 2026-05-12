#if os(iOS) && canImport(ARKit)
import ARKit
import CoreVideo
import Foundation
import simd

final class StockpileARKitQuickVolumeEstimator {
    private struct GridKey: Hashable {
        let x: Int
        let z: Int
    }

    private let maximumRetainedPoints = 3_600
    private let minimumDepthSamplingIntervalSec: TimeInterval = 0.25
    private let minimumCameraMoveM: Float = 0.12
    private var sampledWorldPoints: [SIMD3<Float>] = []
    private var cameraPositions: [SIMD3<Float>] = []
    private var lastDepthSampleTimestamp: TimeInterval?
    private var currentEstimate: StockpileDevicePoseQuickVolumeEstimate?

    func reset() {
        sampledWorldPoints.removeAll(keepingCapacity: true)
        cameraPositions.removeAll(keepingCapacity: true)
        lastDepthSampleTimestamp = nil
        currentEstimate = nil
    }

    func update(
        frame: ARFrame,
        preferSmoothedDepth: Bool
    ) -> StockpileDevicePoseQuickVolumeEstimate? {
        guard frame.camera.trackingState.isStable else {
            return nil
        }

        guard
            let depthData = preferSmoothedDepth
                ? (frame.smoothedSceneDepth ?? frame.sceneDepth)
                : (frame.sceneDepth ?? frame.smoothedSceneDepth)
        else {
            return nil
        }

        let cameraPosition = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )
        appendCameraPosition(cameraPosition)

        if let lastDepthSampleTimestamp,
           frame.timestamp - lastDepthSampleTimestamp < minimumDepthSamplingIntervalSec {
            return currentEstimate
        }
        lastDepthSampleTimestamp = frame.timestamp

        sampledWorldPoints.append(
            contentsOf: sampleWorldPoints(
                from: depthData.depthMap,
                camera: frame.camera
            )
        )
        if sampledWorldPoints.count > maximumRetainedPoints {
            sampledWorldPoints.removeFirst(sampledWorldPoints.count - maximumRetainedPoints)
        }

        currentEstimate = makeEstimate()
        return currentEstimate
    }

    private func appendCameraPosition(_ position: SIMD3<Float>) {
        guard let last = cameraPositions.last else {
            cameraPositions.append(position)
            return
        }

        if simd_distance(last, position) >= minimumCameraMoveM {
            cameraPositions.append(position)
        }
    }

    private func sampleWorldPoints(
        from depthMap: CVPixelBuffer,
        camera: ARCamera
    ) -> [SIMD3<Float>] {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return []
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let floatsPerRow = bytesPerRow / MemoryLayout<Float32>.stride
        let pointer = baseAddress.assumingMemoryBound(to: Float32.self)

        let stepX = max(8, width / 18)
        let stepY = max(8, height / 24)
        let xRange = stride(from: width / 10, to: max(width / 10 + 1, (width * 9) / 10), by: stepX)
        let yRange = stride(from: height / 5, to: max(height / 5 + 1, (height * 19) / 20), by: stepY)
        let intrinsics = camera.intrinsics
        let imageResolution = camera.imageResolution
        let scaleX = Float(width) / max(Float(imageResolution.width), 1)
        let scaleY = Float(height) / max(Float(imageResolution.height), 1)
        let fx = intrinsics.columns.0.x * scaleX
        let fy = intrinsics.columns.1.y * scaleY
        let cx = intrinsics.columns.2.x * scaleX
        let cy = intrinsics.columns.2.y * scaleY
        let cameraTransform = camera.transform
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(192)

        for y in yRange {
            let row = pointer.advanced(by: y * floatsPerRow)
            for x in xRange {
                let depth = row[x]
                guard depth.isFinite, depth >= 0.25, depth <= 15 else {
                    continue
                }

                let pixel = SIMD3<Float>(Float(x), Float(y), 1)
                let cameraPoint = SIMD3<Float>(
                    (pixel.x - cx) * depth / fx,
                    (pixel.y - cy) * depth / fy,
                    depth
                )
                let worldPoint = cameraTransform * SIMD4<Float>(cameraPoint, 1)
                let sample = SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)
                guard sample.x.isFinite, sample.y.isFinite, sample.z.isFinite else {
                    continue
                }
                points.append(sample)
            }
        }

        return points
    }

    private func makeEstimate() -> StockpileDevicePoseQuickVolumeEstimate? {
        guard sampledWorldPoints.count >= 240, cameraPositions.count >= 4 else {
            return nil
        }

        let pathDistance = totalPathDistance(cameraPositions)
        guard pathDistance >= 1.5 else {
            return nil
        }

        let candidatePoints = sampledWorldPoints
        guard candidatePoints.count >= 180 else {
            return nil
        }

        let groundY = percentile(candidatePoints.map { $0.y }, percentile: 0.10)
        let pilePoints = candidatePoints.filter { point in
            point.y > groundY + 0.08 && point.y < groundY + 12
        }
        guard pilePoints.count >= 120 else {
            return nil
        }
        let rawHeights = pilePoints.map { $0.y - groundY }
        let robustPeakLimit = max(0.35, percentile(rawHeights, percentile: 0.96) * 1.20)

        let minX = pilePoints.map { $0.x }.min() ?? 0
        let maxX = pilePoints.map { $0.x }.max() ?? 0
        let minZ = pilePoints.map { $0.z }.min() ?? 0
        let maxZ = pilePoints.map { $0.z }.max() ?? 0
        guard maxX - minX >= 0.5, maxZ - minZ >= 0.5 else {
            return nil
        }

        let footprintSpan = max(Double(maxX - minX), Double(maxZ - minZ))
        let cellSize = max(0.15, min(0.55, footprintSpan / 20.0))
        let cellArea = cellSize * cellSize
        var maximumHeightByCell: [GridKey: Float] = [:]

        for point in pilePoints {
            let height = min(max(0, point.y - groundY), robustPeakLimit)
            guard height >= 0.03 else {
                continue
            }
            let key = GridKey(
                x: Int(floor(Double(point.x - minX) / cellSize)),
                z: Int(floor(Double(point.z - minZ) / cellSize))
            )
            let existingHeight = maximumHeightByCell[key] ?? 0
            if height > existingHeight {
                maximumHeightByCell[key] = height
            }
        }

        guard maximumHeightByCell.count >= 8 else {
            return nil
        }

        let cellHeights = Array(maximumHeightByCell.values)
        let stableHeightCeiling = max(0.35, percentile(cellHeights, percentile: 0.90) * 1.15)
        let stableHeights = cellHeights.map { min($0, stableHeightCeiling) }
        let footprintAreaM2 = Double(maximumHeightByCell.count) * cellArea
        let peakHeightM = Double(percentile(stableHeights, percentile: 0.90))
        let volumeM3 = stableHeights.reduce(0.0) { partial, height in
            partial + Double(height) * cellArea
        }
        guard footprintAreaM2.isFinite,
              peakHeightM.isFinite,
              volumeM3.isFinite,
              footprintAreaM2 > 0,
              peakHeightM > 0.10,
              volumeM3 > 0.10
        else {
            return nil
        }

        let footprintScore = min(1.0, footprintAreaM2 / 3.0)
        let pointScore = min(1.0, Double(pilePoints.count) / 900.0)
        let pathScore = min(1.0, Double(pathDistance) / 14.0)
        let heightScore = min(1.0, peakHeightM / 3.0)
        let confidenceScore = min(
            1.0,
            max(
                0.0,
                footprintScore * 0.35
                    + pointScore * 0.30
                    + pathScore * 0.20
                    + heightScore * 0.15
            )
        )

        return StockpileDevicePoseQuickVolumeEstimate(
            volumeM3: volumeM3,
            footprintAreaM2: footprintAreaM2,
            peakHeightM: peakHeightM,
            confidenceScore: confidenceScore,
            sampledPointCount: pilePoints.count,
            cameraPathDistanceM: Double(pathDistance)
        )
    }

    private func totalPathDistance(_ positions: [SIMD3<Float>]) -> Float {
        guard positions.count > 1 else {
            return 0
        }

        return zip(positions, positions.dropFirst()).reduce(into: 0) { partial, pair in
            partial += simd_distance(pair.0, pair.1)
        }
    }

    private func convexHull(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let uniquePoints = Array(Set(points.map(HullPoint.init))).sorted()
        guard uniquePoints.count > 2 else {
            return uniquePoints.map(\.vector)
        }

        var lower: [HullPoint] = []
        for point in uniquePoints {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }

        var upper: [HullPoint] = []
        for point in uniquePoints.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }

        return Array((lower.dropLast() + upper.dropLast()).map(\.vector))
    }

    private func pointInPolygon(_ point: SIMD2<Float>, polygon: [SIMD2<Float>]) -> Bool {
        guard polygon.count >= 3 else {
            return false
        }

        var contains = false
        var previous = polygon.last!
        for current in polygon {
            let denominator = previous.y - current.y
            let intersects = ((current.y > point.y) != (previous.y > point.y))
                && abs(denominator) > 1e-6
                && (point.x < (previous.x - current.x) * (point.y - current.y) / denominator + current.x)
            if intersects {
                contains.toggle()
            }
            previous = current
        }
        return contains
    }

    private func polygonArea(_ polygon: [SIMD2<Float>]) -> Float {
        guard polygon.count >= 3 else {
            return 0
        }

        var signedArea = Float.zero
        for index in polygon.indices {
            let nextIndex = polygon.index(after: index) == polygon.endIndex ? polygon.startIndex : polygon.index(after: index)
            let current = polygon[index]
            let next = polygon[nextIndex]
            signedArea += current.x * next.y - next.x * current.y
        }
        return abs(signedArea) * 0.5
    }

    private func percentile(_ values: [Float], percentile: Double) -> Float {
        guard values.isEmpty == false else {
            return 0
        }

        let sorted = values.sorted()
        let clamped = min(max(percentile, 0), 1)
        let index = Int((Double(sorted.count - 1) * clamped).rounded(.toNearestOrAwayFromZero))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private func cross(_ a: HullPoint, _ b: HullPoint, _ c: HullPoint) -> Float {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private struct HullPoint: Hashable, Comparable {
        let x: Float
        let y: Float

        init(_ vector: SIMD2<Float>) {
            self.x = vector.x
            self.y = vector.y
        }

        var vector: SIMD2<Float> { SIMD2<Float>(x, y) }

        static func < (lhs: HullPoint, rhs: HullPoint) -> Bool {
            if lhs.x != rhs.x {
                return lhs.x < rhs.x
            }
            return lhs.y < rhs.y
        }
    }
}

private extension ARCamera.TrackingState {
    var isStable: Bool {
        if case .normal = self {
            return true
        }
        return false
    }
}
#endif
