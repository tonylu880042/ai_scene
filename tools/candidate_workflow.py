"""Safe, engine-independent staging and finalization for managed review candidates."""
import json
import fcntl
import hashlib
import errno
import os
import shutil
import stat
import tempfile
import uuid
import sys
from contextlib import contextmanager
from pathlib import Path

OWNER_NAME = ".managed_candidate.json"
REPORT_NAME = "R17_BUILD_REPORT.json"


@contextmanager
def _destination_lock(dest):
    """Serialize cooperating builders for one destination on this host/filesystem."""
    lock_path = dest.parent / f".{dest.name}.managed-candidate.lock"
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ValueError(f"another managed candidate build is active for: {dest}") from exc
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def _rename_noreplace(source, destination):
    """Atomically rename only when destination is absent (cooperative lock is still required)."""
    import ctypes

    libc = ctypes.CDLL(None, use_errno=True)
    source_b = os.fsencode(source)
    destination_b = os.fsencode(destination)
    if sys.platform == "darwin":
        rename = libc.renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(source_b, destination_b, 0x00000004)  # RENAME_EXCL
    elif sys.platform.startswith("linux"):
        rename = getattr(libc, "renameat2", None)
        if rename is None:
            raise OSError(errno.ENOTSUP, "atomic no-replace rename is unavailable")
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(-100, source_b, -100, destination_b, 1)  # AT_FDCWD, RENAME_NOREPLACE
    else:
        raise OSError(errno.ENOTSUP, "atomic no-replace rename is unavailable")
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), os.fspath(destination))


def _tree_fingerprint(root):
    """Capture directory identity plus an inventory of every entry without following links."""
    if not root.exists():
        return None
    root_stat = root.lstat()
    if not root.is_dir() or root.is_symlink():
        return ("not-directory", root_stat.st_dev, root_stat.st_ino, root_stat.st_mode)
    entries = []
    for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        dirs.sort(); files.sort()
        for name in list(dirs):
            path = current_path / name
            st = path.lstat()
            entries.append((str(path.relative_to(root)), st.st_dev, st.st_ino, st.st_mode,
                            st.st_size, st.st_mtime_ns, st.st_ctime_ns,
                            "directory" if not path.is_symlink() else "symlink"))
            if path.is_symlink():
                dirs.remove(name)
        for name in files:
            path = current_path / name
            st = path.lstat()
            digest = None
            if path.is_file() and not path.is_symlink():
                hasher = hashlib.sha256()
                with path.open("rb") as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        hasher.update(chunk)
                digest = hasher.hexdigest()
            entries.append((str(path.relative_to(root)), st.st_dev, st.st_ino, st.st_mode,
                            st.st_size, st.st_mtime_ns, st.st_ctime_ns, digest))
    return (root_stat.st_dev, root_stat.st_ino, tuple(entries))


def _assert_destination_unchanged(dest, expected):
    if _tree_fingerprint(dest) != expected:
        raise ValueError(f"candidate output changed identity or contents during build: {dest}")


def _path_entry_exists(path):
    """Check whether a directory entry exists without following symlinks."""
    try:
        Path(path).lstat()
    except FileNotFoundError:
        return False
    return True


def _directory_identity(path):
    """Return a directory's stable filesystem identity without following symlinks."""
    try:
        st = Path(path).lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode):
        return None
    return (st.st_dev, st.st_ino)


