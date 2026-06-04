#==============================================================================
# install.sh — ZFS-gdrsync Plugin Install/Update Script
#==============================================================================
#
# Runs on BOTH fresh install AND plugin update from Unraid Plugins UI.
# Fully idempotent — safe to re-run.
#
# What it does:
#   1. Log to syslog
#   2. Check dependencies (rclone, sanoid, syncoid, jq, gzip, docker)
#   3. Deploy scripts to /boot/config/zfs-gdrsync/ (persistent across OS updates)
#   4. Restore rclone config from /boot/config/rclone/rclone.conf if missing
#   5. Deploy Sanoid config to /etc/sanoid/sanoid.conf
#   6. Create User Scripts entry (survives OS updates — lives on /boot/config/)
#   7. Add boot-persistence entries to /boot/config/go
#   8. Log completion
#
#==============================================================================

set -euo pipefail

PLUGIN_DIR="/boot/config/plugins/zfs-gdrsync"
SOURCE_PLUGINDIR="$(dirname "$(readlink -f "$0")")"
LOG_PREFIX="zfs-gdrsync-install"

log() { logger -t "$LOG_PREFIX" "$1"; }

log "starting install"

# ---- 1. Source config ----
# Config file: pool, dataset, retention, rclone remote name, GDrive paths
if [ -f "${SOURCE_PLUGINDIR}/config" ]; then
    . "${SOURCE_PLUGINDIR}/config"
else
    log "ERROR: config file not found at ${SOURCE_PLUGINDIR}/config"
    echo "ERROR: config file not found at ${SOURCE_PLUGINDIR}/config"
    exit 1
fi

# Set defaults if not defined
source_pool="${source_pool:-cache}"
source_dataset="${source_dataset:-appdata}"
rclone_remote="${rclone_remote:-gdrive}"
gdrive_root="${gdrive_root:-zfs-archives}"
notification_type="${notification_type:-all}"
notify_tune="${notify_tune:-no}"

# ---- 2. Check dependencies ----
check_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log "ERROR: $1 not found. Install it before running this plugin."
        echo "ERROR: $1 not found. Please install $1 first."
        exit 1
    fi
}

check_cmd rclone
check_cmd sanoid
check_cmd syncoid
check_cmd jq
check_cmd gzip

# docker is required for snap-pre/snap-post to work
if ! command -v docker >/dev/null 2>&1; then
    log "WARNING: docker not found. Container stop/start hooks will not work."
fi

# ---- 3. Create plugin directory on /boot/config (persists across OS updates) ----
mkdir -p "$PLUGIN_DIR/scripts"
mkdir -p "$PLUGIN_DIR/sanoid"
mkdir -p /boot/config/zfs-gdrsync

log "deploying scripts to $PLUGIN_DIR"

# ---- 3b. Copy user config to persistent storage ----
mkdir -p /boot/config/zfs-gdrsync
cp "${SOURCE_PLUGINDIR}/config" "/boot/config/zfs-gdrsync/config"
log "user config deployed to /boot/config/zfs-gdrsync/config"
chmod +x "/boot/config/zfs-gdrsync/config"

# ---- 3b. Copy script to /root for execute permission ----
# IMPORTANT: /boot is FAT32 and does not support Unix execute bits.
# The script must live on an ext4 filesystem (array disk) to be executable.
# We install to /root/zfs-gdrsync/ as the canonical location, and keep
# /boot/config/zfs-gdrsync/ as a reference copy (not directly executable).
mkdir -p /root/zfs-gdrsync
cp "${SOURCE_PLUGINDIR}/scripts/zfs-gdrsync.sh" "/root/zfs-gdrsync/zfs-gdrsync.sh"
chmod +x "/root/zfs-gdrsync/zfs-gdrsync.sh"
log "main script deployed to /root/zfs-gdrsync/zfs-gdrsync.sh (ext4, executable)"

# Also deploy to /boot/config/zfs-gdrsync/ as a reference copy (not executable on FAT32)
cp "${SOURCE_PLUGINDIR}/scripts/zfs-gdrsync.sh" "/boot/config/zfs-gdrsync/zfs-gdrsync.sh"
log "reference copy deployed to /boot/config/zfs-gdrsync/zfs-gdrsync.sh"

# ---- 5. Deploy snap hook scripts to /usr/local/sbin (persist if possible) ----
# These may not survive OS updates — they're re-deployed on every install/update
cp "${SOURCE_PLUGINDIR}/scripts/snap-pre.sh"  "/usr/local/sbin/snap-pre.sh"
cp "${SOURCE_PLUGINDIR}/scripts/snap-post.sh" "/usr/local/sbin/snap-post.sh"
chmod +x "/usr/local/sbin/snap-pre.sh"
chmod +x "/usr/local/sbin/snap-post.sh"
log "snap hooks deployed to /usr/local/sbin"

# ---- 6. Restore rclone config from /boot/config/rclone/ if missing ----
# rclone config is stored at /boot/config/rclone/rclone.conf (persistent on /boot).
# /root/.config/rclone/rclone.conf is tmpfs — wiped on reboot, restored by go file.
# NOTE: If you use Google Advanced Protection Program, OAuth is permanently blocked.
# Use service account auth instead — see README for setup instructions.
RCLONE_CONF="/root/.config/rclone/rclone.conf"
RCLONE_BOOT_DIR="/boot/config/rclone"
RCLONE_BOOT="${RCLONE_BOOT_DIR}/rclone.conf"

mkdir -p "$RCLONE_BOOT_DIR"

