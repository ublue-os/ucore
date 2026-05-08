#!/usr/bin/bash
# Migration: Fix dangling cockpit.service symlinks from legacy service to Quadlet
# If cockpit.service was enabled, the symlink in /etc might be broken after upgrade.
# Removing the dangling link allows the Quadlet-generated service (in /run) to take over.
for WANT_DIR in /etc/systemd/system/*.target.wants; do
    [ -d "$WANT_DIR" ] || continue
    if [ -L "$WANT_DIR/cockpit.service" ] && [ ! -e "$WANT_DIR/cockpit.service" ]; then
        echo "Removing dangling cockpit.service symlink in $WANT_DIR"
        rm "$WANT_DIR/cockpit.service"
    fi
done
