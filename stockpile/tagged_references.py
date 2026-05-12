"""Tagged-reference models for future physical scale calibration."""

from __future__ import annotations

from dataclasses import dataclass, field
from math import dist


Point2D = tuple[float, float]
Point3D = tuple[float, float, float]


@dataclass(frozen=True)
class TaggedReferenceSpec:
    """Physical description of a known tagged reference near a stockpile."""

    tag_id: int
    family: str = "tag36h11"
    label: str | None = None
    tag_size_m: float = 0.18
    reference_height_m: float | None = None
    reference_width_m: float | None = None
    mounting_height_m: float | None = None
    notes: str | None = None

    def __post_init__(self):
        if self.tag_id < 0:
            raise ValueError("tag_id must be non-negative")
        if self.tag_size_m <= 0:
            raise ValueError("tag_size_m must be positive")
        if self.reference_height_m is not None and self.reference_height_m <= 0:
            raise ValueError("reference_height_m must be positive when provided")
        if self.reference_width_m is not None and self.reference_width_m <= 0:
            raise ValueError("reference_width_m must be positive when provided")
        if self.mounting_height_m is not None and self.mounting_height_m < 0:
            raise ValueError("mounting_height_m must be non-negative when provided")

    @property
    def display_name(self) -> str:
        return self.label or f"{self.family}:{self.tag_id}"

    @property
    def scale_dimension_m(self) -> float:
        """Best-known physical dimension for the overall reference object."""
        return self.reference_height_m or self.reference_width_m or self.tag_size_m

    @property
    def calibration_tag_size_m(self) -> float:
        """Physical size of the visible encoded tag face used by corner-based calibration."""
        return self.tag_size_m

    @property
    def has_extended_reference_geometry(self) -> bool:
        """True when the physical reference is larger than the printed tag itself."""
        return any(
            dimension is not None and abs(float(dimension) - float(self.tag_size_m)) > 1e-9
            for dimension in (self.reference_height_m, self.reference_width_m)
        )


@dataclass(frozen=True)
class TaggedReferenceDetection:
    """A single 2D tag detection in a frame."""

    frame_name: str
    tag_id: int
    family: str
    corners_px: tuple[Point2D, Point2D, Point2D, Point2D]
    decision_margin: float | None = None
    hamming: int | None = None

    def __post_init__(self):
        if len(self.corners_px) != 4:
            raise ValueError("corners_px must contain four corners")
        if self.tag_id < 0:
            raise ValueError("tag_id must be non-negative")
        if not self.frame_name:
            raise ValueError("frame_name must be non-empty")

    @property
    def center_px(self) -> Point2D:
        xs = [corner[0] for corner in self.corners_px]
        ys = [corner[1] for corner in self.corners_px]
        return (sum(xs) / 4.0, sum(ys) / 4.0)

    @property
    def bbox(self) -> tuple[float, float, float, float]:
        xs = [corner[0] for corner in self.corners_px]
        ys = [corner[1] for corner in self.corners_px]
        min_x = min(xs)
        min_y = min(ys)
        return (min_x, min_y, max(xs) - min_x, max(ys) - min_y)

    @property
    def mean_edge_length_px(self) -> float:
        corners = self.corners_px
        edge_lengths = [
            dist(corners[index], corners[(index + 1) % len(corners)])
            for index in range(len(corners))
        ]
        return sum(edge_lengths) / len(edge_lengths)


@dataclass
class TaggedReferenceTrack:
    """Aggregated observations for a single physical tagged reference."""

    spec: TaggedReferenceSpec
    detections: list[TaggedReferenceDetection] = field(default_factory=list)
    scale_samples_m_per_unit: list[float] = field(default_factory=list)
    reference_position_3d: Point3D | None = None

    def add_detection(self, detection: TaggedReferenceDetection):
        if detection.tag_id != self.spec.tag_id:
            raise ValueError(
                f"Detection tag_id {detection.tag_id} does not match spec {self.spec.tag_id}",
            )
        self.detections.append(detection)

    @property
    def num_detections(self) -> int:
        return len(self.detections)

    @property
    def is_triangulated(self) -> bool:
        return self.reference_position_3d is not None

    @property
    def best_scale_sample_m_per_unit(self) -> float | None:
        if not self.scale_samples_m_per_unit:
            return None
        return sum(self.scale_samples_m_per_unit) / len(self.scale_samples_m_per_unit)


@dataclass(frozen=True)
class TaggedReferenceCatalog:
    """Lookup layer for known tagged references in a capture session."""

    references: tuple[TaggedReferenceSpec, ...] = ()

    def __post_init__(self):
        seen_ids: set[tuple[str, int]] = set()
        for reference in self.references:
            key = (reference.family, reference.tag_id)
            if key in seen_ids:
                raise ValueError(
                    f"Duplicate tagged reference spec for family={reference.family!r}, "
                    f"tag_id={reference.tag_id}",
                )
            seen_ids.add(key)

    def get(self, tag_id: int, family: str) -> TaggedReferenceSpec | None:
        for reference in self.references:
            if reference.tag_id == tag_id and reference.family == family:
                return reference
        return None

    @property
    def tag_ids(self) -> tuple[int, ...]:
        return tuple(reference.tag_id for reference in self.references)


__all__ = [
    "Point2D",
    "Point3D",
    "TaggedReferenceCatalog",
    "TaggedReferenceDetection",
    "TaggedReferenceSpec",
    "TaggedReferenceTrack",
]
