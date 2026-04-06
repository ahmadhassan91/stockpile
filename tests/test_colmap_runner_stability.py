from __future__ import annotations

import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import pytest

from stockpile.colmap_runner import (
    _COLMAP_PAIR_ID_PRIME,
    _choose_mapper_init_pair,
    _count_database_geometric_matches,
    _decode_colmap_pair_id,
    _is_unsuitable_init_pair_failure,
    _run_colmap_command,
)


def _encode_pair_id(image_id1: int, image_id2: int) -> int:
    a, b = sorted((int(image_id1), int(image_id2)))
    return a * _COLMAP_PAIR_ID_PRIME + b


def _init_db(path: Path) -> None:
    with sqlite3.connect(str(path)) as conn:
        conn.execute(
            """
            CREATE TABLE two_view_geometries (
                pair_id INTEGER PRIMARY KEY,
                rows INTEGER NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE images (
                image_id INTEGER PRIMARY KEY,
                name TEXT NOT NULL
            )
            """
        )
        conn.commit()


def test_decode_colmap_pair_id_round_trip():
    pair_id = _encode_pair_id(7, 19)
    assert _decode_colmap_pair_id(pair_id) == (7, 19)


def test_choose_mapper_init_pair_prefers_highest_inliers_then_smallest_pair_id(tmp_path):
    db_path = tmp_path / "database.db"
    _init_db(db_path)
    with sqlite3.connect(str(db_path)) as conn:
        conn.execute(
            "INSERT INTO two_view_geometries(pair_id, rows) VALUES (?, ?)",
            (_encode_pair_id(2, 3), 60),
        )
        conn.execute(
            "INSERT INTO two_view_geometries(pair_id, rows) VALUES (?, ?)",
            (_encode_pair_id(1, 2), 60),
        )
        conn.execute(
            "INSERT INTO two_view_geometries(pair_id, rows) VALUES (?, ?)",
            (_encode_pair_id(3, 4), 55),
        )
        conn.commit()

    assert _choose_mapper_init_pair(db_path, min_inliers=50) == (1, 2)


def test_choose_mapper_init_pair_returns_none_when_threshold_not_met(tmp_path):
    db_path = tmp_path / "database.db"
    _init_db(db_path)
    with sqlite3.connect(str(db_path)) as conn:
        conn.execute(
            "INSERT INTO two_view_geometries(pair_id, rows) VALUES (?, ?)",
            (_encode_pair_id(4, 9), 12),
        )
        conn.commit()

    assert _choose_mapper_init_pair(db_path, min_inliers=20) is None


def test_choose_mapper_init_pair_prefers_wider_baseline_when_gap_requested(tmp_path):
    db_path = tmp_path / "database.db"
    _init_db(db_path)
    with sqlite3.connect(str(db_path)) as conn:
        conn.execute("INSERT INTO images(image_id, name) VALUES (?, ?)", (84, "frame_00084.jpg"))
        conn.execute("INSERT INTO images(image_id, name) VALUES (?, ?)", (85, "frame_00085.jpg"))
        conn.execute("INSERT INTO images(image_id, name) VALUES (?, ?)", (20, "frame_00020.jpg"))
        conn.execute("INSERT INTO images(image_id, name) VALUES (?, ?)", (60, "frame_00060.jpg"))
        conn.execute(
            "INSERT INTO two_view_geometries(pair_id, rows) VALUES (?, ?)",
            (_encode_pair_id(84, 85), 120),
        )
        conn.execute(
            "INSERT INTO two_view_geometries(pair_id, rows) VALUES (?, ?)",
            (_encode_pair_id(20, 60), 110),
        )
        conn.commit()

    assert _choose_mapper_init_pair(db_path, min_inliers=50, min_frame_gap=12) == (20, 60)


