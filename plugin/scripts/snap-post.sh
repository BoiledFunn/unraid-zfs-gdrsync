#!/bin/bash
#==============================================================================
# snap-post.sh — Restarts Docker containers after ZFS snapshot is complete
#==============================================================================
#
# Called by Sanoid via the post_snapshot_script option in sanoid.conf.
# Restarts exactly the containers that were stopped by snap-pre.sh, reading
# the list from /tmp/zfs-snap-containers.
#
# Usage:
#   This script is called automatically by Sanoid. Do not run manually.
#
# Requirements:
#   - snap-pre.sh must have run first ( STATEFILE must exist and be non-empty)
#   - Docker daemon running and accessible
#
#==============================================================================

STATEFILE=/tmp/zfs-snap-containers

if [ -s "$STATEFILE" ]; then
    echo "[snap-post] Restarting $(wc -l < "$STATEFILE") container(s): $(tr '\n' ' ' < "$STATEFILE")"
    xargs docker start < "$STATEFILE"
    rm -f "$STATEFILE"
    echo "[snap-post] All containers restarted"
else
    echo "[snap-post] No containers to restart (STATEFILE missing or empty)"
fi
