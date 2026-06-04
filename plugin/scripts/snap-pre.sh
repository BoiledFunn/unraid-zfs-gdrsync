#!/bin/bash
#==============================================================================
# snap-pre.sh — Stops all running Docker containers before ZFS snapshot
#==============================================================================
#
# Called by Sanoid via the pre_snapshot_script option in sanoid.conf.
# All containers are stopped before any snapshot is taken so that databases
# and application state are consistent (no mid-write snapshots).
#
# The list of stopped containers is saved to /tmp/zfs-snap-containers so that
# snap-post.sh can restart exactly the containers that were running.
#
# Usage:
#   This script is called automatically by Sanoid. Do not run manually.
#
# Requirements:
#   - Docker daemon running and accessible
#   - Write access to /tmp
#
#==============================================================================

STATEFILE=/tmp/zfs-snap-containers

# Capture list of running containers (names only, one per line)
docker ps --format '{{.Names}}' > "$STATEFILE"

if [ -s "$STATEFILE" ]; then
    echo "[snap-pre] Stopping $(wc -l < "$STATEFILE") container(s): $(tr '\n' ' ' < "$STATEFILE")"
    xargs docker stop < "$STATEFILE"
    echo "[snap-pre] All containers stopped"
else
    echo "[snap-pre] No running containers to stop"
fi
