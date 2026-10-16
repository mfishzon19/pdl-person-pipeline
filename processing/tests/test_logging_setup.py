"""processing.common.logging_setup — configuration contract.

No AWS, no network (per CLAUDE.md).
"""

from __future__ import annotations

import importlib
import logging

import pytest

import processing.common.logging_setup as ls_mod


@pytest.fixture(autouse=True)
def _fresh_module():
    """Reload so the _CONFIGURED flag and handler state don't leak."""
    pkg_logger = logging.getLogger("processing")
    saved_handlers = pkg_logger.handlers[:]
    saved_propagate = pkg_logger.propagate
    saved_level = pkg_logger.level
    importlib.reload(ls_mod)
    yield
    pkg_logger.handlers = saved_handlers
    pkg_logger.propagate = saved_propagate
    pkg_logger.setLevel(saved_level)


def test_configure_attaches_one_stderr_handler():
    before = len(logging.getLogger("processing").handlers)
    ls_mod.configure_logging()
    after = logging.getLogger("processing").handlers
    assert len(after) == before + 1
    assert isinstance(after[-1], logging.StreamHandler)


def test_configure_is_idempotent():
    ls_mod.configure_logging()
    n = len(logging.getLogger("processing").handlers)
    ls_mod.configure_logging()
    assert len(logging.getLogger("processing").handlers) == n


def test_level_from_env(monkeypatch):
    monkeypatch.setenv("LOG_LEVEL", "DEBUG")
    ls_mod.configure_logging()
    assert logging.getLogger("processing").level == logging.DEBUG


def test_module_loggers_inherit():
    ls_mod.configure_logging()
    child = logging.getLogger("processing.s3_ingester.run")
    assert child.getEffectiveLevel() == logging.INFO
