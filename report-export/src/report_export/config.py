"""Frozen runtime configuration + path validation
(design.md §3.2 config, §5 S0, §11).

`Config` is the single source of truth for the three filesystem
locations the pipeline touches: the INPUT CSV, `state_dir`, and
`out_dir`. Every path is normalized (`~`-expanded, made absolute,
`.`/`..` collapsed) and checked for embedded NUL bytes before the
pipeline ever sees it -- a defence-in-depth mitigation for CWE-22
(path traversal) at the CLI boundary. Existence/writability of the
resolved paths is deliberately NOT checked here: that belongs to the
module that actually touches the filesystem (csv_reader for INPUT,
state.py/xlsx_writer for state_dir/out_dir -- design.md §13-19).

`state_dir`/`out_dir` default to the exact paths the Docker image
mounts (design.md §10.6 Volumes, §10.7 entrypoint example), so the
standard containerized invocation needs no flags at all. Host-direct
execution must override both explicitly via `--state-dir`/`--out-dir`
(design.md §11 CLI table).
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Final

from report_export.errors import UsageError

__all__ = ["DEFAULT_OUT_DIR", "DEFAULT_STATE_DIR", "Config"]

#: Container mount points (design.md §10.6); baked-in CLI defaults so
#: the standard `docker run` invocation (§10.7) never needs
#: `--state-dir`/`--out-dir`. Host-direct runs must override both.
DEFAULT_STATE_DIR: Final[Path] = Path("/data/state")
DEFAULT_OUT_DIR: Final[Path] = Path("/data/output")


def _normalize_path(raw: Path, *, label: str) -> Path:
    """Normalize `raw` to an absolute, symlink/`..`-resolved path.

    Fail-fast (`UsageError`, exit 1) on an embedded NUL byte or any
    resolution failure (symlink loops, unreadable intermediate
    directories) -- defence-in-depth against CWE-22. Never checks
    whether the final path exists (`resolve(strict=False)`): existence
    is a later, module-specific concern.
    """
    text = os.fspath(raw)
    if "\x00" in text:
        raise UsageError(f"{label} must not contain a NUL byte: {raw!r}")
    try:
        return Path(text).expanduser().resolve(strict=False)
    except (OSError, RuntimeError) as exc:
        raise UsageError(f"{label} could not be resolved: {raw!r} ({exc})") from exc


@dataclass(frozen=True, slots=True)
class Config:
    """Runtime configuration for one pipeline run (design.md §5 S0).

    Built directly from the CLI's three arguments (design.md §11):
    `INPUT` (required, positional) and the optional
    `--state-dir`/`--out-dir` overrides. Every other pipeline behaviour
    is baked-in (§11.1) and intentionally has no `Config` field.
    """

    input_path: Path
    state_dir: Path = DEFAULT_STATE_DIR
    out_dir: Path = DEFAULT_OUT_DIR

    def __post_init__(self) -> None:
        object.__setattr__(self, "input_path", _normalize_path(self.input_path, label="INPUT"))
        object.__setattr__(self, "state_dir", _normalize_path(self.state_dir, label="--state-dir"))
        object.__setattr__(self, "out_dir", _normalize_path(self.out_dir, label="--out-dir"))
