from __future__ import annotations

import os
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path


@dataclass(frozen=True)
class BackendSettings:
    service_name: str = "stockpile-lidar-backend"
    version: str = "0.1.0"
    environment: str = "development"
    storage_root: Path = Path("/tmp/stockpile-lidar")


@lru_cache(maxsize=1)
def get_settings() -> BackendSettings:
    return BackendSettings(
        environment=os.getenv("STOCKPILE_LIDAR_ENV", "development"),
        storage_root=Path(os.getenv("STOCKPILE_LIDAR_STORAGE_ROOT", "/tmp/stockpile-lidar")),
    )
