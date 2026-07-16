"""Lean argparse CLI: `INPUT` + `--state-dir`/`--out-dir` +
`--version`/`--help` only -- everything else is baked in (design.md
§2.3 cli, §3.9).

The sole `except ReportExportError` boundary in the whole package
(errors.py's own docstring): every other module lets typed exceptions
propagate unmodified; this is where they turn into a process exit code
(design.md §4.2).
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import logging
from pathlib import Path
from typing import Final, NoReturn

from report_export import __version__
from report_export.config import DEFAULT_OUT_DIR, DEFAULT_STATE_DIR, Config
from report_export.errors import ReportExportError, UsageError
from report_export.logging_setup import configure_logging
from report_export.pipeline import run

__all__ = ["main", "parse_args"]

logger = logging.getLogger(__name__)

_PROG: Final[str] = "report-export"


class _FailFastArgumentParser(argparse.ArgumentParser):
    """`error()` raises `UsageError` (exit 1, design.md §4.2) instead
    of argparse's default "print usage to stderr, `sys.exit(2)`" --
    keeps every usage error on the same typed-exception path as every
    other failure mode, and off exit code 2 (reserved for input
    validation, design.md §4.2). `--help`/`--version` are unaffected:
    both exit via `parser.exit()`, a different code path -- standard
    argparse behaviour (design.md §3.9 table: "標準 argparse").
    """

    def error(self, message: str) -> NoReturn:
        raise UsageError(f"{self.prog}: {message}")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse the lean 3-argument CLI surface (design.md §3.9 table):
    positional `INPUT`, optional `--state-dir`/`--out-dir`, standard
    `--version`/`--help`. No other flag exists (design.md §3.9.1: every
    other behaviour is baked in).
    """
    parser = _FailFastArgumentParser(
        prog=_PROG, description="Weekly Excel connection-log report export (design.md)."
    )
    parser.add_argument("INPUT", type=Path, help="raw 14-column input CSV for this batch")
    parser.add_argument(
        "--state-dir",
        type=Path,
        default=DEFAULT_STATE_DIR,
        help=f"canonical state directory (default: {DEFAULT_STATE_DIR})",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=DEFAULT_OUT_DIR,
        help=f"deliverable output directory (default: {DEFAULT_OUT_DIR})",
    )
    parser.add_argument("--version", action="version", version=f"{_PROG} {__version__}")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """CLI entry point (`console_script` + `python -m report_export`).

    Returns the process exit code (design.md §4.2) rather than calling
    `sys.exit()` itself, so it stays directly callable/testable
    in-process; `__main__.py` is the only caller that turns the return
    value into an actual process exit.
    """
    configure_logging()
    try:
        args = parse_args(argv)
        config = Config(input_path=args.INPUT, state_dir=args.state_dir, out_dir=args.out_dir)
        summary = run(config)
    except ReportExportError as exc:
        logger.error(str(exc), extra={"exit_code": exc.exit_code})
        return exc.exit_code
    print(json.dumps(dataclasses.asdict(summary), ensure_ascii=False, sort_keys=True))
    return 0
