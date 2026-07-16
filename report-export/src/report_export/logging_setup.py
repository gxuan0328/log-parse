"""Structured stderr logging (design.md §2.3 logging_setup, §3.9.1, §4.3, §4.6).

stdout is reserved exclusively for the pipeline's single JSON summary
(`cli.py`, a later phase); every log record goes to stderr instead. No
field is masked -- the stakeholder has confirmed there is no PII
concern (design.md §4.6), so REQUEST_ID / CLIENT_IP / HOSP_ID are
logged verbatim, never redacted.
"""

from __future__ import annotations

import logging
import os
import sys
from typing import Final, TextIO

__all__ = ["StructuredFormatter", "configure_logging"]

_LOGGER_NAME: Final[str] = "report_export"
_DEFAULT_LEVEL: Final[int] = logging.INFO

#: Debug elevation is env-only, never a CLI flag -- internal use only,
#: intentionally not exposed as a CLI switch (design.md §3.9.1).
_LEVEL_ENV_VAR: Final[str] = "REPORT_EXPORT_LOG_LEVEL"

#: Every attribute a stdlib LogRecord carries at construction time;
#: anything else present on a record arrived via
#: `logger.info(..., extra={...})` and is rendered as additional
#: key=val pairs (design.md §2.3: structured key=val or JSON logging).
_STANDARD_RECORD_FIELDS: Final[frozenset[str]] = frozenset(
    logging.LogRecord(
        name="", level=0, pathname="", lineno=0, msg="", args=(), exc_info=None
    ).__dict__.keys()
)


class StructuredFormatter(logging.Formatter):
    """Renders `TIMESTAMP LEVEL logger=NAME msg=MESSAGE [key=val ...]`.

    Colour is applied only when the destination stream is a TTY and
    `NO_COLOR` is unset -- TTY/NO_COLOR-aware (design.md §2.3); colour
    never changes the underlying field content, only ANSI wrapping, so
    a redirected/piped stderr always yields identical plain text.
    """

    _BASE_FMT: Final[str] = "%(asctime)s %(levelname)-8s logger=%(name)s msg=%(message)s"
    _DATE_FMT: Final[str] = "%Y-%m-%dT%H:%M:%S%z"
    _LEVEL_COLOR: Final[dict[int, str]] = {
        logging.DEBUG: "\x1b[36m",
        logging.INFO: "\x1b[32m",
        logging.WARNING: "\x1b[33m",
        logging.ERROR: "\x1b[31m",
        logging.CRITICAL: "\x1b[35m",
    }
    _RESET: Final[str] = "\x1b[0m"

    def __init__(self, *, use_color: bool) -> None:
        super().__init__(fmt=self._BASE_FMT, datefmt=self._DATE_FMT)
        self._use_color = use_color

    def format(self, record: logging.LogRecord) -> str:
        # Snapshot extras BEFORE super().format(): formatting mutates
        # `record` in place (adds `.message`/`.asctime`), which would
        # otherwise be misidentified as caller-supplied `extra` fields.
        extra_fields = {
            key: value
            for key, value in record.__dict__.items()
            if key not in _STANDARD_RECORD_FIELDS
        }
        rendered = super().format(record)
        if extra_fields:
            extra_text = " ".join(f"{key}={value!r}" for key, value in sorted(extra_fields.items()))
            rendered = f"{rendered} {extra_text}"
        color = self._LEVEL_COLOR.get(record.levelno, "") if self._use_color else ""
        return f"{color}{rendered}{self._RESET}" if color else rendered


def _stream_supports_color(stream: TextIO) -> bool:
    if os.environ.get("NO_COLOR") is not None:
        return False
    isatty = getattr(stream, "isatty", None)
    return bool(isatty and isatty())


def _resolve_level_from_env() -> int:
    """Read `REPORT_EXPORT_LOG_LEVEL` for debug elevation (design.md §3.9.1)."""
    raw = os.environ.get(_LEVEL_ENV_VAR, "").strip().upper()
    if not raw:
        return _DEFAULT_LEVEL
    name_to_level = logging.getLevelNamesMapping()
    if raw in name_to_level:
        return name_to_level[raw]
    if raw.isdigit():
        return int(raw)
    return _DEFAULT_LEVEL


def configure_logging(*, level: int | None = None, stream: TextIO | None = None) -> logging.Logger:
    """Configure the `report_export` logger tree to emit structured
    records to stderr (default) or `stream` if given.

    Idempotent: safe to call more than once -- existing handlers on the
    `report_export` logger are replaced, never stacked. Child loggers
    created the normal way (`logging.getLogger(__name__)` in every
    other module, e.g. `report_export.lookup`) propagate up to this
    logger automatically; propagation from `report_export` to the root
    logger is disabled so records never double up and stdout is never
    touched.
    """
    resolved_level = level if level is not None else _resolve_level_from_env()
    target_stream = stream if stream is not None else sys.stderr

    logger = logging.getLogger(_LOGGER_NAME)
    logger.setLevel(resolved_level)
    logger.propagate = False
    for handler in list(logger.handlers):
        logger.removeHandler(handler)

    handler = logging.StreamHandler(stream=target_stream)
    handler.setFormatter(StructuredFormatter(use_color=_stream_supports_color(target_stream)))
    logger.addHandler(handler)
    return logger
