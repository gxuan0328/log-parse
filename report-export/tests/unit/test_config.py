"""Unit tests for report_export.config (design.md §3.2 config, §5 S0, §11, CWE-22)."""

from __future__ import annotations

import dataclasses
import os
from pathlib import Path

import pytest

from report_export.config import DEFAULT_OUT_DIR, DEFAULT_STATE_DIR, Config
from report_export.errors import UsageError


def test_defaults_match_design_doc_container_mount_points() -> None:
    # design.md §10.6 Volumes / §10.7 entrypoint example: the standard
    # `docker run` invocation passes no --state-dir/--out-dir at all.
    assert Path("/data/state") == DEFAULT_STATE_DIR
    assert Path("/data/output") == DEFAULT_OUT_DIR


def test_config_uses_builtin_defaults_when_omitted(tmp_path: Path) -> None:
    input_path = tmp_path / "week.csv"
    config = Config(input_path=input_path)
    assert config.state_dir == DEFAULT_STATE_DIR
    assert config.out_dir == DEFAULT_OUT_DIR


def test_config_normalizes_relative_paths_to_absolute(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.chdir(tmp_path)
    config = Config(
        input_path=Path("week.csv"),
        state_dir=Path("state"),
        out_dir=Path("output"),
    )
    assert config.input_path.is_absolute()
    assert config.state_dir.is_absolute()
    assert config.out_dir.is_absolute()
    assert config.input_path == (tmp_path / "week.csv").resolve()
    assert config.state_dir == (tmp_path / "state").resolve()
    assert config.out_dir == (tmp_path / "output").resolve()


def test_config_collapses_dot_dot_traversal(tmp_path: Path) -> None:
    nested = tmp_path / "a" / "b"
    nested.mkdir(parents=True)
    sneaky = nested / ".." / ".." / "week.csv"
    config = Config(input_path=sneaky)
    assert ".." not in config.input_path.parts
    assert config.input_path == (tmp_path / "week.csv").resolve()


def test_config_rejects_nul_byte_in_input_path() -> None:
    with pytest.raises(UsageError, match="INPUT"):
        Config(input_path=Path("week\x00.csv"))


def test_config_rejects_nul_byte_in_state_dir(tmp_path: Path) -> None:
    with pytest.raises(UsageError, match="--state-dir"):
        Config(input_path=tmp_path / "week.csv", state_dir=Path("bad\x00dir"))


def test_config_rejects_nul_byte_in_out_dir(tmp_path: Path) -> None:
    with pytest.raises(UsageError, match="--out-dir"):
        Config(input_path=tmp_path / "week.csv", out_dir=Path("bad\x00dir"))


def test_config_is_frozen(tmp_path: Path) -> None:
    config = Config(input_path=tmp_path / "week.csv")
    with pytest.raises(dataclasses.FrozenInstanceError):
        config.input_path = tmp_path  # type: ignore[misc]


def test_config_expands_user_home(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))
    config = Config(
        input_path=Path("~/week.csv"),
        state_dir=Path("~/state"),
        out_dir=Path("~/out"),
    )
    assert config.input_path == (tmp_path / "week.csv").resolve()
    assert config.state_dir == (tmp_path / "state").resolve()
    assert config.out_dir == (tmp_path / "out").resolve()


def test_config_does_not_require_paths_to_exist(tmp_path: Path) -> None:
    # Existence/writability checks belong to csv_reader / state.py /
    # xlsx_writer (later phases), not Config (design.md module table).
    missing = tmp_path / "does" / "not" / "exist.csv"
    config = Config(input_path=missing)
    assert config.input_path == missing.resolve()
    assert not config.input_path.exists()


def test_config_wraps_symlink_loop_as_usage_error(tmp_path: Path) -> None:
    # A pathological resolve() failure (RuntimeError: symlink loop) must
    # surface as our typed UsageError, never leak a raw stdlib exception.
    link_a = tmp_path / "a"
    link_b = tmp_path / "b"
    os.symlink(link_b, link_a)
    os.symlink(link_a, link_b)
    with pytest.raises(UsageError, match="INPUT"):
        Config(input_path=link_a)
