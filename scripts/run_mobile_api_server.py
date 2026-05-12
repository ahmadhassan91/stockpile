#!/usr/bin/env python3
"""Run the real stockpile mobile API locally."""

from __future__ import annotations

import argparse
import os

import uvicorn


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the real FastAPI mobile API for the native iPhone alpha flow."
    )
    parser.add_argument(
        "--host",
        default=os.environ.get("STOCKPILE_MOBILE_API_HOST", "127.0.0.1"),
        help="Host interface to bind.",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("STOCKPILE_MOBILE_API_PORT", "8000")),
        help="Port to bind.",
    )
    parser.add_argument(
        "--reload",
        action="store_true",
        help="Enable uvicorn autoreload for local development.",
    )
    parser.add_argument(
        "--log-level",
        default=os.environ.get("STOCKPILE_MOBILE_API_LOG_LEVEL", "info"),
        help="Uvicorn log level.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    uvicorn.run(
        "stockpile.mobile_api_app:app",
        host=args.host,
        port=args.port,
        reload=args.reload,
        log_level=args.log_level,
    )


if __name__ == "__main__":
    main()
