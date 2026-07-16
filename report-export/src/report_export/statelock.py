"""File-lock abstraction: `flock`-preferred, `O_CREAT|O_EXCL` sentinel
fallback + stale detection (design.md §2.3 statelock, §4.4, §7.1,
§6-13).

The PRIMARY guarantee is operational serialization (a single operator
or cron schedule never runs two batches concurrently, design.md §4.4)
-- this module is defense-in-depth, not the sole safety net, because
`state_dir` may live on NFSv3/CIFS where `flock()` can be emulated,
degraded, or silently ineffective. Never waits: an unavailable lock is
an immediate, loud `LockBusyError` (exit 4, design.md §4.2), never a
retry/backoff loop.
"""

from __future__ import annotations

import contextlib
import errno
import fcntl
import logging
import os
import socket
import time
from collections.abc import Iterator
from datetime import UTC, datetime
from pathlib import Path
from typing import Final

from report_export.errors import LockBusyError, WriteError

__all__ = ["acquire"]

logger = logging.getLogger(__name__)

_LOCK_FILENAME: Final[str] = ".lock"
_SENTINEL_FILENAME: Final[str] = ".lock.sentinel"

#: A sentinel older than this is presumed to belong to a dead/crashed
#: process even if its PID happens to have been reused by an unrelated
#: process on this host (design.md §4.4 stale detection). This is a
#: weekly batch job; six hours is generously beyond any plausible run.
_STALE_THRESHOLD_SECONDS: Final[float] = 6 * 60 * 60


@contextlib.contextmanager
def acquire(state_dir: Path) -> Iterator[None]:
    """Acquire the exclusive `state_dir/.lock` for the duration of the
    `with` block; always released on exit, normal or exceptional.

    Tries `fcntl.flock(LOCK_EX | LOCK_NB)` first. If this filesystem
    does not honour `flock` at all (`ENOSYS`/`EOPNOTSUPP`/`EINVAL`),
    falls back to an `O_CREAT|O_EXCL` sentinel file containing
    `pid`/`host`/`utc`, with stale-sentinel reclamation (design.md
    §4.4).

    Raises:
        LockBusyError (exit 4): the lock is already held by another
            live process/host, under either strategy. Never waits.
        WriteError (exit 5): an unexpected IO failure while preparing
            or writing the lock itself (not a "busy" condition).
    """
    _ensure_dir(state_dir)
    lock_path = state_dir / _LOCK_FILENAME

    flock_fd = _try_flock(lock_path)
    if flock_fd is not None:
        try:
            yield
        finally:
            _release_flock(flock_fd)
        return

    sentinel_path = state_dir / _SENTINEL_FILENAME
    _acquire_sentinel(sentinel_path)
    try:
        yield
    finally:
        _release_sentinel(sentinel_path)


def _ensure_dir(state_dir: Path) -> None:
    try:
        state_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(state_dir, 0o700)
    except OSError as exc:
        raise WriteError(f"cannot prepare state_dir for locking: {state_dir} ({exc})") from exc


def _try_flock(lock_path: Path) -> int | None:
    """Best-effort `fcntl.flock`.

    Returns an open fd holding the lock, or `None` if this filesystem
    does not support `flock` at all -- the caller then falls back to
    the `O_EXCL` sentinel.

    Raises:
        LockBusyError: `flock` IS honoured here and the lock is held
            by another live process.
        WriteError: any other unexpected IO failure.
    """
    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    except OSError as exc:
        raise WriteError(f"cannot open state lock file: {lock_path} ({exc})") from exc
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        raise LockBusyError(f"state lock busy (flock): {lock_path}") from None
    except OSError as exc:
        os.close(fd)
        if exc.errno in (errno.ENOSYS, errno.EOPNOTSUPP, errno.EINVAL):
            logger.warning(
                "flock unsupported on this filesystem, falling back to O_EXCL sentinel lock",
                extra={"path": str(lock_path), "errno": exc.errno},
            )
            return None
        raise WriteError(f"state lock flock failed: {lock_path} ({exc})") from exc
    os.write(fd, f"{os.getpid()}\n".encode("ascii"))
    return fd


def _release_flock(fd: int) -> None:
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def _acquire_sentinel(sentinel_path: Path) -> None:
    payload = f"pid={os.getpid()} host={socket.gethostname()} utc={_utc_now_iso()}\n".encode()
    for attempt in range(2):  # initial attempt, then one retry after a stale reclaim
        try:
            fd = os.open(sentinel_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            if attempt == 0 and _reclaim_if_stale(sentinel_path):
                continue
            raise LockBusyError(f"state lock busy (sentinel): {sentinel_path}") from None
        except OSError as exc:
            raise WriteError(f"cannot create state lock sentinel: {sentinel_path} ({exc})") from exc
        else:
            try:
                os.write(fd, payload)
            finally:
                os.close(fd)
            return
    # Unreachable: attempt 0 always either returns, retries once (via
    # `continue`), or raises; attempt 1 always either returns or raises
    # (its `attempt == 0` guard is False, so reclaim is never retried
    # again). Kept explicit rather than an implicit fallthrough, so a
    # future change to the loop bound fails loudly instead of silently
    # returning as if the lock had been acquired.
    raise AssertionError(  # pragma: no cover
        "unreachable: _acquire_sentinel loop always returns or raises"
    )


def _release_sentinel(sentinel_path: Path) -> None:
    with contextlib.suppress(FileNotFoundError):
        sentinel_path.unlink()


def _reclaim_if_stale(sentinel_path: Path) -> bool:
    """Return True (having removed the sentinel) iff it is safely
    presumed stale: its owning PID no longer exists on this host, or
    it is older than `_STALE_THRESHOLD_SECONDS` (design.md §4.4).
    """
    try:
        text = sentinel_path.read_text(encoding="utf-8")
        stat_result = sentinel_path.stat()
    except FileNotFoundError:
        return True  # released concurrently between our O_EXCL failure and this check

    pid = _parse_pid(text)
    age_seconds = time.time() - stat_result.st_mtime
    is_stale = (pid is not None and not _pid_alive(pid)) or age_seconds > _STALE_THRESHOLD_SECONDS
    if not is_stale:
        return False

    logger.warning(
        "reclaiming stale state lock sentinel",
        extra={
            "path": str(sentinel_path),
            "sentinel": text.strip(),
            "age_seconds": round(age_seconds),
        },
    )
    with contextlib.suppress(FileNotFoundError):
        sentinel_path.unlink()
    return True


def _parse_pid(sentinel_text: str) -> int | None:
    for token in sentinel_text.split():
        if token.startswith("pid="):
            with contextlib.suppress(ValueError):
                return int(token.removeprefix("pid="))
    return None


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists, just owned by another user
    return True


def _utc_now_iso() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
