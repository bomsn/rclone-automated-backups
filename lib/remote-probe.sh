#!/usr/bin/env bash

# Verify the exact destination without overwriting an existing customer file.
# The unpredictable object is removed only after its content is read back.
verify_rclone_destination() {
    local remote=$1 directory=$2 temporary name destination expected observed
    temporary=$(umask 077; mktemp -d /var/tmp/rclone-remote-probe.XXXXXXXXXXXX) || return 1
    name=".rclone-probe-$(basename "$temporary").txt"
    destination="${remote}:${directory%/}/${name}"
    if ! head -c 32 /dev/urandom | base64 > "$temporary/probe"; then
        rm -f -- "$temporary/probe"; rmdir -- "$temporary"; return 1
    fi
    expected=$(cat "$temporary/probe")
    if [ -z "$expected" ] || ! rclone copyto --ignore-existing --retries 1 --low-level-retries 1 \
        --contimeout 10s --timeout 30s -- "$temporary/probe" "$destination"; then
        rm -f -- "$temporary/probe"; rmdir -- "$temporary"; return 1
    fi
    if ! observed=$(rclone cat --count 128 --retries 1 --low-level-retries 1 --contimeout 10s --timeout 30s -- "$destination") ||
        [ "$observed" != "$expected" ]; then
        echo 'The remote probe could not be verified. No remote object was deleted.' >&2
        rm -f -- "$temporary/probe"; rmdir -- "$temporary"; return 1
    fi
    rm -f -- "$temporary/probe"
    rmdir -- "$temporary"
    rclone deletefile --retries 1 --low-level-retries 1 --contimeout 10s --timeout 30s -- "$destination"
}
