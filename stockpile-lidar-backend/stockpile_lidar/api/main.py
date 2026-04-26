from __future__ import annotations

from fastapi import FastAPI

from stockpile_lidar.api.routes import captures, jobs, results
from stockpile_lidar.config import BackendSettings, get_settings


API_V2_PREFIX = "/api/v2"


def create_app(settings: BackendSettings | None = None) -> FastAPI:
    resolved_settings = settings or get_settings()
    app = FastAPI(
        title="Stockpile LiDAR Backend",
        version=resolved_settings.version,
    )

    @app.get("/health", tags=["health"])
    async def health() -> dict[str, str]:
        return {
            "status": "ok",
            "service": resolved_settings.service_name,
        }

    app.include_router(captures.router, prefix=API_V2_PREFIX)
    app.include_router(jobs.router, prefix=API_V2_PREFIX)
    app.include_router(results.router, prefix=API_V2_PREFIX)
    return app


app = create_app()
