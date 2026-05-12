#!/usr/bin/env python3
"""Run the real local FastAPI mobile API for the iOS alpha flow."""

from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path

import uvicorn

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from stockpile.mobile_api_service import StockpileMobileAPIService  # noqa: E402
from stockpile.mobile_job_runtime import (  # noqa: E402
    StockpileMobileJobRuntimeConfiguration,
)


logger = logging.getLogger("stockpile.mobile_api_dev")


def _configure_pythonpath(repo_root: Path):
    raw_pythonpath = os.environ.get("PYTHONPATH", "")
    components = [component for component in raw_pythonpath.split(os.pathsep) if component]
    repo_root_str = str(repo_root)
    if repo_root_str not in components:
        os.environ["PYTHONPATH"] = os.pathsep.join([repo_root_str, *components]) if components else repo_root_str


def _bool_env(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return default
    return raw in {"1", "true", "yes", "on"}


def _auth_summary() -> str:
    if os.environ.get("STOCKPILE_MOBILE_API_BEARER_TOKEN", "").strip():
        return "bearer token enabled"
    if os.environ.get("STOCKPILE_MOBILE_API_KEY", "").strip():
        return "x-api-key enabled"
    return "disabled"


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent

    parser = argparse.ArgumentParser(description="Run the real local Stockpile mobile FastAPI app.")
    parser.add_argument(
        "--host",
        default=os.environ.get("STOCKPILE_MOBILE_DEV_HOST", "127.0.0.1"),
        help="Bind host for the FastAPI server.",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("STOCKPILE_MOBILE_DEV_PORT", "8000")),
        help="Bind port for the FastAPI server.",
    )
    parser.add_argument(
        "--reload",
        action="store_true",
        default=_bool_env("STOCKPILE_MOBILE_DEV_RELOAD"),
        help="Enable uvicorn auto-reload.",
    )
    parser.add_argument(
        "--log-level",
        default=os.environ.get("STOCKPILE_MOBILE_DEV_LOG_LEVEL", "info"),
        help="uvicorn log level.",
    )
    args = parser.parse_args()

    os.chdir(repo_root)
    _configure_pythonpath(repo_root)

    logging.basicConfig(
        level=getattr(logging, str(args.log_level).upper(), logging.INFO),
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )

    service = StockpileMobileAPIService.from_environment()
    runtime_configuration = StockpileMobileJobRuntimeConfiguration.from_environment()

    logger.info("Starting real FastAPI mobile API on http://%s:%s", args.host, args.port)
    logger.info("API base URL: %s", service.api_base_url)
    logger.info("Upload base URL: %s", service.upload_base_url)
    logger.info("Data root: %s", service.root_dir)
    logger.info("Pipeline workspace root: %s", runtime_configuration.workspace_root)
    logger.info("Auth: %s", _auth_summary())
    logger.info(
        "Uploads finalized through /api/mobile/uploads/{uploadId}/content will start in-process pipeline jobs."
    )

    uvicorn.run(
        "stockpile.mobile_api_app:create_app",
        host=args.host,
        port=args.port,
        reload=args.reload,
        factory=True,
        log_level=str(args.log_level).lower(),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
