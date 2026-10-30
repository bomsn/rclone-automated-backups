#!/usr/bin/env bash

# A root cron job must not live below a directory a website user can replace.
# Walk descriptors rather than validating a pathname and reopening it later.
prepare_operator_directory() {
    python3 - "$1" <<'PY'
import os,stat,sys
if not sys.argv[1]:raise ValueError('Choose a dedicated backup state directory')
path=os.path.abspath(sys.argv[1])
components=path.split('/')[1:]
if not components or components==['']:raise ValueError('Choose a dedicated backup state directory')
current=os.open('/',os.O_RDONLY|os.O_DIRECTORY)
try:
    for index,component in enumerate(components):
        try:os.mkdir(component,0o700,dir_fd=current)
        except FileExistsError:pass
        child=os.open(component,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=current)
        info=os.fstat(child)
        writable=info.st_mode&0o022
        if info.st_uid!=os.geteuid() or (writable and (not info.st_mode&stat.S_ISVTX or index==len(components)-1)):
            os.close(child)
            raise ValueError('Backup state must stay below operator-owned directories; use /var/lib/rclone-automated-backups')
        os.close(current);current=child
finally:os.close(current)
PY
}

validate_operator_file() {
    local path="$1" mode
    [ -f "$path" ] && [ ! -L "$path" ] && [ -O "$path" ] || return 1
    mode=$(stat -c %a -- "$path") || return 1
    (( (8#$mode & 0022) == 0 ))
}

# Retain lock inodes used by older jobs, but never truncate a symlink or an
# attacker-owned file in /tmp. A trusted sticky parent prevents replacement
# between validation and opening the root-owned regular file.
prepare_backup_lock() {
    local path="$1" parent mode
    parent=$(dirname -- "$path")
    if [[ -L "$parent" || ! -d "$parent" || ! -O "$parent" ]]; then
        echo 'Untrusted backup lock directory.' >&2
        return 1
    fi
    mode=$(stat -c %a -- "$parent") || return 1
    if (( (8#$mode & 0022) != 0 && (8#$mode & 01000) == 0 )); then
        echo 'Backup lock directory permits unsafe replacement.' >&2
        return 1
    fi
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        (umask 077; set -o noclobber; : > "$path") 2>/dev/null || true
    fi
    if [[ -L "$path" || ! -f "$path" || ! -O "$path" || $(stat -c %h -- "$path") != 1 ]]; then
        echo 'Backup lock must be an owned regular file with one link.' >&2
        return 1
    fi
    mode=$(stat -c %a -- "$path") || return 1
    if (( (8#$mode & 0022) != 0 )); then
        # Older jobs created this owned inode with their process umask. Tighten
        # it in place so running legacy jobs still share the same flock inode.
        chmod 600 -- "$path" || return 1
    fi
}
