"""Restore operator-selected trees without following archive or target links.

Directory descriptors bind writes to the reviewed destination even if a site
renames a parent. Archive ownership and executable privilege bits are never
trusted. Site-owned destinations are written with that site's Unix identity.
"""
import argparse
import contextlib
import fnmatch
import math
import os
from pathlib import PurePosixPath
import secrets
import shutil
import stat
import sys
import tarfile
import tempfile


def open_directory(path):
    if not os.path.isabs(path) or os.path.normpath(path) == "/":
        raise ValueError("An existing absolute destination other than / is required")
    current = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in PurePosixPath(path).parts[1:]:
            if part in (".", ".."):
                raise ValueError("Ambiguous directory component")
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=current)
            os.close(current)
            current = next_fd
        return current
    except BaseException:
        os.close(current)
        raise


def identity(fd):
    value = os.fstat(fd)
    return f"{value.st_dev}:{value.st_ino}:{value.st_uid}:{value.st_gid}"


def parts(name):
    value = PurePosixPath(name)
    if value.is_absolute() or ".." in value.parts or "\x00" in name:
        raise ValueError("Unsafe archive path")
    return value.parts


@contextlib.contextmanager
def parent(root, components, create=False):
    current = os.dup(root)
    try:
        for part in components:
            if create:
                try:
                    os.mkdir(part, 0o755, dir_fd=current)
                except FileExistsError:
                    pass
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=current)
            os.close(current)
            current = next_fd
        yield current
    finally:
        os.close(current)


def replace_file(directory, name, stream, mode, mtime=None):
    temporary = ".rclone-restore-" + secrets.token_hex(12)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
    try:
        with os.fdopen(fd, "wb") as output:
            shutil.copyfileobj(stream, output, 1024 * 1024)
            output.flush()
            os.fchmod(output.fileno(), mode & 0o777)
            if mtime is not None:
                os.utime(output.fileno(), (mtime, mtime))
            os.fsync(output.fileno())
        os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
    finally:
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass


def validate(archive):
    count = total = 0
    for member in archive:
        count += 1
        total += member.size
        if count > 500000 or total > 64 * 1024**3 or member.size < 0:
            raise ValueError("Archive exceeds restore limits")
        if not math.isfinite(member.mtime):
            raise ValueError("Invalid archive modification time")
        path = parts(member.name)
        if not path and not member.isdir():
            raise ValueError("Invalid archive root")
        if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
            raise ValueError("Archive contains a device or other special file")
        if member.issym():
            # Preserve internal relative links, but never links out of the tree.
            if PurePosixPath(member.linkname).is_absolute():
                raise ValueError("Absolute archive symlink")
            depth = len(path) - 1
            for part in PurePosixPath(member.linkname).parts:
                depth += -1 if part == ".." else (0 if part == "." else 1)
                if depth < 0:
                    raise ValueError("Archive symlink leaves destination")
        if member.islnk():
            parts(member.linkname)


