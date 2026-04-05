from __future__ import annotations

import sqlite3
from pathlib import Path

from stockpile.colmap_runner import (
    _COLMAP_PAIR_ID_PRIME,
    _choose_mapper_init_pair,
    _count_database_geometric_matches,
    _decode_colmap_pair_id,
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
