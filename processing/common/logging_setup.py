"""Central stdlib-logging configuration for processing/ entrypoints.

Every CLI entrypoint calls ``configure_logging()`` once, first thing.
Design:

- One StreamHandler to **stderr** on the ``processing`` package logger.
- **stdout stays reserved for program output** (summary JSON, ids, CLI
  reports) — those remain print() on purpose so they can be piped; do
  not convert them.
- Idempotent: repeated calls in one process don't stack handlers.

LOG_LEVEL env var overrides the default INFO (DEBUG/INFO/WARNING/ERROR).
"""

from __future__ import annotations

import logging
import os
import sys

_FORMAT = "%(asctime)s %(levelname)s %(name)s %(message)s"
_DATEFMT = "%Y-%m-%dT%H:%M:%S%z"

_CONFIGURED = False


def configure_logging() -> None:
    """Attach the stderr handler to the ``processing`` logger (once)."""
    global _CONFIGURED
    if _CONFIGURED:
        return

    level_name = os.environ.get("LOG_LEVEL", "INFO").upper()
    level = getattr(logging, level_name, logging.INFO)

    pkg_logger = logging.getLogger("processing")
    pkg_logger.setLevel(level)
    # Don't double-emit through the root logger if a host process (pytest,
    # a notebook) configured it.
    pkg_logger.propagate = False

    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(logging.Formatter(_FORMAT, datefmt=_DATEFMT))
    pkg_logger.addHandler(handler)

    _CONFIGURED = True
