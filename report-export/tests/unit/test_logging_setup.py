"""Unit tests for report_export.logging_setup (design.md §2.3, §3.9.1, §4.3, §4.6)."""

from __future__ import annotations

import io
import logging

import pytest

from report_export.logging_setup import configure_logging


class _FakeTTYStream(io.StringIO):
    """A StringIO that claims to be a TTY, for colour-path tests."""

    def isatty(self) -> bool:
        return True


def test_configure_logging_defaults_to_info_level(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("REPORT_EXPORT_LOG_LEVEL", raising=False)
    logger = configure_logging(stream=io.StringIO())
    assert logger.level == logging.INFO


def test_configure_logging_writes_to_given_stream() -> None:
    buffer = io.StringIO()
    logger = configure_logging(stream=buffer)
    logger.info("hello")
    assert "hello" in buffer.getvalue()


def test_configure_logging_never_touches_root_logger_handlers() -> None:
    root_handlers_before = list(logging.getLogger().handlers)
    configure_logging(stream=io.StringIO())
    assert list(logging.getLogger().handlers) == root_handlers_before


def test_configure_logging_is_idempotent_no_duplicate_handlers() -> None:
    buffer = io.StringIO()
    configure_logging(stream=buffer)
    configure_logging(stream=buffer)
    logger = logging.getLogger("report_export")
    assert len(logger.handlers) == 1


def test_structured_output_contains_key_value_fields() -> None:
    buffer = io.StringIO()
    logger = configure_logging(stream=buffer, level=logging.INFO)
    logger.warning("dup request_id skipped", extra={"request_id": "abc-123", "line_no": 7})
    output = buffer.getvalue()
    assert "request_id='abc-123'" in output
    assert "line_no=7" in output
    assert "msg=dup request_id skipped" in output
    assert "WARNING" in output


def test_no_masking_full_values_present() -> None:
    buffer = io.StringIO()
    logger = configure_logging(stream=buffer)
    extra = {"client_ip": "10.243.129.44", "hosp_id": "0937010019"}
    logger.warning("unmapped hosp id", extra=extra)
    output = buffer.getvalue()
    assert "10.243.129.44" in output
    assert "0937010019" in output
    assert "***" not in output
    assert "REDACTED" not in output.upper()


def test_explicit_level_overrides_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("REPORT_EXPORT_LOG_LEVEL", "DEBUG")
    logger = configure_logging(stream=io.StringIO(), level=logging.ERROR)
    assert logger.level == logging.ERROR


def test_env_var_elevates_level(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("REPORT_EXPORT_LOG_LEVEL", "DEBUG")
    logger = configure_logging(stream=io.StringIO())
    assert logger.level == logging.DEBUG


def test_env_var_accepts_numeric_level(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("REPORT_EXPORT_LOG_LEVEL", "40")  # ERROR
    logger = configure_logging(stream=io.StringIO())
    assert logger.level == logging.ERROR


def test_env_var_unknown_name_falls_back_to_info(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("REPORT_EXPORT_LOG_LEVEL", "NOT_A_LEVEL")
    logger = configure_logging(stream=io.StringIO())
    assert logger.level == logging.INFO


def test_unset_env_defaults_to_info(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("REPORT_EXPORT_LOG_LEVEL", raising=False)
    logger = configure_logging(stream=io.StringIO())
    assert logger.level == logging.INFO


def test_color_applied_when_tty_and_no_color_unset(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("NO_COLOR", raising=False)
    buffer = _FakeTTYStream()
    logger = configure_logging(stream=buffer)
    logger.info("colored")
    assert "\x1b[" in buffer.getvalue()


def test_no_color_env_suppresses_color_even_on_tty(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("NO_COLOR", "1")
    buffer = _FakeTTYStream()
    logger = configure_logging(stream=buffer)
    logger.info("plain")
    assert "\x1b[" not in buffer.getvalue()


def test_non_tty_stream_has_no_color() -> None:
    buffer = io.StringIO()  # StringIO.isatty() is False
    logger = configure_logging(stream=buffer)
    logger.info("plain")
    assert "\x1b[" not in buffer.getvalue()


def test_default_stream_is_stderr_not_stdout(capsys: pytest.CaptureFixture[str]) -> None:
    logger = configure_logging()
    logger.warning("goes to stderr")
    captured = capsys.readouterr()
    assert "goes to stderr" in captured.err
    assert "goes to stderr" not in captured.out
