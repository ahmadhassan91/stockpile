"""2D tagged-reference detection using OpenCV ArUco/AprilTag dictionaries."""

from __future__ import annotations

import logging
from pathlib import Path

import cv2
import numpy as np

from .config import TaggedReferenceConfig
from .tagged_references import TaggedReferenceDetection

logger = logging.getLogger(__name__)


_ARUCO_DICTIONARY_BY_FAMILY = {
    "tag16h5": "DICT_APRILTAG_16h5",
    "tag25h9": "DICT_APRILTAG_25h9",
    "tag36h10": "DICT_APRILTAG_36h10",
    "tag36h11": "DICT_APRILTAG_36h11",
}


def _resolve_aruco_dictionary(family: str):
    aruco = getattr(cv2, "aruco", None)
    if aruco is None:
        return None

    dictionary_name = _ARUCO_DICTIONARY_BY_FAMILY.get(family.lower())
    if dictionary_name is None:
        logger.warning("Unsupported tagged reference family: %s", family)
        return None

    dictionary_id = getattr(aruco, dictionary_name, None)
    if dictionary_id is None:
        logger.warning(
            "OpenCV aruco runtime does not expose dictionary %s for family %s",
            dictionary_name,
            family,
        )
        return None

    return aruco.getPredefinedDictionary(dictionary_id)


def _build_detector(dictionary):
    aruco = getattr(cv2, "aruco", None)
    if aruco is None:
        return None

    parameters_factory = getattr(aruco, "DetectorParameters", None)
    if callable(parameters_factory):
        parameters = parameters_factory()
    else:
        parameters = aruco.DetectorParameters_create()

    detector_cls = getattr(aruco, "ArucoDetector", None)
    if detector_cls is not None:
        return detector_cls(dictionary, parameters)
    return (dictionary, parameters)


def detect_tagged_references(
    image_bgr: np.ndarray,
    config: TaggedReferenceConfig | None = None,
) -> list[TaggedReferenceDetection]:
    """Detect physical tagged references in a BGR image.

    This is intentionally conservative. It only returns detections that:
    - match the configured tag family
    - pass the minimum edge-size threshold
    - pass the configured tag allowlist/catalog rules
    """
    config = config or TaggedReferenceConfig()
    if not config.enabled:
        return []

    dictionary = _resolve_aruco_dictionary(config.family)
    if dictionary is None:
        return []

    detector = _build_detector(dictionary)
    if detector is None:
        return []

    gray = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2GRAY)

    if isinstance(detector, tuple):
        aruco = cv2.aruco
        corners, ids, _ = aruco.detectMarkers(gray, detector[0], parameters=detector[1])
    else:
        corners, ids, _ = detector.detectMarkers(gray)

    if ids is None or len(ids) == 0:
        return []

    detections: list[TaggedReferenceDetection] = []
    for marker_corners, raw_id in zip(corners, ids.flatten(), strict=False):
        tag_id = int(raw_id)
        spec = config.spec_for_tag(tag_id)
        if spec is None:
            continue

        corners_array = np.asarray(marker_corners, dtype=float).reshape(-1, 2)
        if corners_array.shape != (4, 2):
            continue

        corners_px = tuple((float(x), float(y)) for x, y in corners_array)
        detection = TaggedReferenceDetection(
            frame_name="<single-frame>",
            tag_id=tag_id,
            family=spec.family,
            corners_px=corners_px,
        )
        if detection.mean_edge_length_px < config.min_tag_edge_px:
            continue

        detections.append(detection)

    return detections


def detect_tagged_references_in_frames(
    frame_paths: list[Path],
    config: TaggedReferenceConfig | None = None,
    progress_callback=None,
) -> dict[str, list[TaggedReferenceDetection]]:
    """Detect tagged references across multiple frames."""
    config = config or TaggedReferenceConfig()
    results: dict[str, list[TaggedReferenceDetection]] = {}

    for index, path in enumerate(frame_paths):
        image = cv2.imread(str(path))
        if image is None:
            logger.warning("Cannot read image: %s", path)
            continue

        detections = []
        for detection in detect_tagged_references(image, config):
            detections.append(
                TaggedReferenceDetection(
                    frame_name=path.name,
                    tag_id=detection.tag_id,
                    family=detection.family,
                    corners_px=detection.corners_px,
                    decision_margin=detection.decision_margin,
                    hamming=detection.hamming,
                )
            )

        if detections:
            results[path.name] = detections

        if progress_callback:
            progress_callback((index + 1) / len(frame_paths))

    logger.info(
        "Found tagged references in %d / %d frames",
        len(results),
        len(frame_paths),
    )
    return results


__all__ = [
    "detect_tagged_references",
    "detect_tagged_references_in_frames",
]
