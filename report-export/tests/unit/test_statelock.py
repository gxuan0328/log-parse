"""Unit tests for report_export.statelock (design.md §7.1 test_state
flock/O_EXCL bullets, §4.4, §6-13).
"""

from __future__ import annotations

import errno
import fcntl
import os
import time
from pathlib import Path

import pytest

from report_export import statelock
from report_export.errors import LockBusyError, WriteError

# --------------------------------------------------------------------
# flock path (real, on the native filesystem pytest's tmp_path uses --
# NOT the project's own DrvFs-mounted working tree, where chmod/flock
# semantics are unreliable).
# --------------------------------------------------------------------


def test_acquire_and_release_succeeds(tmp_path: Path) -> None:
    with statelock.acquire(tmp_path):
        pass  # must not raise


def test_creates_state_dir_if_missing(tmp_path: Path) -> None:
    state_dir = tmp_path / "does" / "not" / "exist"
    with statelock.acquire(state_dir):
        assert state_dir.is_dir()


def test_state_dir_gets_0700_permissions(tmp_path: Path) -> None:
    state_dir = tmp_path / "state"
    with statelock.acquire(state_dir):
        pass
    assert oct(state_dir.stat().st_mode & 0o777) == "0o700"


def test_lock_file_created_under_state_dir(tmp_path: Path) -> None:
    with statelock.acquire(tmp_path):
        assert (tmp_path / ".lock").exists()


def test_second_acquire_while_first_held_raises_lock_busy(tmp_path: Path) -> None:
    with statelock.acquire(tmp_path), pytest.raises(LockBusyError), statelock.acquire(tmp_path):
        pass  # pragma: no cover -- must never be entered


def test_lock_released_on_normal_exit_allows_reacquire(tmp_path: Path) -> None:
    with statelock.acquire(tmp_path):
        pass
    with statelock.acquire(tmp_path):
        pass  # must not raise -- first lock was fully released


class _BoomError(Exception):
    pass


def test_lock_released_even_when_body_raises(tmp_path: Path) -> None:
    with pytest.raises(_BoomError), statelock.acquire(tmp_path):
        raise _BoomError("simulated failure inside the locked section")

    with statelock.acquire(tmp_path):
        pass  # must not raise -- release happens even on exception


def test_lock_busy_error_names_the_lock_path(tmp_path: Path) -> None:
    with (
        statelock.acquire(tmp_path),
        pytest.raises(LockBusyError, match=r"\.lock"),
        statelock.acquire(tmp_path),
    ):
        pass  # pragma: no cover


# --------------------------------------------------------------------
# O_CREAT|O_EXCL sentinel fallback (design.md §4.4): forced by
# monkeypatching fcntl.flock to simulate an fs that does not honour it.
# --------------------------------------------------------------------


def _make_flock_unsupported(monkeypatch: pytest.MonkeyPatch) -> None:
    def _raise_enosys(fd: int, operation: int) -> None:
        raise OSError(errno.ENOSYS, "Function not implemented")

    monkeypatch.setattr(fcntl, "flock", _raise_enosys)