def test_choose_mapper_init_pair_falls_back_when_no_pair_meets_gap(tmp_path):
    db_path = tmp_path / "database.db"
    _init_db(db_path)
    with sqlite3.connect(str(db_path)) as conn:
        conn.execute("INSERT INTO images(image_id, name) VALUES (?, ?)", (1, "frame_00001.jpg"))
        conn.execute("INSERT INTO images(image_id, name) VALUES (?, ?)", (2, "frame_00002.jpg"))
        conn.execute("INSERT INTO images(image_id, name) VALUES (?, ?)", (3, "frame_00003.jpg"))
        conn.execute(
            "INSERT INTO two_view_geometries(pair_id, rows) VALUES (?, ?)",
            (_encode_pair_id(1, 2), 80),
        )
        conn.execute(
            "INSERT INTO two_view_geometries(pair_id, rows) VALUES (?, ?)",
            (_encode_pair_id(2, 3), 70),
        )
        conn.commit()

    assert _choose_mapper_init_pair(db_path, min_inliers=20, min_frame_gap=12) == (1, 2)


def test_choose_mapper_init_pair_scans_beyond_early_candidates_for_wide_gap(tmp_path):
    db_path = tmp_path / "database.db"
    _init_db(db_path)
    with sqlite3.connect(str(db_path)) as conn:
        for image_id in range(1, 401):
            conn.execute(
                "INSERT INTO images(image_id, name) VALUES (?, ?)",
                (image_id, f"frame_{image_id:05d}.jpg"),
            )
        # Many strong but near-consecutive pairs first.
        for image_id in range(1, 330):
            conn.execute(
                "INSERT INTO two_view_geometries(pair_id, rows) VALUES (?, ?)",
                (_encode_pair_id(image_id, image_id + 1), 10000 - image_id),
            )
        # Lower-ranked but wide-baseline candidate.
        conn.execute(
            "INSERT INTO two_view_geometries(pair_id, rows) VALUES (?, ?)",
            (_encode_pair_id(10, 200), 9600),
        )
        conn.commit()

    assert _choose_mapper_init_pair(db_path, min_inliers=100, min_frame_gap=12) == (10, 200)


def test_count_database_geometric_matches_counts_only_positive_rows(tmp_path):
    db_path = tmp_path / "database.db"
    _init_db(db_path)
    with sqlite3.connect(str(db_path)) as conn:
        conn.execute(
            "INSERT INTO two_view_geometries(pair_id, rows) VALUES (?, ?)",
            (_encode_pair_id(1, 2), 0),
        )
        conn.execute(
            "INSERT INTO two_view_geometries(pair_id, rows) VALUES (?, ?)",
            (_encode_pair_id(2, 3), 18),
        )
        conn.execute(
            "INSERT INTO two_view_geometries(pair_id, rows) VALUES (?, ?)",
            (_encode_pair_id(3, 4), 4),
        )
        conn.commit()

    assert _count_database_geometric_matches(db_path) == 2


def test_is_unsuitable_init_pair_failure_true_when_marker_present(tmp_path):
    (tmp_path / "mapper.stderr.log").write_text(
        "E.... Provided pair is unsuitable for initialization\n"
    )
    assert _is_unsuitable_init_pair_failure(tmp_path, "mapper")


def test_is_unsuitable_init_pair_failure_false_for_other_errors(tmp_path):
    (tmp_path / "mapper.stderr.log").write_text(
        "Reached maximum runtime of 420 seconds.\n"
        "Could not open /path/to/project.ini\n"
    )
    assert not _is_unsuitable_init_pair_failure(tmp_path, "mapper")


def test_run_colmap_command_kills_detached_children_on_timeout(tmp_path):
    marker_path = tmp_path / "timeout-marker.db"
    script_path = tmp_path / "spawn_detached.py"
    script_path.write_text(
        "import subprocess\n"
        "import sys\n"
        "import time\n"
        "marker = sys.argv[1]\n"
        "subprocess.Popen(\n"
        "    [sys.executable, '-c', 'import time; time.sleep(30)', marker],\n"
        "    start_new_session=True,\n"
        ")\n"
        "time.sleep(30)\n"
    )

    with pytest.raises(subprocess.TimeoutExpired):
        _run_colmap_command(
            [sys.executable, str(script_path), str(marker_path)],
            tmp_path,
            "timeout_cleanup",
            timeout=1,
        )

    time.sleep(0.5)
    process_listing = subprocess.run(
        ["ps", "-eo", "pid=,args="],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert str(marker_path) not in process_listing.stdout
