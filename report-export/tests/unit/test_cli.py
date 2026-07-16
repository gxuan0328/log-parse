"""Unit tests for report_export.cli (design.md §7.1 test_cli, §3.9)."""

from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path

import pytest

from report_export import cli
from report_export.config import Config
from report_export.errors import (
    InputValidationError,
    LockBusyError,
    ReportExportError,
    StateIntegrityError,
    UsageError,
    WriteError,
)
from report_export.errors import (
    ReferenceError as ReportExportReferenceError,
)
from report_export.pipeline import RunSummary


def _summary(**overrides: object) -> RunSummary:
    base: dict[str, object] = {
        "deliverable": "/data/output/2026-07-15_連線紀錄.xlsx",
        "run_date": "2026-07-15",
        "batch_seq": 1,
        "input": "/data/input/week.csv",
        "input_sha256": "abc123",
        "rows_in": 25,
        "normal": 19,
        "dropped_nonnormal": 6,
        "new_records": 19,
        "skipped_cross_state": 0,
        "skipped_intra_batch": 0,
        "unknown_status_skipped": 0,
        "state_total": 19,
        "unique_ips": 11,
        "unmapped_hosp_ids": 0,
    }
    base.update(overrides)
    return RunSummary(**base)  # type: ignore[arg-type]


def _raiser(exc: ReportExportError) -> Callable[[object], RunSummary]:
    def _raise(config: object) -> RunSummary:
        raise exc

    return _raise


def _write_dummy_input(tmp_path: Path) -> Path:
    input_path = tmp_path / "input.csv"
    input_path.write_text("x", encoding="utf-8")
    return input_path


# --------------------------------------------------------------------
# parse_args -- lean CLI shape (design.md §3.9)
# --------------------------------------------------------------------


def test_parse_args_accepts_input_positional() -> None:
    args = cli.parse_args(["input.csv"])
    assert Path("input.csv") == args.INPUT


def test_parse_args_accepts_state_dir_and_out_dir() -> None:
    args = cli.parse_args(
        ["input.csv", "--state-dir", "/custom/state", "--out-dir", "/custom/out"]
    )
    assert args.state_dir == Path("/custom/state")
    assert args.out_dir == Path("/custom/out")


def test_parse_args_state_dir_and_out_dir_default_to_baked_in_paths() -> None:
    args = cli.parse_args(["input.csv"])
    assert args.state_dir == Path("/data/state")
    assert args.out_dir == Path("/data/output")


def test_parse_args_missing_input_raises_usage_error() -> None:
    with pytest.raises(UsageError):
        cli.parse_args([])


def test_parse_args_unknown_flag_raises_usage_error() -> None:
    with pytest.raises(UsageError):
        cli.parse_args(["input.csv", "--bogus-flag"])


def test_parse_args_run_date_is_not_a_recognized_flag() -> None:
    # design.md §3.9.1: run_date is an internal pipeline.run() test seam
    # only, deliberately never a CLI flag.
    with pytest.raises(UsageError):
        cli.parse_args(["input.csv", "--run-date", "2026-07-15"])


def test_parse_args_version_exits_zero() -> None:
    with pytest.raises(SystemExit) as exc_info:
        cli.parse_args(["--version"])
    assert exc_info.value.code == 0


def test_parse_args_help_exits_zero() -> None:
    with pytest.raises(SystemExit) as exc_info:
        cli.parse_args(["--help"])
    assert exc_info.value.code == 0


def test_parse_args_version_prints_version_string(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit):
        cli.parse_args(["--version"])
    out = capsys.readouterr().out
    assert "report-export" in out


# --------------------------------------------------------------------
# main() -- success path (stdout JSON, design.md §3.9.2)
# --------------------------------------------------------------------