def restore(root, archive, preserve, clear, database_hash):
    validate(archive)
    sql_members = []
    if database_hash:
        for member in archive.getmembers():
            path = parts(member.name)
            if len(path) == 1 and fnmatch.fnmatchcase(path[0], f"*{database_hash}_*.sql"):
                if not member.isfile():
                    raise ValueError("Database dump must be a regular file")
                sql_members.append(member.name)
        if len(sql_members) != 1:
            raise ValueError("Archive must contain exactly one selected database dump")
    archive.fileobj.seek(0)
    if clear:
        if not shutil.rmtree.avoids_symlink_attacks:
            raise RuntimeError("This Python platform cannot safely clear a tree")
        for name in os.listdir(root):
            if name in preserve:
                continue
            value = os.stat(name, dir_fd=root, follow_symlinks=False)
            if stat.S_ISDIR(value.st_mode):
                shutil.rmtree(name, dir_fd=root)
            else:
                os.unlink(name, dir_fd=root)
    # Reopen after validation; gzip/tar readers retain their own stream state.
    with tarfile.open(fileobj=archive.fileobj, mode="r:*") as content:
        links = []
        for member in content:
            path = parts(member.name)
            if member.name in sql_members:
                # FD 3 is opened by the privileged caller into private storage
                # before the worker drops to the destination site's identity.
                with os.fdopen(os.dup(3), "wb") as output, content.extractfile(member) as incoming:
                    shutil.copyfileobj(incoming, output, 1024 * 1024)
                    output.flush()
                    os.fsync(output.fileno())
                continue
            if not path or path[0] in preserve:
                continue
            if member.isdir():
                with parent(root, path, create=True):
                    pass
            elif member.isfile():
                with parent(root, path[:-1], create=True) as directory:
                    with content.extractfile(member) as incoming:
                        replace_file(directory, path[-1], incoming, member.mode, member.mtime)
            else:
                links.append(member)
        # Links are installed last, so an archive cannot redirect a later write.
        for member in links:
            path = parts(member.name)
            with parent(root, path[:-1], create=True) as directory:
                try:
                    os.unlink(path[-1], dir_fd=directory)
                except FileNotFoundError:
                    pass
                if member.issym():
                    os.symlink(member.linkname, path[-1], dir_fd=directory)
                else:
                    source = parts(member.linkname)
                    with parent(root, source[:-1]) as source_dir:
                        value = os.stat(source[-1], dir_fd=source_dir, follow_symlinks=False)
                        if not stat.S_ISREG(value.st_mode):
                            raise ValueError("Hardlink source is not a regular file")
                        os.link(source[-1], path[-1], src_dir_fd=source_dir, dst_dir_fd=directory, follow_symlinks=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("identity", "archive", "read", "write"))
    parser.add_argument("path")
    parser.add_argument("--identity")
    parser.add_argument("--name")
    parser.add_argument("--clear", action="store_true")
    parser.add_argument("--preserve", action="append", default=[])
    parser.add_argument("--database-hash")
    arguments = parser.parse_args()
    incoming = sys.stdin.buffer
    spool = None
    # A pipe cannot be rewound for the validate-before-clear pass. Spool it to
    # an anonymous private file before dropping privileges, never into a site.
    if arguments.action == "archive" and not incoming.seekable():
        spool = tempfile.TemporaryFile()
        total = 0
        while chunk := incoming.read(1024 * 1024):
            total += len(chunk)
            if total > 64 * 1024**3:
                raise ValueError("Compressed archive exceeds restore limit")
            spool.write(chunk)
        spool.seek(0)
        incoming = spool
    root = open_directory(arguments.path)
    try:
        reviewed = identity(root)
        if arguments.action == "identity":
            print(reviewed)
            return
        if not arguments.identity or reviewed != arguments.identity:
            raise ValueError("Destination changed; review the restore again")
        owner = os.fstat(root)
        if os.geteuid() == 0 and owner.st_uid != 0:
            os.setgroups([])
            os.setgid(owner.st_gid)
            os.setuid(owner.st_uid)
        if arguments.action == "archive":
            with tarfile.open(fileobj=incoming, mode="r:*") as archive:
                restore(root, archive, set(arguments.preserve), arguments.clear, arguments.database_hash)
        else:
            path = parts(arguments.name or "")
            if not path:
                raise ValueError("A relative filename is required")
            with parent(root, path[:-1]) as directory:
                if arguments.action == "read":
                    fd = os.open(path[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
                    with os.fdopen(fd, "rb") as incoming:
                        if not stat.S_ISREG(os.fstat(incoming.fileno()).st_mode):
                            raise ValueError("Not a regular file")
                        shutil.copyfileobj(incoming, sys.stdout.buffer)
                else:
                    replace_file(directory, path[-1], sys.stdin.buffer, 0o600)
    finally:
        os.close(root)
        if spool is not None:
            spool.close()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, tarfile.TarError, RuntimeError) as error:
        sys.exit("Restore refused: " + str(error))
