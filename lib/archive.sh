#!/bin/bash

# Read live site files under their owner's permissions. Only the private SQL
# dump and completed archive are handled by the privileged backup process.
run_site_reader() {
    local source="$1" uid; shift
    uid=$(stat -c %u -- "$source") || return 1
    if [ "$uid" = "$(id -u)" ]; then
        "$@"
    else
        (cd / && sudo -u "#$uid" -- "$@")
    fi
}

create_site_tar() {
    local output="$1" source="$2" sql="${3:-}"; shift 3
    local plain="$output" snapshot='' uid gid required available result=0
    if ! run_site_reader "$source" tar --warning=no-file-changed --transform 's,^\./,,' "$@" -cf - -C "$source" . > "$plain"; then
        # Preserve the existing changing-files fallback, but run both the copy
        # and its reader as the site owner instead of giving root a live tree.
        required=$(run_site_reader "$source" du -sb -- "$source" | cut -f1) || return 1
        available=$(df -B1 -- "${output%/*}" | awk 'NR==2 {print $4}') || return 1
        [ "$available" -gt "$((required * 3))" ] || return 1
        snapshot=$(mktemp -d /var/tmp/rclone-site-snapshot.XXXXXXXXXX) || return 1
        uid=$(stat -c %u -- "$source") gid=$(stat -c %g -- "$source")
        chown "$uid:$gid" "$snapshot" || return 1
        if ! run_site_reader "$source" cp -a --no-preserve=ownership -- "$source/." "$snapshot/" ||
           ! run_site_reader "$source" tar --transform 's,^\./,,' "$@" -cf - -C "$snapshot" . > "$plain"; then
            result=1
        fi
        rm -rf -- "$snapshot"
        [ "$result" = 0 ] || return 1
    fi
    if [ -n "$sql" ]; then
        tar -rf "$plain" -C "${sql%/*}" -- "${sql##*/}" || return 1
    fi
}

create_site_archive() {
    local output="$1" source="$2" sql="${3:-}"; shift 3
    local plain="${output}.uncompressed"
    create_site_tar "$plain" "$source" "$sql" "$@" || return 1
    if ! gzip -c -- "$plain" > "$output"; then
        rm -f -- "$plain" "$output"
        return 1
    fi
    rm -f -- "$plain"
}

create_incremental_tree() {
    local source="$1" work="$2" extractor="$3"; shift 3
    local required available snapshot_site snapshot_identity
    [ "$(id -u)" = 0 ] && [ -d "$source" ] && [ "$(stat -c %u -- "$source")" != 0 ] || return 1
    [ "$(realpath -e -- "$source")" = "$source" ] && [ "$source" != / ] || return 1
    [ "$(realpath -e -- "$work")" = "$work" ] && [ "$(stat -c %u:%a -- "$work")" = 0:700 ] || return 1
    [ -f "$extractor" ] && [ ! -L "$extractor" ] && [ "$(stat -c %u -- "$extractor")" = 0 ] &&
        [ "$((8#$(stat -c %a -- "$extractor") & 0022))" = 0 ] || return 1
    required=$(run_site_reader "$source" du -sb -- "$source" | cut -f1) || return 1
    available=$(df -B1 -- "$work" | awk 'NR==2 {print $4}') || return 1
    if ! [[ "$required" =~ ^[0-9]+$ ]] || [ "$available" -le "$((required * 3 + 67108864))" ]; then
        echo 'Insufficient private snapshot space. Aborting incremental backup.' >&2
        return 1
    fi
    mkdir -m 700 -- "$work/incremental-tree" || return 1
    snapshot_site="$work/incremental-tree/${source#/}"
    mkdir -p -- "$snapshot_site" || return 1
    create_site_tar "$work/site-files.tar" "$source" '' "$@" || return 1
    snapshot_identity=$(python3 "$extractor" identity "$snapshot_site") || return 1
    python3 "$extractor" archive "$snapshot_site" --identity "$snapshot_identity" < "$work/site-files.tar" || return 1
    rm -f -- "$work/site-files.tar"
}