def _remove_directory_contents(fd):
    """Remove entries through an already-open directory, without resolving its pathname."""
    for entry in os.scandir(fd):
        name = entry.name
        try:
            child_stat = os.stat(name, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        if stat.S_ISDIR(child_stat.st_mode):
            flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
            child_fd = os.open(name, flags, dir_fd=fd)
            try:
                opened_stat = os.fstat(child_fd)
                if (opened_stat.st_dev, opened_stat.st_ino) != (child_stat.st_dev, child_stat.st_ino):
                    raise OSError(errno.EBUSY, "directory entry changed during cleanup", name)
                _remove_directory_contents(child_fd)
            finally:
                os.close(child_fd)
            os.rmdir(name, dir_fd=fd)
        else:
            os.unlink(name, dir_fd=fd)


def _cleanup_owned_stage(path, expected_identity):
    """Clean the recorded directory; return a retained private path if identity changed."""
    path = Path(path).absolute()
    private_name = uuid.uuid4().hex
    parent_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    private_parent = None
    private_fd = None
    try:
        private_parent = Path(tempfile.mkdtemp(prefix=f".{path.parent.name}.stage-cleanup-",
                                               dir=path.parent))
        private_fd = os.open(private_parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            stage_fd = os.open(path.name, flags, dir_fd=parent_fd)
        except OSError as exc:
            if exc.errno in (errno.ENOENT, errno.ENOTDIR, errno.ELOOP):
                return False
            raise
        try:
            st = os.fstat(stage_fd)
            if (st.st_dev, st.st_ino) != expected_identity:
                return False
            _remove_directory_contents(stage_fd)
        finally:
            os.close(stage_fd)
        # Move the emptied stage out of its replaceable public name first. The
        # unpredictable mode-0700 parent is private to this cleanup transaction;
        # verify the moved entry's fd identity before the final rmdir. Thus a
        # public stage-path replacement can never be the directory we remove.
        # The private namespace is trusted against other users, not arbitrary
        # processes running as this same user.
        try:
            os.rename(path.name, private_name, src_dir_fd=parent_fd, dst_dir_fd=private_fd)
        except OSError as exc:
            # The pinned fd cannot make the public name stable. Treat a late
            # disappearance or non-directory substitution as unverified capture.
            if exc.errno in (errno.ENOENT, errno.ENOTDIR, errno.ELOOP):
                return False
            raise
        try:
            moved_fd = os.open(private_name, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) |
                               getattr(os, "O_NOFOLLOW", 0), dir_fd=private_fd)
        except OSError as exc:
            if exc.errno in (errno.ENOENT, errno.ENOTDIR, errno.ELOOP):
                return (str(private_parent / private_name)
                        if _path_entry_exists(private_parent / private_name) else False)
            raise
        try:
            moved_stat = os.fstat(moved_fd)
            if (moved_stat.st_dev, moved_stat.st_ino) != expected_identity:
                return str(private_parent / private_name)
        finally:
            os.close(moved_fd)
        os.rmdir(private_name, dir_fd=private_fd)
        return True
    except BaseException as exc:
        private_path = (str(private_parent.absolute()) if private_parent is not None else
                        str(path.parent / f".{path.parent.name}.stage-cleanup-*"))
        exc.add_note(f"Private cleanup path: {private_path}")
        raise
    finally:
        try:
            if private_fd is not None:
                try:
                    os.close(private_fd)
                except BaseException as exc:
                    exc.add_note(f"Private cleanup path: {private_parent.absolute()}")
                    raise
        finally:
            try:
                try:
                    if private_parent is not None and not _path_entry_exists(private_parent / private_name):
                        os.rmdir(private_parent.name, dir_fd=parent_fd)
                except BaseException as exc:
                    exc.add_note(f"Private cleanup path: {private_parent.absolute()}")
                    raise
            finally:
                try:
                    os.close(parent_fd)
                except BaseException as exc:
                    exc.add_note(f"Cleanup parent path: {path.parent}")
                    raise


def _path_without_symlinks(path):
    raw = Path(path).expanduser()
    if ".." in raw.parts:
        raise ValueError(f"refusing path containing '..': {path}")
    if not raw.is_absolute():
        raw = Path.cwd() / raw
    for part in (raw, *raw.parents):
        if part.is_symlink():
            raise ValueError(f"refusing symlink path component: {part}")
    return raw.resolve(strict=False)


def assert_managed_output_safe(destination, source, package_id):
    """Reject overlapping paths, symlinks and existing directories without an exact owner marker."""
    dest = _path_without_symlinks(destination)
    src = _path_without_symlinks(source)
    if dest == src or src in dest.parents or dest in src.parents:
        raise ValueError("candidate output and source must be disjoint paths")
    if dest.exists():
        if not dest.is_dir():
            raise ValueError(f"candidate output exists and is not a directory: {dest}")
        marker = dest / OWNER_NAME
        if marker.is_symlink() or not marker.is_file():
            raise ValueError(f"refusing to replace unowned candidate output directory: {dest}")
        try:
            owner = json.loads(marker.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            raise ValueError(f"candidate output owner marker is invalid: {dest}") from exc
        if owner != {"package_id": package_id, "output": str(dest)}:
            raise ValueError(f"candidate output owner marker does not match this build: {dest}")
    return dest, src


def finalize_package(package_dir, package_id, report):
    """Write the package id, blocker-aware acceptance state and complete build report."""
    package_dir = Path(package_dir)
    manifest_path = package_dir / "manifest.json"
    acceptance_path = package_dir / "acceptance.json"
    manifest = json.loads(manifest_path.read_text())
    acceptance = json.loads(acceptance_path.read_text())
    errors = report.get("p4_errors", [])
    status = "blocked" if errors else report.get("status", "valid")
    manifest["package_id"] = package_id
    manifest_path.write_text(json.dumps(manifest, indent=1) + "\n")
    acceptance["status"] = "blocked" if status == "blocked" else acceptance.get("status", "accepted")
    if not isinstance(acceptance.get("blockers"), list):
        acceptance["blockers"] = []
    if errors:
        reason = "Expected P4 validation findings; see " + REPORT_NAME
        if not any(blocker.get("reason") == reason for blocker in acceptance["blockers"] if isinstance(blocker, dict)):
            acceptance["blockers"].append({"priority": "P4 validation", "reason": reason})
    acceptance["package_id"] = package_id
    acceptance_path.write_text(json.dumps(acceptance, indent=1) + "\n")
    complete_report = dict(report, package_id=package_id, status=status)
    (package_dir / REPORT_NAME).write_text(json.dumps(complete_report, indent=2) + "\n")
    return complete_report


def build_managed_candidate(destination, source, package_id, build_into):
    """Build beside destination and atomically replace only a previous output owned by this candidate."""
    dest, src = assert_managed_output_safe(destination, source, package_id)
    dest.parent.mkdir(parents=True, exist_ok=True)
    with _destination_lock(dest):
        # Recheck after acquiring the lock: another cooperating build may have completed meanwhile.
        dest, src = assert_managed_output_safe(dest, src, package_id)
        before = _tree_fingerprint(dest)
        stage = Path(tempfile.mkdtemp(prefix=f".{dest.name}.stage-", dir=dest.parent))
        shutil.rmtree(stage)
        stage_identity = None
        backup = dest.parent / f".{dest.name}.backup-{uuid.uuid4().hex}"
        moved = False
        active_error = None
        try:
            try:
                report = build_into(stage)
            except BaseException as exc:
                # A callback that raises may have replaced the stage path before returning;
                # its current identity cannot prove ownership. Preserve any entry and report where.
                if _path_entry_exists(stage):
                    exc.add_note(f"Unverified callback stage preserved at: {stage}")
                raise
            stage_identity = _directory_identity(stage)
            report["previous_output_backup"] = ({
                "status": "retained_unverified", "path": str(backup)
            } if before is not None else {"status": "none", "path": None})
            complete_report = finalize_package(stage, package_id, report)
            (stage / OWNER_NAME).write_text(json.dumps({"package_id": package_id, "output": str(dest)}, indent=2) + "\n")
            _assert_destination_unchanged(dest, before)
            assert_managed_output_safe(dest, src, package_id)
            _assert_destination_unchanged(dest, before)
            if before is not None:
                os.rename(dest, backup)
                moved = True
                # Verify the exact tree after the move before installing the new candidate.
                if _tree_fingerprint(backup) != before:
                    if not dest.exists():
                        _rename_noreplace(backup, dest)
                        moved = False
                    raise ValueError(f"candidate output changed during replacement: {dest}")
            try:
                _rename_noreplace(stage, dest)
            except Exception:
                if moved and not dest.exists():
                    _rename_noreplace(backup, dest)
                    moved = False
                raise
            # Rename transferred stage ownership to the published destination. The old
            # pathname may immediately be reused by another actor (for example, a backup).
            stage = None
            return complete_report
        except BaseException as exc:
            active_error = exc
            raise
        finally:
            if stage is not None and stage_identity is not None and \
                    _directory_identity(stage) == stage_identity:
                try:
                    retained = _cleanup_owned_stage(stage, stage_identity)
                except BaseException as cleanup_error:
                    if active_error is None:
                        raise
                    private_parent = next((note for note in getattr(cleanup_error, "__notes__", [])
                                           if note.startswith("Private cleanup path: ")), None)
                    detail = f"Stage cleanup failed ({type(cleanup_error).__name__}: {cleanup_error})"
                    if private_parent and "stage-cleanup-*" not in private_parent:
                        detail += f"; {private_parent}"
                    else:
                        detail += f"; stage path: {Path(stage).absolute()}"
                    active_error.add_note(detail)
                else:
                    if isinstance(retained, str) and active_error is not None:
                        active_error.add_note(f"Unverified stage entry retained at: {retained}")