if [ -f "$RCLONE_BOOT" ] && [ ! -s "$RCLONE_CONF" ]; then
    mkdir -p "$(dirname "$RCLONE_CONF")"
    cp "$RCLONE_BOOT" "$RCLONE_CONF"
    log "restored rclone config from $RCLONE_BOOT"
elif [ -s "$RCLONE_CONF" ]; then
    log "rclone config already present at $RCLONE_CONF"
    if [ ! -f "$RCLONE_BOOT" ]; then
        cp "$RCLONE_CONF" "$RCLONE_BOOT"
        log "backed up rclone config to $RCLONE_BOOT"
    fi
else
    echo "========================================================"
    echo " rclone Google Drive setup required."
    echo " Config will be saved to: $RCLONE_BOOT (persistent)"
    echo " NOTE: Google Advanced Protection Program users cannot"
    echo " use OAuth — use service account auth instead."
    echo " See README for service account setup instructions."
    echo "========================================================"
    log "WARNING: rclone config not found at $RCLONE_BOOT — run 'rclone config --config $RCLONE_BOOT' to set up GDrive access."
fi

# ---- 7. Verify rclone remote is accessible ----
if rclone listremotes 2>/dev/null | grep -q "^${rclone_remote}:"; then
    log "rclone remote '$rclone_remote' verified"
else
    log "WARNING: rclone remote '$rclone_remote' not found. Run 'rclone config' to create it."
fi

# ---- 8. Deploy Sanoid config ----
# Backup existing sanoid.conf first
if [ -f /etc/sanoid/sanoid.conf ] && [ ! -f /etc/sanoid/sanoid.conf.bak ]; then
    cp /etc/sanoid/sanoid.conf /etc/sanoid/sanoid.conf.bak
    log "backed up existing /etc/sanoid/sanoid.conf"
fi

# Append our dataset config to the existing sanoid.conf (don't overwrite)
if ! grep -q "^\[${source_pool}/${source_dataset}\]" /etc/sanoid/sanoid.conf 2>/dev/null; then
    cat "${SOURCE_PLUGINDIR}/sanoid/sanoid.conf" >> /etc/sanoid/sanoid.conf
    log "added ${source_pool}/${source_dataset} to /etc/sanoid/sanoid.conf"
else
    log "sanoid config for ${source_pool}/${source_dataset} already exists"
fi

# Also save a copy to the plugin directory
cp "${SOURCE_PLUGINDIR}/sanoid/sanoid.conf" "${PLUGIN_DIR}/sanoid/sanoid.conf"

# ---- 9. Create User Scripts entry ----
USER_SCRIPTS_DIR="/boot/config/plugins/user.scripts/scripts/zfs-gdrsync"
mkdir -p "$USER_SCRIPTS_DIR"

# Main script entry — uses /root/zfs-gdrsync/zfs-gdrsync.sh on ext4 array disk
# (NOT /boot/config/zfs-gdrsync/zfs-gdrsync.sh — FAT32 /boot doesn't support execute bits)
cat > "${USER_SCRIPTS_DIR}/script" << 'SCRIPT_EOF'
#!/bin/bash
bash /root/zfs-gdrsync/zfs-gdrsync.sh >> /var/log/zfs-gdrsync.log 2>&1
SCRIPT_EOF
chmod +x "${USER_SCRIPTS_DIR}/script"

# Cron schedule — runs daily at 00:30 (30 min after midnight, after Sanoid's 23:59 snap)
/bin/bash -c 'cat > "'${USER_SCRIPTS_DIR}'/cron" <<'"'"'EOF'"'"'
30 0 * * *
EOF'

log "user scripts entry created at $USER_SCRIPTS_DIR"

# ---- 10. Add boot-persistence entries to /boot/config/go ----
# /root/ is tmpfs — wiped on every reboot. The go file is Unraid's persistent
# startup script (/boot/config/go), rebuilt from USB on every boot.
# These entries ensure scripts are redeployed automatically after every reboot.
GO_FILE="/boot/config/go"
GO_MARKER="zfs-gdrsync: redeploy scripts"

if ! grep -q "$GO_MARKER" "$GO_FILE" 2>/dev/null; then
    cat >> "$GO_FILE" << 'GO_EOF'

# --- zfs-gdrsync: redeploy scripts to tmpfs on every boot ---
mkdir -p /root/zfs-gdrsync
cp /boot/config/zfs-gdrsync/zfs-gdrsync.sh /root/zfs-gdrsync/zfs-gdrsync.sh
chmod +x /root/zfs-gdrsync/zfs-gdrsync.sh
cp /boot/config/plugins/zfs-gdrsync/scripts/snap-pre.sh /usr/local/sbin/snap-pre.sh 2>/dev/null
cp /boot/config/plugins/zfs-gdrsync/scripts/snap-post.sh /usr/local/sbin/snap-post.sh 2>/dev/null
chmod +x /usr/local/sbin/snap-pre.sh /usr/local/sbin/snap-post.sh 2>/dev/null
touch /var/log/zfs-gdrsync.log
# --- rclone: deploy config to tmpfs on every boot ---
mkdir -p /root/.config/rclone
cp /boot/config/rclone/rclone.conf /root/.config/rclone/rclone.conf 2>/dev/null
GO_EOF
    log "added boot-persistence entries to $GO_FILE"
else
    log "boot-persistence entries already present in $GO_FILE"
fi

# ---- 11. Create log file if missing ----
touch /var/log/zfs-gdrsync.log 2>/dev/null || true

log "install complete"
echo "zfs-gdrsync install complete. Run 'bash /root/zfs-gdrsync/zfs-gdrsync.sh --dry-run' to verify."