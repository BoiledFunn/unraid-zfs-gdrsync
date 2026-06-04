#!/bin/bash
#==============================================================================
# uninstall.sh — ZFS-gdrsync Plugin Removal Script
#==============================================================================
#
# Removes the zfs-gdrsync plugin and deployed files.
# Does NOT remove:
#   - /boot/config/zfs-gdrsync-state.json     (backup state — user may want to keep)
#   - /boot/config/rclone/rclone.conf         (GDrive auth — critical, keep it)
#   - /boot/config/rclone/service-account.json (service account key — keep it)
#   - /boot/config/sanoid-gdrsync/            (per-dataset Sanoid configs)
#
# Does NOT remove:
#   - Sanoid plugin itself (it's a separate Unraid plugin)
#   - rclone binary
#
#==============================================================================

set -euo pipefail

PLUGIN_DIR="/boot/config/plugins/zfs-gdrsync"
LOG_PREFIX="zfs-gdrsync-uninstall"

log() { logger -t "$LOG_PREFIX" "$1"; }

log "starting uninstall"

# Stop any containers that might be stopped from a mid-backup state
if [ -f /usr/local/sbin/snap-post.sh ]; then
    /usr/local/sbin/snap-post.sh 2>/dev/null || true
fi

# Remove deployed scripts (these survive OS updates, so must be explicitly removed)
rm -f "/boot/config/zfs-gdrsync/zfs-gdrsync.sh"  2>/dev/null || true
rm -rf "/root/zfs-gdrsync/zfs-gdrsync.sh"         2>/dev/null || true
rm -f /usr/local/sbin/snap-pre.sh   2>/dev/null || true
rm -f /usr/local/sbin/snap-post.sh  2>/dev/null || true

# Remove plugin directory
rm -rf "$PLUGIN_DIR"

# Remove User Scripts entry
rm -rf /boot/config/plugins/user.scripts/scripts/zfs-gdrsync

# Remove go file entries added by install.sh
# Without this, the go file would try to copy files that no longer exist on every boot.
GO_FILE="/boot/config/go"
if [ -f "$GO_FILE" ] && grep -q "zfs-gdrsync: redeploy scripts" "$GO_FILE"; then
    # Remove the block from the marker line to the rclone deploy line
    sed -i '/# --- zfs-gdrsync: redeploy scripts/,/cp \/boot\/config\/rclone\/rclone.conf/d' "$GO_FILE"
    log "removed boot-persistence entries from $GO_FILE"
fi

log "uninstall complete"
echo "zfs-gdrsync uninstall complete.
- State file preserved at /boot/config/zfs-gdrsync-state.json
- rclone config preserved at /boot/config/rclone/rclone.conf
- Sanoid plugin left intact (it is a separate plugin)"