def test_falls_back_to_sentinel_when_flock_unsupported(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _make_flock_unsupported(monkeypatch)
    with statelock.acquire(tmp_path):
        assert (tmp_path / ".lock.sentinel").exists()


def test_sentinel_content_has_pid_host_utc(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _make_flock_unsupported(monkeypatch)
    with statelock.acquire(tmp_path):
        content = (tmp_path / ".lock.sentinel").read_text(encoding="utf-8")
    assert f"pid={os.getpid()}" in content
    assert "host=" in content
    assert "utc=" in content


def test_sentinel_removed_after_release(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _make_flock_unsupported(monkeypatch)
    with statelock.acquire(tmp_path):
        pass
    assert not (tmp_path / ".lock.sentinel").exists()


def test_sentinel_removed_even_when_body_raises(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _make_flock_unsupported(monkeypatch)

    with pytest.raises(_BoomError), statelock.acquire(tmp_path):
        raise _BoomError

    assert not (tmp_path / ".lock.sentinel").exists()


def test_second_sentinel_acquire_by_live_process_raises_lock_busy(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _make_flock_unsupported(monkeypatch)
    # The sentinel's pid is THIS test process's own pid, which is
    # obviously alive -- must not be reclaimed as stale.
    with statelock.acquire(tmp_path), pytest.raises(LockBusyError), statelock.acquire(tmp_path):
        pass  # pragma: no cover


def test_reacquire_after_sentinel_release_succeeds(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _make_flock_unsupported(monkeypatch)
    with statelock.acquire(tmp_path):
        pass
    with statelock.acquire(tmp_path):
        pass  # must not raise


# --------------------------------------------------------------------
# Stale sentinel reclamation (design.md §4.4)
# --------------------------------------------------------------------


def test_stale_sentinel_with_dead_pid_is_reclaimed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _make_flock_unsupported(monkeypatch)
    tmp_path.mkdir(exist_ok=True)
    sentinel = tmp_path / ".lock.sentinel"
    # A PID essentially guaranteed not to be alive on this host.
    dead_pid = 999_999
    sentinel.write_text(
        f"pid={dead_pid} host=elsewhere utc=2020-01-01T00:00:00Z\n", encoding="utf-8"
    )

    with statelock.acquire(tmp_path):
        pass  # must reclaim the stale sentinel and succeed, not raise LockBusyError


def test_stale_sentinel_by_age_is_reclaimed_even_with_live_pid(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _make_flock_unsupported(monkeypatch)
    tmp_path.mkdir(exist_ok=True)
    sentinel = tmp_path / ".lock.sentinel"
    # Our OWN pid is alive, but the sentinel's mtime is far older than
    # the staleness threshold -- age alone must trigger reclamation.
    sentinel.write_text(f"pid={os.getpid()} host=here utc=2020-01-01T00:00:00Z\n", encoding="utf-8")
    ancient = time.time() - 999_999
    os.utime(sentinel, (ancient, ancient))

    with statelock.acquire(tmp_path):
        pass  # must reclaim by age and succeed


def test_fresh_sentinel_with_live_pid_is_not_reclaimed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _make_flock_unsupported(monkeypatch)
    tmp_path.mkdir(exist_ok=True)
    sentinel = tmp_path / ".lock.sentinel"
    sentinel.write_text(f"pid={os.getpid()} host=here utc=2026-07-15T00:00:00Z\n", encoding="utf-8")

    with pytest.raises(LockBusyError), statelock.acquire(tmp_path):
        pass  # pragma: no cover


def test_sentinel_with_unparsable_pid_falls_back_to_age_check(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _make_flock_unsupported(monkeypatch)
    tmp_path.mkdir(exist_ok=True)
    sentinel = tmp_path / ".lock.sentinel"
    sentinel.write_text("garbage content with no pid=token\n", encoding="utf-8")
    ancient = time.time() - 999_999
    os.utime(sentinel, (ancient, ancient))

    with statelock.acquire(tmp_path):
        pass  # unparsable pid + old age -> reclaimed via the age path


# --------------------------------------------------------------------
# Unexpected IO failures surface as WriteError, not a raw OSError
# --------------------------------------------------------------------


def test_unexpected_flock_oserror_surfaces_as_write_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def _raise_eio(fd: int, operation: int) -> None:
        raise OSError(errno.EIO, "Input/output error")

    monkeypatch.setattr(fcntl, "flock", _raise_eio)
    with pytest.raises(WriteError), statelock.acquire(tmp_path):
        pass  # pragma: no cover


def test_unexpected_sentinel_open_oserror_surfaces_as_write_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _make_flock_unsupported(monkeypatch)
    real_os_open = os.open

    def _raise_eio_for_sentinel(path: str | os.PathLike[str], flags: int, mode: int = 0o777) -> int:
        if str(path).endswith(".lock.sentinel"):
            raise OSError(errno.EIO, "Input/output error")
        return real_os_open(path, flags, mode)

    monkeypatch.setattr(os, "open", _raise_eio_for_sentinel)
    with pytest.raises(WriteError), statelock.acquire(tmp_path):
        pass  # pragma: no cover


def test_unexpected_lock_file_open_oserror_surfaces_as_write_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    real_os_open = os.open

    def _raise_eio_for_lock_file(
        path: str | os.PathLike[str], flags: int, mode: int = 0o777
    ) -> int:
        if str(path).endswith(os.sep + ".lock"):
            raise OSError(errno.EIO, "Input/output error")
        return real_os_open(path, flags, mode)

    monkeypatch.setattr(os, "open", _raise_eio_for_lock_file)
    with pytest.raises(WriteError), statelock.acquire(tmp_path):
        pass  # pragma: no cover


def test_ensure_dir_wraps_unexpected_mkdir_failure_as_write_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def _raise_eio(
        self: Path, *, mode: int = 0o777, parents: bool = False, exist_ok: bool = False
    ) -> None:
        raise OSError(errno.EIO, "Input/output error")

    monkeypatch.setattr(Path, "mkdir", _raise_eio)
    with pytest.raises(WriteError, match="cannot prepare state_dir"), statelock.acquire(tmp_path):
        pass  # pragma: no cover


# --------------------------------------------------------------------
# Race-condition edges in stale-sentinel reclamation (design.md §4.4)
# --------------------------------------------------------------------


def test_sentinel_disappearing_between_exists_check_and_read_is_treated_as_released(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Simulates: our O_EXCL failed because a sentinel existed, but by
    # the time we go to inspect it (for staleness), another process
    # has already released it -- must be treated as "safe to proceed",
    # not as an unexpected failure.
    _make_flock_unsupported(monkeypatch)
    tmp_path.mkdir(exist_ok=True)
    stale_content = "pid=1 host=x utc=2020-01-01T00:00:00Z\n"
    (tmp_path / ".lock.sentinel").write_text(stale_content, encoding="utf-8")

    real_read_text = Path.read_text

    def _vanish_on_read(self: Path, *args: object, **kwargs: object) -> str:
        if self.name == ".lock.sentinel":
            self.unlink()
            raise FileNotFoundError(self)
        return real_read_text(self, *args, **kwargs)  # type: ignore[arg-type]

    monkeypatch.setattr(Path, "read_text", _vanish_on_read)
    with statelock.acquire(tmp_path):
        pass  # must succeed, not raise


def test_pid_owned_by_another_user_is_treated_as_alive(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # os.kill(pid, 0) raising PermissionError means the pid exists but
    # is owned by someone else -- must NOT be reclaimed as stale.
    _make_flock_unsupported(monkeypatch)
    tmp_path.mkdir(exist_ok=True)
    sentinel = tmp_path / ".lock.sentinel"
    sentinel.write_text("pid=1 host=x utc=2026-07-15T00:00:00Z\n", encoding="utf-8")

    def _raise_permission_error(pid: int, sig: int) -> None:
        raise PermissionError

    monkeypatch.setattr(os, "kill", _raise_permission_error)
    with pytest.raises(LockBusyError), statelock.acquire(tmp_path):
        pass  # pragma: no cover
