import Foundation

public struct StockpileObservedReferenceMarker: Sendable, Equatable, Identifiable {
    public let markerID: String
    public let visibleCount: Int
    public let confidence: Double
    public let qualityHint: StockpileReferenceMarkerQualityPayload?

    public var id: String { markerID }

    public init(
        markerID: String,
        visibleCount: Int,
        confidence: Double,
        qualityHint: StockpileReferenceMarkerQualityPayload? = nil
    ) {
        self.markerID = markerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.visibleCount = max(0, visibleCount)
        self.confidence = min(max(confidence, 0), 1)
        self.qualityHint = qualityHint
    }
}

public enum StockpileReferenceMarkerSnapshotBuilder {
    public static func makeSnapshots(
        from observations: [StockpileObservedReferenceMarker],
        confirmedConfidenceThreshold: Double = 0.75,
        minimumConfirmedVisibleCount: Int = 2
    ) -> [StockpileReferenceMarkerSnapshotPayload] {
        let clampedConfidenceThreshold = min(max(confirmedConfidenceThreshold, 0), 1)
        let clampedMinimumVisibleCount = max(1, minimumConfirmedVisibleCount)

        var mergedByMarkerID: [String: StockpileObservedReferenceMarker] = [:]

        for observation in observations {
            let normalizedID = observation.markerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedID.isEmpty == false else {
                continue
            }

            let normalizedObservation = StockpileObservedReferenceMarker(
                markerID: normalizedID,
                visibleCount: observation.visibleCount,
                confidence: observation.confidence,
                qualityHint: observation.qualityHint
            )

            if let existingObservation = mergedByMarkerID[normalizedID] {
                mergedByMarkerID[normalizedID] = merge(
                    existingObservation,
                    with: normalizedObservation
                )
            } else {
                mergedByMarkerID[normalizedID] = normalizedObservation
            }
        }

        return mergedByMarkerID.values
            .map { observation in
                StockpileReferenceMarkerSnapshotPayload(
                    markerID: observation.markerID,
                    visibleCount: observation.visibleCount,
                    confidence: observation.confidence,
                    quality: resolvedQuality(
                        for: observation,
                        confirmedConfidenceThreshold: clampedConfidenceThreshold,
                        minimumConfirmedVisibleCount: clampedMinimumVisibleCount
                    )
                )
            }
            .sorted(by: snapshotSortOrder)
    }

    private static func merge(
        _ lhs: StockpileObservedReferenceMarker,
        with rhs: StockpileObservedReferenceMarker
    ) -> StockpileObservedReferenceMarker {
        StockpileObservedReferenceMarker(
            markerID: lhs.markerID,
            visibleCount: max(lhs.visibleCount, rhs.visibleCount),
            confidence: max(lhs.confidence, rhs.confidence),
            qualityHint: strongestQualityHint(lhs.qualityHint, rhs.qualityHint)
        )
    }

    private static func strongestQualityHint(
        _ lhs: StockpileReferenceMarkerQualityPayload?,
        _ rhs: StockpileReferenceMarkerQualityPayload?
    ) -> StockpileReferenceMarkerQualityPayload? {
        switch (lhs, rhs) {
        case (.none, .none):
            return nil
        case let (.some(quality), .none), let (.none, .some(quality)):
            return quality
        case let (.some(lhsQuality), .some(rhsQuality)):
            return qualityRank(lhsQuality) >= qualityRank(rhsQuality) ? lhsQuality : rhsQuality
        }
    }

    private static func resolvedQuality(
        for observation: StockpileObservedReferenceMarker,
        confirmedConfidenceThreshold: Double,
        minimumConfirmedVisibleCount: Int
    ) -> StockpileReferenceMarkerQualityPayload {
        let derivedQuality: StockpileReferenceMarkerQualityPayload
        if observation.visibleCount <= 0 || observation.confidence <= 0 {
            derivedQuality = .missing
        } else if observation.visibleCount >= minimumConfirmedVisibleCount,
                  observation.confidence >= confirmedConfidenceThreshold {
            derivedQuality = .confirmed
        } else {
            derivedQuality = .weak
        }

        guard let qualityHint = observation.qualityHint else {
            return derivedQuality
        }

        return qualityRank(qualityHint) >= qualityRank(derivedQuality)
            ? qualityHint
            : derivedQuality
    }

    private static func snapshotSortOrder(
        _ lhs: StockpileReferenceMarkerSnapshotPayload,
        _ rhs: StockpileReferenceMarkerSnapshotPayload
    ) -> Bool {
        let lhsRank = qualityRank(lhs.quality)
        let rhsRank = qualityRank(rhs.quality)
        if lhsRank != rhsRank {
            return lhsRank > rhsRank
        }

        if lhs.visibleCount != rhs.visibleCount {
            return lhs.visibleCount > rhs.visibleCount
        }

        if lhs.confidence != rhs.confidence {
            return lhs.confidence > rhs.confidence
        }

        return lhs.markerID.localizedCaseInsensitiveCompare(rhs.markerID) == .orderedAscending
    }

    private static func qualityRank(_ quality: StockpileReferenceMarkerQualityPayload) -> Int {
        switch quality {
        case .confirmed:
            return 2
        case .weak:
            return 1
        case .missing:
            return 0
        }
    }
}