def test_main_success_prints_single_json_line_to_stdout(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(cli, "run", lambda config: _summary())
    input_path = _write_dummy_input(tmp_path)

    exit_code = cli.main([str(input_path)])

    assert exit_code == 0
    out = capsys.readouterr().out
    lines = out.strip().splitlines()
    assert len(lines) == 1
    payload = json.loads(lines[0])
    assert payload["state_total"] == 19
    assert payload["unique_ips"] == 11


def test_main_success_json_contains_exactly_the_summary_fields(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(cli, "run", lambda config: _summary())
    input_path = _write_dummy_input(tmp_path)

    cli.main([str(input_path)])

    payload = json.loads(capsys.readouterr().out)
    expected_keys = {
        "deliverable",
        "run_date",
        "batch_seq",
        "input",
        "input_sha256",
        "rows_in",
        "normal",
        "dropped_nonnormal",
        "new_records",
        "skipped_cross_state",
        "skipped_intra_batch",
        "unknown_status_skipped",
        "state_total",
        "unique_ips",
        "unmapped_hosp_ids",
    }
    assert set(payload.keys()) == expected_keys


def test_main_success_returns_exit_code_0(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(cli, "run", lambda config: _summary())
    input_path = _write_dummy_input(tmp_path)

    assert cli.main([str(input_path)]) == 0


def test_main_passes_input_state_dir_out_dir_into_config(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    captured: dict[str, Config] = {}

    def _fake_run(config: Config) -> RunSummary:
        captured["config"] = config
        return _summary()

    monkeypatch.setattr(cli, "run", _fake_run)
    input_path = _write_dummy_input(tmp_path)
    state_dir = tmp_path / "state"
    out_dir = tmp_path / "out"

    cli.main([str(input_path), "--state-dir", str(state_dir), "--out-dir", str(out_dir)])

    config = captured["config"]
    assert config.input_path == input_path.resolve()
    assert config.state_dir == state_dir.resolve()
    assert config.out_dir == out_dir.resolve()


# --------------------------------------------------------------------
# Exit codes map to typed exceptions (design.md §4.2)
# --------------------------------------------------------------------


@pytest.mark.parametrize(
    ("exc", "expected_code"),
    [
        (UsageError("bad usage"), 1),
        (InputValidationError("bad input"), 2),
        (StateIntegrityError("bad state"), 3),
        (LockBusyError("locked"), 4),
        (WriteError("write failed"), 5),
        (ReportExportReferenceError("no reference"), 5),
    ],
)
def test_main_maps_typed_exception_to_exit_code(
    exc: ReportExportError,
    expected_code: int,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(cli, "run", _raiser(exc))
    input_path = _write_dummy_input(tmp_path)

    assert cli.main([str(input_path)]) == expected_code


def test_main_prints_nothing_to_stdout_on_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(cli, "run", _raiser(InputValidationError("bad")))
    input_path = _write_dummy_input(tmp_path)

    cli.main([str(input_path)])

    assert capsys.readouterr().out == ""


def test_main_logs_error_to_stderr(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # NOTE: this deliberately reads the real stderr stream via capsys,
    # not caplog. `main()` calls `configure_logging()`, which sets
    # `report_export.propagate = False` by design (logging_setup.py:
    # "records never double up and stdout is never touched") --
    # caplog's `at_level(logger=...)` only lowers levels, it does not
    # attach its handler directly to the named logger, so it relies on
    # propagation reaching a root-attached handler. That propagation is
    # exactly what `configure_logging()` intentionally cuts off, so
    # caplog cannot observe records emitted through the real pipeline
    # here -- reading the actual configured stderr output is the
    # faithful way to assert this.
    monkeypatch.setattr(cli, "run", _raiser(InputValidationError("boom detail")))
    input_path = _write_dummy_input(tmp_path)

    cli.main([str(input_path)])

    err = capsys.readouterr().err
    assert "boom detail" in err
    assert "ERROR" in err


def test_main_error_log_line_is_structured_key_value(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(cli, "run", _raiser(InputValidationError("boom detail")))
    input_path = _write_dummy_input(tmp_path)

    cli.main([str(input_path)])

    err = capsys.readouterr().err
    assert "logger=report_export.cli" in err
    assert "exit_code=2" in err


def test_unknown_flag_exits_1(tmp_path: Path) -> None:
    input_path = _write_dummy_input(tmp_path)
    assert cli.main([str(input_path), "--unknown-flag"]) == 1


def test_missing_input_exits_1() -> None:
    assert cli.main([]) == 1


def test_bad_input_path_exits_1_via_config_validation(tmp_path: Path) -> None:
    # A NUL byte fails Config's own CWE-22 path normalization
    # (UsageError, exit 1) before pipeline.run() is ever reached.
    assert cli.main(["bad\x00path.csv"]) == 1


# --------------------------------------------------------------------
# `python -m report_export` entry point (design.md §2.3 __main__)
# --------------------------------------------------------------------


def test_main_module_is_importable_and_re_exports_main() -> None:
    import report_export.__main__ as main_module

    assert main_module.main is cli.main


# --------------------------------------------------------------------
# The lean CLI surface never grows extra flags (design.md §3.9)
# --------------------------------------------------------------------


@pytest.mark.parametrize(
    "removed_flag",
    [
        "--run-date",
        "--seed-source",
        "--no-seed",
        "--regenerate-last",
        "--on-duplicate",
        "--output-name",
        "--no-clobber",
        "--dry-run",
        "--lock-timeout",
        "--strict-integrity",
        "--no-backup",
        "--summary-format",
        "--hosp-table",
        "--log-level",
        "--quiet",
    ],
)
def test_flags_removed_by_design_are_rejected(removed_flag: str) -> None:
    # design.md §3.9.1: every one of these was baked in / removed in
    # favor of an internal default -- none survives as a CLI flag.
    with pytest.raises(UsageError):
        cli.parse_args(["input.csv", removed_flag, "x"])
