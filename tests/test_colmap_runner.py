from __future__ import annotations

from stockpile.colmap_runner import _should_prefer_sequential_matching
from stockpile.config import ColmapConfig


def test_prefers_sequential_matching_for_large_video_subsets():
    config = ColmapConfig(use_sequential_matching=True, sequential_matching_min_frames=120)

    assert _should_prefer_sequential_matching(config, 300) is True
    assert _should_prefer_sequential_matching(config, 120) is True


def test_uses_exhaustive_matching_for_small_or_disabled_runs():
    enabled = ColmapConfig(use_sequential_matching=True, sequential_matching_min_frames=120)
    disabled = ColmapConfig(use_sequential_matching=False, sequential_matching_min_frames=120)

    assert _should_prefer_sequential_matching(enabled, 119) is False
    assert _should_prefer_sequential_matching(disabled, 300) is False
