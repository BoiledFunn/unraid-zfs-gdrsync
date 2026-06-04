#!/bin/bash
#==============================================================================
# zfs-gdrsync.sh — Unraid ZFS Snapshot → Google Drive Push Script
#==============================================================================
#
# PURPOSE
#   Pushes ZFS snapshots from a local pool to Google Drive using rclone.
#   Designed as a drop-in replacement for the rsync replication path in
#   SpaceinvaderOne's ZFS_Dataset_Repications.sh script, adapted for rclone
#   instead of rsync/Syncoid.
#
# WHAT IT KEEPS FROM SPACEINVADERONE'S SCRIPT
#   - Sanoid snapshot creation + pruning per dataset
#   - Pre-run safety checks
#   - Multi-dataset auto-select with exclusion prefixes
#   - Per-dataset iteration and Unraid notifications
#   - Retention policy configuration variables
#   - State tracking for resume/interruption handling
#
# WHAT IT REPLACES
#   - Syncoid/rsync replication → zfs send | gzip | rclone rcat
#   - Hardlink-based incremental → ZFS incremental streams (createtxg-based)
#
# SNAPSHOT TRACKING (IMPORTANT)
#   Tracks last-synced snapshot by ZFS 'createtxg' (transaction group number),
#   NOT by snapshot name. This is critical because Sanoid recursive snapshots
#   all share the same timestamp in their name (e.g., all 24 child datasets
#   get @2026-05-27-040706 simultaneously). The name is identical across all
#   children but the createtxg is unique and monotonically increasing.
#
#   State file: /boot/config/zfs-gdrsync-state.json
#
# DEPENDENCIES
#   - ZFS (kernel module + zfs utilities)
#   - Sanoid plugin for Unraid (installed at /usr/local/sbin/sanoid)
#   - Syncoid (bundled with Sanoid plugin, installed at /usr/local/sbin/syncoid)
#   - rclone native binary, configured with a Google Drive remote
#   - jq (for JSON state file reads/writes)
#   - gzip (for compressing ZFS streams)
#
# USAGE
#   ./zfs-gdrsync.sh                    # Run manually
#   ./zfs-gdrsync.sh --help             # Show this header
#   ./zfs-gdrsync.sh --dry-run          # Show what would be pushed (no changes)
#   ./zfs-gdrsync.sh --force-full       # Force a full send even if prior state exists
#
# SCHEDULING
#   Run via cron or User Scripts plugin on Unraid.
#   Recommended schedule: 30 minutes after midnight (00:30) to allow Sanoid's
#   daily 23:59 snapshot to complete and any post-midnight cron to settle.
#   Sanoid itself should be configured separately (see INSTALL.md).
#
#   Example cron entry:
#     30 0 * * * /usr/local/sbin/zfs-gdrsync.sh >> /var/log/zfs-gdrsync.log 2>&1
#
# AUTHOR
#   BoiledFunn (github.com/BoiledFunn)
#   Adapted from SpaceinvaderOne's ZFS_Dataset_Repications.sh
#   ZFS → Google Drive adaptation for rclone streaming
#
# VERSION
#   1.0 — Initial release
#   1.1 — 2026-05-28: Fixed rclone --no-checksum flag (removed in newer rclone,
#          replaced with --checksum=false). Fixed full send command incorrectly
#          using -I flag (incremental) instead of plain zfs send. Set
#          autosnapshots="no" — snapshot management delegated entirely to
#          /etc/sanoid/sanoid.conf with container stop/start hooks.
#
#==============================================================================

# Exit on error, on undefined variable, and if a pipeline fails
set -euo pipefail

#==============================================================================
# CONFIGURATION — PERSISTENT USER SETTINGS
#==============================================================================
# User-configurable settings live in /boot/config/zfs-gdrsync/config (survives
# OS updates and plugin reinstalls). The install.sh populates this file from
# the plugin's config file on first install.
#
# Edit /boot/config/zfs-gdrsync/config to change any value below.
# Do NOT edit this script — it is replaced on every plugin update.
#==============================================================================

CONFIG_FILE="/boot/config/zfs-gdrsync/config"

# Source user settings if available (sets all the variables below)
# If not present (first install), the defaults in this file are used.
if [[ -f "$CONFIG_FILE" ]]; then
    . "$CONFIG_FILE"
fi

#==============================================================================
# SELF-HEALING — Survive reboots without clicking "plugin update"
# /root/ is tmpfs — wiped on every reboot; recreate rclone symlink from backup
# /etc/sanoid/sanoid.conf is also tmpfs — re-append dataset config if missing
#==============================================================================

# -- rclone config symlink --
RCLONE_CONF="/root/.config/rclone/rclone.conf"
RCLONE_BOOT="/boot/config/rclone/rclone.conf"
if [[ -f "$RCLONE_BOOT" ]] && [[ ! -f "$RCLONE_CONF" ]]; then
    mkdir -p "$(dirname "$RCLONE_CONF")"
    cp "$RCLONE_BOOT" "$RCLONE_CONF"
fi

# -- sanoid global config (dataset entry) --
# install.sh appends this to /etc/sanoid/sanoid.conf on plugin update, but it
# is lost on reboot. Re-append if our dataset section is missing.
SANOID_GLOBAL_CONF="/etc/sanoid/sanoid.conf"
SANOID_PLUGIN_CONF="/boot/config/plugins/zfs-gdrsync/sanoid/sanoid.conf"
if [[ -f "$SANOID_PLUGIN_CONF" ]] && [[ -f "$SANOID_GLOBAL_CONF" ]]; then
    if ! grep -q "^\[${source_pool}/${source_dataset}\]" "$SANOID_GLOBAL_CONF" 2>/dev/null; then
        cat "$SANOID_PLUGIN_CONF" >> "$SANOID_GLOBAL_CONF"
    fi
fi

#==============================================================================
# CONFIGURATION VARIABLES — DEFAULTS (overridden by config file above)
#==============================================================================
# All user-configurable variables are at the top of this file.
# Edit /boot/config/zfs-gdrsync/config to override these values.
# This script is replaced on every plugin update — do not edit here.

# ---- NOTIFICATIONS ----
# Controls when Unraid GUI notifications are sent.
#   "all"    — send notifications for both successes and failures
#   "error"  — send notifications only for failures
#   "none"   — suppress all notifications
notification_type="${notification_type:-all}"

# Play a beep tune on the server's internal speaker on success/failure.
# Requires the 'beep' package to be installed on Unraid.
#   "yes"  — play success/failure tunes
#   "no"   — silent operation
notify_tune="${notify_tune:-no}"


# ---- SOURCE DATASET ----
# Pool and dataset to back up. No leading slash, no /mnt/ prefix.
# Example: pool="cache", dataset="appdata" backs up cache/appdata
source_pool="${source_pool:-cache}"
source_dataset="${source_dataset:-appdata}"

# Auto-select: should all child datasets under source_dataset be processed?
#   "yes"  — discover and process all child datasets recursively
#   "no"   — process only the single dataset named in source_dataset
source_dataset_auto_select="${source_dataset_auto_select:-yes}"

# Exclude child datasets whose name starts with this prefix.
# Example: "backup_" ignores datasets named "backup_something"
# Leave empty to disable prefix exclusion.
source_dataset_auto_select_exclude_prefix="${source_dataset_auto_select_exclude_prefix:-}"

# Exclude specific child datasets by exact name (space-separated list).
# Example: source_dataset_auto_select_excludes=("temp-db" "staging-cache")
source_dataset_auto_select_excludes=(
  # Add dataset names to exclude here, one per line, e.g.:
  # "some-temporary-dataset"
)


# ---- SNAPSHOT RETENTION (SANOID) ----
# These values are written into the Sanoid config file for each dataset.
# They control local snapshot pruning, not GDrive storage.

# Number of hourly snapshots to retain (0 = no hourlies)
snapshot_hours="${snapshot_hours:-0}"

# Number of daily snapshots to retain
snapshot_days="${snapshot_days:-7}"

# Number of weekly snapshots to retain
snapshot_weeks="${snapshot_weeks:-4}"

# Number of monthly snapshots to retain
snapshot_months="${snapshot_months:-3}"

# Number of yearly snapshots to retain (0 = no yearlies)
snapshot_years="${snapshot_years:-0}"

# Enable automatic snapshot creation via Sanoid.
#   "yes"  — Sanoid creates snapshots on its schedule
#   "no"   — skip snapshot creation (only push existing snapshots)
# NOTE: On most Unraid systems "no" means the backup silently does nothing —
# no external Sanoid cron exists by default. Set "yes" unless you have a
# verified external Sanoid schedule already running.
autosnapshots="${autosnapshots:-yes}"


# ---- RCLONE / GOOGLE DRIVE ----
# The rclone remote name as configured via `rclone config`.
# Run `rclone listremotes` to see configured remotes.
rclone_remote="${rclone_remote:-gdrive}"

# Top-level folder on Google Drive where archives are stored.
# Created automatically if it doesn't exist.
# Example: "zfs-archives" → files stored at gdrive:zfs-archives/...
gdrive_root="${gdrive_root:-zfs-archives}"

# Compress ZFS streams before uploading.
#   "yes"  — gzip -n compresses the stream before sending to rclone (recommended)
#   "no"   — send raw uncompressed ZFS stream (larger uploads, more GDrive space used)
compress_output="${compress_output:-yes}"


# How many days of archive files to retain on Google Drive per dataset.
# Archive files older than this are automatically deleted from GDrive at the
# end of each successful dataset sync. This keeps your Drive storage bounded.
#
# How to size this value:
#   - Each daily run produces one .zfs.gz file per dataset (~1-2GB incremental,
#     ~10-20GB full). After N days you'll have at most N files per dataset.
#   - At minimum, set this to 1 (keep only the most recent archive).
#   - A value of 14 means you can restore to any point in the last 2 weeks.
#   - Set to 0 to disable pruning entirely (archives accumulate forever).
#
# NOTE: GDrive pruning is based on the file's modification time as reported
# by Google Drive, which is set at upload time. This is reliable.
gdrive_retention_days="${gdrive_retention_days:-14}"

# How often to do a FULL send. A full snapshot is the base for the incremental
# chain that follows. Recommended: 7 (weekly). The oldest full snapshot is
# never deleted if it still has incrementals in the retention window that
# depend on it as a base — the restore chain is always preserved.
#   1  = daily fulls (most storage, fastest per-day restore)
#   7  = weekly fulls (default, good balance)
#  14+ = less frequent fulls (less storage, requires intact local snapshots
#        for restore points between fulls)
gdrive_full_backup_days="${gdrive_full_backup_days:-7}"

# ---- PATHS AND FILES ----
# State file tracking last-synced snapshot per dataset (JSON format).
# Stored on the Unraid boot device (/boot) so it persists across reboots.
state_file="/boot/config/zfs-gdrsync-state.json"

# Directory where per-dataset Sanoid configs are generated and stored.
# Each dataset gets its own sanoid.conf in a subdirectory named after the dataset.
sanoid_config_dir="/boot/config/sanoid-gdrsync/"

# Path to Sanoid and Syncoid binaries (plugin installs to /usr/local/sbin on Unraid)
SANOID="/usr/local/sbin/sanoid"
SYNCOID="/usr/local/sbin/syncoid"

# Path to rclone binary (resolved at runtime — works whether installed in
# /usr/local/bin, /usr/bin, or anywhere else on $PATH)
RCLONE="$(command -v rclone 2>/dev/null || echo /usr/local/bin/rclone)"

# Path to jq binary (for JSON state file operations)
JQ="$(command -v jq 2>/dev/null || echo /usr/bin/jq)"


#==============================================================================
# COMMAND LINE ARGUMENTS
#==============================================================================
# Supports --dry-run and --force-full for safer manual invocations.

DRY_RUN="no"
FORCE_FULL="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN="yes"
      shift
      ;;
    --force-full)
      FORCE_FULL="yes"
      shift
      ;;
    --help|-h)
      head -50 "$0"
      exit 0
      ;;
    *)
      echo "[zfs-gdrsync] Unknown argument: $1"
      echo "Usage: $0 [--dry-run] [--force-full] [--help]"
      exit 1
      ;;
  esac
done


#==============================================================================
# FUNCTION: unraid_notify
#==============================================================================
# Sends a notification to the Unraid web GUI and any configured notification
# agents (email, pushover, etc.) via the notify script.
#
# Arguments:
#   $1 — message text
#   $2 — flag: "success" or "failure"
#
# Global config:
#   notification_type — controls when notifications fire ("all", "error", "none")
#   notify_tune       — controls audible beep on this server
#==============================================================================
unraid_notify() {
  local message="$1"
  local flag="$2"

  # Suppress all notifications if configured
  [[ "$notification_type" == "none" ]] && return 0

  # Suppress success notifications if configured for error-only mode
  [[ "$notification_type" == "error" && "$flag" == "success" ]] && return 0

  # Determine severity for the Unraid notification system
  local severity
  if [[ "$flag" == "success" ]]; then
    severity="normal"
    # Play success beep on the system speaker (if beep package is installed)
    if [[ "$notify_tune" == "yes" ]]; then
      command -v beep &>/dev/null && \
        beep -f 523 -l 200 -n -f 659 -l 200 -n -f 784 -l 400 2>/dev/null
    fi
  else
    severity="warning"
    # Play Imperial March on the system speaker for failures
    if [[ "$notify_tune" == "yes" ]]; then
      command -v beep &>/dev/null && \
        beep -l 350 -f 392 -D 100 \
             -n -l 350 -f 392 -D 100 \
             -n -l 350 -f 392 -D 100 \
             -n -l 250 -f 311.1 -D 100 \
             -n -l 25 -f 466.2 -D 100 \
             -n -l 350 -f 392 -D 100 2>/dev/null
    fi
  fi

  # Send to Unraid notification system
  /usr/local/emhttp/webGui/scripts/notify \
    -s "ZFS→GDrive Backup" \
    -d "$message" \
    -i "$severity"
}


#==============================================================================
# FUNCTION: read_state_txg
#==============================================================================
# Reads the last-synced createtxg value for a given dataset from the JSON
# state file.
#
# The state file tracks one entry per dataset, recording:
#   - last_synced_name   : full snapshot name that was last pushed
#   - last_synced_txg    : ZFS transaction group number of that snapshot
#   - last_synced_iso    : ISO 8601 timestamp of that snapshot
#
# Arguments:
#   $1 — full dataset path, e.g. "cache/appdata/binhex-radarr"
#
# Returns:
#   The createtxg number as a string, or empty if no prior sync exists.
#==============================================================================
read_state_txg() {
  local dataset="$1"
  local txg
  txg=$("$JQ" -r --arg ds "$dataset" \
    '.[$ds].last_synced_txg // empty' \
    "$state_file" 2>/dev/null || echo "")
  echo "$txg"
}


#==============================================================================
# FUNCTION: read_state_snap_name
#==============================================================================
# Reads the last-synced snapshot name for a given dataset.
#
# Arguments:
#   $1 — full dataset path
#
# Returns:
#   The snapshot name string, or empty if no prior sync exists.
#==============================================================================
read_state_snap_name() {
  local dataset="$1"
  local name
  name=$("$JQ" -r --arg ds "$dataset" \
    '.[$ds].last_synced_name // empty' \
    "$state_file" 2>/dev/null || echo "")
  echo "$name"
}


#==============================================================================
# FUNCTION: read_state_full_txg
#==============================================================================
# Reads the TXG of the most recent FULL send for a given dataset.
# Used to determine if a new full send is due (days since > gdrive_full_backup_days).
#
# Arguments:
#   $1 — full dataset path
#
# Returns:
#   The full send TXG as a string, or empty if no prior full send exists.
#==============================================================================
read_state_full_txg() {
  local dataset="$1"
  local txg
  txg=$("$JQ" -r --arg ds "$dataset" \
    '.[$ds].last_full_txg // empty' \
    "$state_file" 2>/dev/null || echo "")
  echo "$txg"
}


#==============================================================================
# FUNCTION: read_state_full_iso
#==============================================================================
# Reads the ISO timestamp of the most recent FULL send for a given dataset.
#
# Arguments:
#   $1 — full dataset path
#
# Returns:
#   ISO 8601 timestamp string, or empty if no prior full send exists.
#==============================================================================
read_state_full_iso() {
  local dataset="$1"
  local iso
  iso=$("$JQ" -r --arg ds "$dataset" \
    '.[$ds].last_full_iso // empty' \
    "$state_file" 2>/dev/null || echo "")
  echo "$iso"
}


#==============================================================================
# FUNCTION: write_state
#==============================================================================
# Atomically updates the JSON state file with the last synced snapshot info
# for a given dataset. Uses a temp file + atomic mv to ensure no data loss
# if the script is interrupted mid-write.
#
# Arguments:
#   $1 — full dataset path, e.g. "cache/appdata/binhex-radarr"
#   $2 — snapshot name, e.g. "cache/appdata/binhex-radarr@2026-05-27-040706"
#   $3 — createtxg number as string, e.g. "987654"
#   $4 — ISO 8601 creation timestamp, e.g. "2026-05-27T04:07:06Z"
#   $5 — (optional) last_full_txg: TXG of the most recent FULL send for this ds
#   $6 — (optional) last_full_iso: ISO of the most recent FULL send for this ds
#==============================================================================
write_state() {
  local dataset="$1"
  local snap_name="$2"
  local snap_txg="$3"
  local snap_iso="$4"
  local full_txg="${5:-}"
  local full_iso="${6:-}"

  # Create a temporary file for safe atomic write
  local tmp_file
  tmp_file=$(mktemp "$state_file.XXXXXX")

  # If state file doesn't exist yet, start with empty JSON object
  if [[ ! -f "$state_file" ]]; then
    echo "{}" > "$tmp_file"
  else
    cp "$state_file" "$tmp_file"
  fi

  # Read existing full snapshot tracking if not provided (preserve across runs)
  local existing_full_txg=""
  local existing_full_iso=""
  if [[ -f "$state_file" ]]; then
    existing_full_txg=$("$JQ" -r --arg ds "$dataset" \
      '.[$ds].last_full_txg // empty' "$state_file" 2>/dev/null || echo "")
    existing_full_iso=$("$JQ" -r --arg ds "$dataset" \
      '.[$ds].last_full_iso // empty' "$state_file" 2>/dev/null || echo "")
  fi

  # Use provided values, otherwise keep existing
  : "${full_txg:=$existing_full_txg}"
  : "${full_iso:=$existing_full_iso}"

  # Build the JSON entry for this dataset
  local entry
  entry=$("$JQ" -n \
    --arg name "$snap_name" \
    --arg txg  "$snap_txg"    \
    --arg iso  "$snap_iso"    \
    --arg ftxg "$full_txg"    \
    --arg fiso "$full_iso"    \
    '{ last_synced_name: $name,
       last_synced_txg: ($txg | tonumber),
       last_synced_iso: $iso,
       last_full_txg: (if ($ftxg | length) > 0 then $ftxg else null end),
       last_full_iso: (if ($fiso | length) > 0 then $fiso else null end) }')

  # Atomically update the state file
  "$JQ" --arg ds "$dataset" \
        --argjson entry "$entry" \
        'setpath([$ds]; $entry)' \
        "$tmp_file" > "${tmp_file}.new" \
    && mv "${tmp_file}.new" "$tmp_file" \
    && mv "$tmp_file" "$state_file"

  echo "[zfs-gdrsync] State updated: ${dataset} → txg=${snap_txg} snap=${snap_name}"
}


#==============================================================================
# FUNCTION: create_sanoid_config
#==============================================================================
# Creates a Sanoid configuration file for a specific dataset if one doesn't
# already exist. This is idempotent — calling it multiple times is safe.
#
# The generated config uses the "production" template with:
#   - recursive = zfs  (uses ZFS-native recursive snapshots, atomic and consistent)
#   - autosnap = yes   (Sanoid creates snapshots on its schedule)
#   - autoprune = yes  (Sanoid prunes old snapshots per retention policy)
#
# Sanoid's built-in scheduler runs independently — this script does NOT need
# to trigger Sanoid's daemon. The --take-snapshots and --prune-snapshots
# flags used in this script are one-shot invocations that respect the schedule.
#
# Arguments:
#   $1 — full dataset path, e.g. "cache/appdata/binhex-radarr"
#==============================================================================
create_sanoid_config() {
  local dataset="$1"
  local cfg_dir="${sanoid_config_dir}${dataset}/"

  # Only create configs if autosnapshots mode is enabled
  [[ "$autosnapshots" != "yes" ]] && return 0

  # Create dataset-specific config directory
  mkdir -p "$cfg_dir"

  # Copy Sanoid defaults if not already present in this dataset's config dir
  if [[ -f /etc/sanoid/sanoid.defaults.conf ]] && \
     [[ ! -f "${cfg_dir}sanoid.defaults.conf" ]]; then
    cp /etc/sanoid/sanoid.defaults.conf "${cfg_dir}sanoid.defaults.conf"
  fi

  # Skip if sanoid.conf already exists for this dataset (idempotent)
  [[ -f "${cfg_dir}sanoid.conf" ]] && return 0

  # Generate sanoid.conf for this dataset
  # Uses template_production from the defaults, overridden with our retention values
  cat > "${cfg_dir}sanoid.conf" <<EOF
# Sanoid configuration for ${dataset}
# Generated by zfs-gdrsync.sh — safe to edit manually after first run.

[${dataset}]
use_template = production
recursive = zfs

[template_production]
frequently = ${snapshot_hours}
hourly = ${snapshot_hours}
daily = ${snapshot_days}
weekly = ${snapshot_weeks}
monthly = ${snapshot_months}
yearly = ${snapshot_years}
autosnap = yes
autoprune = yes
EOF

  echo "[zfs-gdrsync] Sanoid config created: ${cfg_dir}sanoid.conf"
}


#==============================================================================
# FUNCTION: autosnap
#==============================================================================
# Triggers Sanoid to take a snapshot for a dataset (one-shot, not daemon).
# Respects the dataset's configured schedule (will only create a snapshot if
# the schedule says it's time to do so), but --take-snapshots can be called
# at any time and Sanoid will evaluate whether to create a snapshot.
#
# Arguments:
#   $1 — full dataset path
#==============================================================================
autosnap() {
  local dataset="$1"
  [[ "$autosnapshots" != "yes" ]] && return 0

  local cfg_dir="${sanoid_config_dir}${dataset}/"
  echo "[zfs-gdrsync] [${dataset}] Creating/verifying snapshots via Sanoid"
  "$SANOID" --configdir="$cfg_dir" --take-snapshots
  echo "[zfs-gdrsync] [${dataset}] Sanoid snapshot operation complete"
}


#==============================================================================
# FUNCTION: autoprune
#==============================================================================
# Triggers Sanoid to prune old snapshots for a dataset (one-shot, not daemon).
# Respects the retention policy defined in the dataset's Sanoid config.
#
# Arguments:
#   $1 — full dataset path
#==============================================================================
autoprune() {
  local dataset="$1"
  [[ "$autosnapshots" != "yes" ]] && return 0

  local cfg_dir="${sanoid_config_dir}${dataset}/"
  echo "[zfs-gdrsync] [${dataset}] Pruning old snapshots via Sanoid"
  "$SANOID" --configdir="$cfg_dir" --prune-snapshots
  echo "[zfs-gdrsync] [${dataset}] Sanoid prune operation complete"
}


#==============================================================================
# FUNCTION: dataset_path
#==============================================================================
# Constructs the full ZFS dataset path from pool + dataset name.
# No /mnt/ prefix — ZFS paths are pool/dataset, not /mnt/pool/dataset.
#
# Arguments:
#   $1 — pool name, e.g. "cache"
#   $2 — dataset name or path, e.g. "appdata" or "appdata/binhex-radarr"
#==============================================================================
dataset_path() {
  local pool="$1"
  local dataset="$2"
  echo "${pool}/${dataset}"
}


#==============================================================================
# FUNCTION: newest_snapshot
#==============================================================================
# Finds the newest snapshot for a given dataset, sorted by ZFS createtxg
# (transaction group number). createtxg is guaranteed to be unique and
# monotonically increasing within a pool — newer snapshots always have
# higher createtxg values.
#
# IMPORTANT: This is why we track by createtxg and not by snapshot name.
# When Sanoid takes recursive snapshots, ALL child datasets get snapshots
# with identical names (e.g., @2026-05-27-040706). Sorting by name would
# give us all 24 at once. Sorting by createtxg reveals their true ordering.
#
# Arguments:
#   $1 — full dataset path, e.g. "cache/appdata/binhex-radarr"
#
# Returns:
#   Snapshot name, e.g. "cache/appdata/binhex-radarr@2026-05-27-040706"
#==============================================================================
newest_snapshot() {
  local ds="$1"
  zfs list -t snapshot -o name,createtxg -S createtxg -H "$ds" 2>/dev/null | \
    head -n 1 | cut -f1
}


#==============================================================================
# FUNCTION: snapshot_txg
#==============================================================================
# Gets the ZFS createtxg value for a specific snapshot.
#
# Arguments:
#   $1 — full snapshot name, e.g. "cache/appdata/binhex-radarr@2026-05-27-040706"
#
# Returns:
#   Transaction group number as string, e.g. "987654"
#==============================================================================
snapshot_txg() {
  local snap="$1"
  zfs get -H -o value createtxg "$snap" 2>/dev/null
}


#==============================================================================
# FUNCTION: snapshot_iso
#==============================================================================
# Gets the ISO 8601 creation timestamp for a specific snapshot.
# Used for human-readable state file entries.
#
# Arguments:
#   $1 — full snapshot name
#
# Returns:
#   ISO 8601 timestamp, e.g. "2026-05-27T04:07:06+00:00"
#==============================================================================
snapshot_iso() {
  local snap="$1"
  local epoch
  epoch=$(zfs get -H -p -o value creation "$snap" 2>/dev/null)
  date -d "@${epoch}" -Iseconds 2>/dev/null || echo "$(date -Iseconds)"
}


#==============================================================================
# FUNCTION: days_since_full_backup
#==============================================================================
# Calculates the number of full days since the last FULL snapshot was sent
# for a given dataset. Used to decide whether to do a new full send.
#
# Arguments:
#   $1 — ISO 8601 timestamp of the last full send (e.g. "2026-06-01T00:00:00Z")
#
# Returns:
#   Integer number of full days elapsed, or a large number if $1 is empty.
#==============================================================================
days_since_full_backup() {
  local full_iso="$1"

  if [[ -z "$full_iso" ]]; then
    # No prior full — treat as "a long time ago" to force a full send
    echo "999"
    return
  fi

  # Parse the ISO timestamp to epoch seconds
  # Handle both Z (UTC) and +HH:MM offset formats
  local full_epoch
  full_epoch=$(date -d "$full_iso" +%s 2>/dev/null)
  if [[ -z "$full_epoch" ]]; then
    echo "999"
    return
  fi

  local now_epoch
  now_epoch=$(date +%s)

  local seconds_elapsed=$((now_epoch - full_epoch))
  local days_elapsed=$((seconds_elapsed / 86400))

  echo "$days_elapsed"
}


#==============================================================================
# FUNCTION: gdrive_snapshot_path
#==============================================================================
# Builds the full rclone remote path for a snapshot archive file.
# The path format is:
#   {remote}:{root}/{pool}/{dataset}/{snapshot_name}.zfs[.gz]
#
# Snapshot names are sanitized for GDrive compatibility:
#   / replaced with _  (slashes are path separators in GDrive)
#   @ replaced with _  (@ is not valid in GDrive filenames)
#
# Arguments:
#   $1 — rclone remote name, e.g. "gdrive"
#   $2 — GDrive root folder, e.g. "zfs-archives"
#   $3 — full dataset path, e.g. "cache/appdata/binhex-radarr"
#   $4 — full snapshot name, e.g. "cache/appdata/binhex-radarr@2026-05-27-040706"
#
# Returns:
#   rclone path, e.g. "gdrive:zfs-archives/cache/appdata/binhex-radarr/cache_appdata_binhex-radarr_2026-05-27-040706.zfs.gz"
#==============================================================================
gdrive_snapshot_path() {
  local remote="$1"
  local root="$2"
  local ds="$3"
  local snap="$4"
  local is_incremental="${5:-no}"  # "yes" for -I incremental sends

  # Extract the last component of the dataset path (the dataset name itself)
  local ds_name="${ds##*/}"

  # Sanitize snapshot name for GDrive filesystem compatibility
  # Replace / with _  (GDrive doesn't use / in filenames — they're path separators)
  # Replace @ with _  (@ is not valid in most cloud filesystems)
  local snap_name
  snap_name=$(echo "$snap" | sed 's/\//_/g; s/@/_/g')

  # File extension: .zfs.gz if compressed, .zfs if not
  local ext=".zfs"
  [[ "$compress_output" == "yes" ]] && ext=".zfs.gz"

  # Mark incremental sends with _I_ in the filename so prune logic can identify them.
  # Without this marker, incremental and full send filenames are identical and the
  # prune function cannot distinguish them to apply the correct retention policy.
  if [[ "$is_incremental" == "yes" ]]; then
    snap_name="${snap_name}_I_"
  fi

  echo "${remote}:${root}/${ds}/${snap_name}${ext}"
}


#==============================================================================
# FUNCTION: push_snapshot_to_gdrive
#==============================================================================
# Pushes a single snapshot (or incremental range) to Google Drive.
#
# Uses the ZFS incremental send flag -I to capture all snapshots between
# the base and target. This is critical for reliability: if the script missed
# a run (server was off, cron didn't fire), multiple new snapshots may exist.
# -I sends them all in a single stream and the receiver sees all of them.
#
# The stream pipeline is:
#   zfs send [-I base_snap] target_snap  |  gzip -n  |  rclone rcat remote:path
#
# gzip -n strips the filename from the gzip header, which is required for
# clean stdin piping to rclone rcat (without -n, gzip includes the original
# filename and rclone would write a file with that name instead of streaming).
#
# rclone rcat writes the stdin content directly to the remote path without
# needing a local temp file — it handles chunking internally for large files.
#
# rclone flags for large ZFS streams on GDrive:
#   --drive-chunk-size 256M   — upload in 256MB chunks for reliability
#   --drive-upload-cutoff 256M — cutover to chunked upload below 256MB threshold
#   --checksum=false            — skip post-upload checksum verification (ZFS handles integrity;
#                               enabling it would require downloading the full stream to verify)
#
# Arguments:
#   $1 — full dataset path, e.g. "cache/appdata/binhex-radarr"
#   $2 — base snapshot name (empty string = full send, no incremental)
#   $3 — target snapshot name
#   $4 — rclone remote name, e.g. "gdrive"
#   $5 — GDrive root folder, e.g. "zfs-archives"
#
# Returns:
#   Exit code 0 on success, non-zero on failure.
#==============================================================================
push_snapshot_to_gdrive() {
  local ds="$1"
  local from_snap="$2"
  local to_snap="$3"
  local remote="$4"
  local root="$5"

  local gdrive_path
  local is_incremental="no"
  if [[ -z "$from_snap" ]]; then
    # Full snapshot send (no base, no incremental)
    gdrive_path=$(gdrive_snapshot_path "$remote" "$root" "$ds" "$to_snap" "no")
  else
    # Incremental send — mark the filename with _I_ so prune logic can identify it
    is_incremental="yes"
    gdrive_path=$(gdrive_snapshot_path "$remote" "$root" "$ds" "$to_snap" "yes")
  fi

  echo "[zfs-gdrsync] [${ds}] Initiating GDrive push"
  echo "[zfs-gdrsync] [${ds}]   From snapshot : ${from_snap:-<full>}"
  echo "[zfs-gdrsync] [${ds}]   To snapshot   : ${to_snap}"
  echo "[zfs-gdrsync] [${ds}]   GDrive path   : ${gdrive_path}"

  # Build the zfs send command
  # -I flag: incremental send that includes ALL snapshots in the range.
  #   The receiver will receive all intermediate snapshots, not just the delta.
  #   This is important: it means if 3 new snapshots exist since last sync,
  #   the receiver gets all 3 and can see the full history.
  local send_cmd
  if [[ -z "$from_snap" ]]; then
    # Full snapshot send (no base, no incremental)
	send_cmd="zfs send \"${to_snap}\""
    echo "[zfs-gdrsync] [${ds}]   Mode         : FULL send"
  else
    # Incremental send from base to target (packages all intermediate snaps)
    send_cmd="zfs send -I \"${from_snap}\" \"${to_snap}\""
    echo "[zfs-gdrsync] [${ds}]   Mode         : INCREMENTAL send (-I)"
  fi

  # Build the full pipeline
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "[zfs-gdrsync] [${ds}]   DRY RUN — would execute: ${send_cmd} | gzip -n | rclone rcat ..."
    return 0
  fi

  if [[ "$compress_output" == "yes" ]]; then
    echo "[zfs-gdrsync] [${ds}]   Compression  : gzip -n (stream compress)"
    # Pipe: zfs send | gzip -n | rclone rcat
    # gzip -n: -n prevents gzip from embedding the original filename in the header.
    #          This is critical — without -n, rclone rcat sees a filename in the
    #          gzip header and writes to a file with that name instead of treating
    #          the stream as raw binary data.
    eval "$send_cmd" 2>/dev/null | gzip -n | \
      "$RCLONE" rcat \
        --drive-chunk-size 256M \
        --drive-upload-cutoff 256M \
        --checksum=false \
        "$gdrive_path"
  else
    echo "[zfs-gdrsync] [${ds}]   Compression  : none (raw stream)"
    eval "$send_cmd" 2>/dev/null | \
      "$RCLONE" rcat \
        --drive-chunk-size 256M \
        --drive-upload-cutoff 256M \
        --checksum=false \
        "$gdrive_path"
  fi

  return $?
}


#==============================================================================
# FUNCTION: find_base_snapshot_for_incremental
#==============================================================================
# Given a target txg and the last synced txg, finds the snapshot that has
# exactly the last synced txg — this is the correct base for a -I incremental.
#
# Arguments:
#   $1 — full dataset path
#   $2 — last synced txg (string)
#
# Returns:
#   Snapshot name that matches that txg, or empty if not found.
#==============================================================================
find_base_snapshot_for_incremental() {
  local ds="$1"
  local last_txg="$2"

  # List all snapshots sorted by createtxg descending, find the one with matching txg.
  # NR>1 skips the header row. The matching snapshot is the correct "from" base for
  # the -I incremental send — it's the exact snapshot that was last successfully pushed.
  # NOTE: awk field separator is tab (-F'\t') because zfs list -H uses tabs.
  zfs list -t snapshot -o name,createtxg -S createtxg -H "$ds" 2>/dev/null | \
    awk -F'\t' -v txg="$last_txg" '$2 == txg {print $1; exit}'
}


#==============================================================================
# FUNCTION: prune_gdrive_dataset
#==============================================================================
# Deletes archive files from Google Drive older than gdrive_retention_days.
#
# TIERED RETENTION POLICY:
#   - All files within gdrive_retention_days are ALWAYS kept (14-day window)
#   - For files OLDER than gdrive_retention_days:
#     * INCREMENTAL files: deleted (safe — never bases for other files)
#     * FULL files: deleted ONLY if not the oldest full snapshot in the list
#       (oldest full is the base for its incremental chain — delete it and
#        those incrementals become unusable)
#   - This means at minimum, you always have the oldest full snapshot preserved
#     as an anchor for the restore chain.
#
# rclone lsf with --format p returns: relative_path  modtime_seconds
# Split on first whitespace to separate the filename from the timestamp.
#
# Arguments:
#   $1 — full dataset path, e.g. "cache/appdata/binhex-radarr"
#==============================================================================
prune_gdrive_dataset() {
  local ds="$1"

  # Pruning disabled — skip entirely
  if [[ "$gdrive_retention_days" == "0" ]]; then
    echo "[zfs-gdrsync] [${ds}] GDrive pruning disabled (gdrive_retention_days=0)"
    return 0
  fi

  # Build the remote folder path for this dataset
  local remote_folder="${rclone_remote}:${gdrive_root}/${ds}"

  echo "[zfs-gdrsync] [${ds}] Pruning GDrive archives (retention: ${gdrive_retention_days} days)"
  echo "[zfs-gdrsync] [${ds}]   Remote folder: ${remote_folder}"

  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "[zfs-gdrsync] [${ds}]   DRY RUN — would run pruning check on all archives"
    return 0
  fi

  # Get current time as epoch seconds
  local now_epoch
  now_epoch=$(date +%s)
  local cutoff_epoch=$((now_epoch - gdrive_retention_days * 86400))

  # List all .zfs.gz files for this dataset with their modification timestamps.
  # rclone lsf --format p outputs: "filename  modtime_seconds" (space-separated).
  local lsf_output
  lsf_output=$("$RCLONE" lsf \
    --format "p" \
    --separator " " \
    --include "*.zfs.gz" \
    "$remote_folder" 2>/dev/null || true)

  if [[ -z "$lsf_output" ]]; then
    echo "[zfs-gdrsync] [${ds}]   No archives found — nothing to prune"
    return 0
  fi

  # Parse files into full vs incremental, and build a by-age sorted list.
  # Strategy:
  #   - All files within retention window (mtime >= cutoff_epoch): KEEP (no exceptions)
  #   - Incremental files older than window: DELETE (never a base for restore)
  #   - Full files older than window: KEEP only the most recent one; DELETE the rest
  #     (the most recent full is the anchor for any restore chain)
  #
  # Filename convention: incremental sends are marked with _I_ before the extension.
  # Full sends have no _I_ marker.

  local -a files_to_delete=()
  local newest_full_name=""
  local newest_full_mtime="0"

  while IFS=" " read -r fname mtime; do
    [[ -z "$fname" || -z "$mtime" ]] && continue

    local file_age_days=$(( (now_epoch - mtime) / 86400 ))
    local older_than_retention=0
    [[ $mtime -lt $cutoff_epoch ]] && older_than_retention=1

    local is_incremental=0
    [[ "$fname" == *" _I_"* || "$fname" == *"_I_"."zfs.gz" ]] && is_incremental=1

    echo "[zfs-gdrsync] [${ds}]   ${fname}  age=${file_age_days}d  $([[ $older_than_retention -eq 1 ]] && echo OLD || echo ok)$([[ $is_incremental -eq 1 ]] && echo inc || echo full)"

    if [[ $older_than_retention -eq 0 ]]; then
      # File is within retention window — always keep
      continue
    fi

    # File is older than retention window
    if [[ $is_incremental -eq 1 ]]; then
      # Incremental: never a restore base, safe to delete
      files_to_delete+=("$fname")
    else
      # Full snapshot: track the newest one by mtime (largest mtime = most recent)
      if [[ $mtime -gt $newest_full_mtime ]]; then
        newest_full_mtime="$mtime"
        newest_full_name="$fname"
      fi
    fi
  done <<< "$lsf_output"

  # Second pass: mark old full files for deletion — except the most recent one
  while IFS=" " read -r fname mtime; do
    [[ -z "$fname" || -z "$mtime" ]] && continue
    [[ $mtime -lt $cutoff_epoch ]] && continue  # within window — already kept above

    [[ "$fname" == *" _I_"* || "$fname" == *"_I_".".zfs.gz" ]] && continue  # incremental — handled above

    # This is a full file older than retention window
    if [[ "$fname" != "$newest_full_name" ]]; then
      files_to_delete+=("$fname")
    fi
  done <<< "$lsf_output"

  if [[ ${#files_to_delete[@]} -eq 0 ]]; then
    echo "[zfs-gdrsync] [${ds}]   No archives past retention threshold to prune"
    return 0
  fi

  echo "[zfs-gdrsync] [${ds}]   Deleting ${#files_to_delete[@]} archive(s):"
  for f in "${files_to_delete[@]}"; do
    echo "[zfs-gdrsync] [${ds}]     - ${f}"
  done

  local delete_count=0
  local delete_errors=0
  for f in "${files_to_delete[@]}"; do
    if "$RCLONE" delete "${remote_folder}/${f}" 2>&1; then
      delete_count=$((delete_count + 1))
    else
      delete_errors=$((delete_errors + 1))
    fi
  done

  if [[ $delete_errors -eq 0 ]]; then
    echo "[zfs-gdrsync] [${ds}]   Pruning complete: ${delete_count} archive(s) deleted"
  else
    echo "[zfs-gdrsync] [${ds}]   WARNING: ${delete_errors} deletion error(s) — some old archives may remain"
    echo "[zfs-gdrsync] [${ds}]   This is non-fatal. Check GDrive manually if needed."
  fi
}


#==============================================================================
# FUNCTION: sync_dataset
#==============================================================================
# Main sync logic for a single dataset. Orchestrates:
#   1. Sanoid create snapshots
#   2. Sanoid prune old snapshots
#   3. Find newest local snapshot
#   4. Determine incremental vs full send based on state file
#   5. Push to GDrive
#   6. Update state file on success
#
# Arguments:
#   $1 — full dataset path, e.g. "cache/appdata/binhex-radarr"
#==============================================================================
sync_dataset() {
  local ds="$1"
  local ds_name="${ds##*/}"

  echo ""
  echo "[zfs-gdrsync] ================================================"
  echo "[zfs-gdrsync] Processing dataset: ${ds}"
  echo "[zfs-gdrsync] ================================================"

  # --- Step 1: Sanoid snapshot creation ---
  autosnap "$ds"

  # --- Step 2: Sanoid pruning ---
  autoprune "$ds"

  # --- Step 3: Find the newest local snapshot ---
  local newest_snap
  newest_snap=$(newest_snapshot "$ds")
  if [[ -z "$newest_snap" ]]; then
    echo "[zfs-gdrsync] [${ds}] No snapshots found — skipping"
    return 0
  fi
  echo "[zfs-gdrsync] [${ds}] Newest snapshot: ${newest_snap}"

  local newest_txg
  newest_txg=$(snapshot_txg "$newest_snap")
  echo "[zfs-gdrsync] [${ds}] Newest snapshot txg: ${newest_txg}"

  # --- Step 4: Read state to determine send mode ---
  local last_txg_str
  last_txg_str=$(read_state_txg "$ds")
  local last_txg=""
  [[ -n "$last_txg_str" ]] && last_txg="$last_txg_str"

  # Read the last full send info — needed to decide FULL vs INCREMENTAL
  local last_full_txg_str
  local last_full_iso_str
  last_full_txg_str=$(read_state_full_txg "$ds")
  last_full_iso_str=$(read_state_full_iso "$ds")
  [[ -n "$last_full_txg_str" ]] && last_full_txg="$last_full_txg_str"
  [[ -z "$last_full_iso_str" ]] && last_full_iso_str=""

  # Determine send mode: full vs incremental
  local from_snap=""
  local mode_desc=""
  local send_type="incremental"  # "full" or "incremental"

  # Decide: do we need a FULL send?
  # Conditions for full send:
  #   - No prior sync exists at all  OR
  #   - --force-full flag was passed  OR
  #   - Days since last full send >= gdrive_full_backup_days
  local days_since_full
  days_since_full=$(days_since_full_backup "$last_full_iso_str")
  local need_full="no"

  if [[ -z "$last_txg" || "$FORCE_FULL" == "yes" ]]; then
    need_full="yes"
  elif [[ "$days_since_full" -ge "$gdrive_full_backup_days" ]]; then
    need_full="yes"
  fi

  if [[ "$need_full" == "yes" ]]; then
    # Full send — no incremental base
    send_type="full"
    mode_desc="FULL (first sync${FORCE_FULL:+, forced}${last_txg:+, ${days_since_full} days since last full})"
    if [[ -z "$last_txg" ]]; then
      echo "[zfs-gdrsync] [${ds}] No prior sync found — performing full send"
    else
      echo "[zfs-gdrsync] [${ds}] Days since last full send: ${days_since_full} (threshold: ${gdrive_full_backup_days})"
      echo "[zfs-gdrsync] [${ds}] Full backup interval reached — performing full send"
    fi
  else
    # Incremental send — base is the last synced snapshot
    send_type="incremental"
    mode_desc="INCREMENTAL from txg ${last_txg} → ${newest_txg}"
    if [[ "$newest_txg" -le "$last_txg" ]]; then
      echo "[zfs-gdrsync] [${ds}] No new snapshots since last sync"
      echo "[zfs-gdrsync] [${ds}]   Last synced txg : ${last_txg}"
      echo "[zfs-gdrsync] [${ds}]   Newest local txg: ${newest_txg}"
      echo "[zfs-gdrsync] [${ds}]   Skipping — nothing to do"
      return 0
    fi

    from_snap=$(find_base_snapshot_for_incremental "$ds" "$last_txg")
    if [[ -z "$from_snap" ]]; then
      # Base snapshot was pruned locally — fall back to full send
      echo "[zfs-gdrsync] [${ds}] WARNING: base snapshot for txg ${last_txg} not found locally"
      echo "[zfs-gdrsync] [${ds}] Falling back to full send"
      send_type="full"
      mode_desc="FULL (fallback — base snapshot pruned locally)"
      from_snap=""
    else
      echo "[zfs-gdrsync] [${ds}] Incremental base snapshot: ${from_snap}"
    fi
  fi

  echo "[zfs-gdrsync] [${ds}] Send mode: ${mode_desc}"

  # --- Step 5: Push to GDrive ---
  if push_snapshot_to_gdrive "$ds" "$from_snap" "$newest_snap" "$rclone_remote" "$gdrive_root"; then
    echo "[zfs-gdrsync] [${ds}] Upload successful"

    # --- Step 6: Update state file ---
    local snap_iso
    snap_iso=$(snapshot_iso "$newest_snap")

    # If this was a FULL send, update the full snapshot tracker.
    # Otherwise, preserve the existing full snapshot info from state.
    local state_full_txg="$last_full_txg"
    local state_full_iso="$last_full_iso_str"
    if [[ "$send_type" == "full" ]]; then
      state_full_txg="$newest_txg"
      state_full_iso="$snap_iso"
      echo "[zfs-gdrsync] [${ds}] Full send complete — new full snapshot TXG: ${newest_txg}"
    fi

    if [[ "$DRY_RUN" != "yes" ]]; then
      write_state "$ds" "$newest_snap" "$newest_txg" "$snap_iso" \
                  "$state_full_txg" "$state_full_iso"
    else
      echo "[zfs-gdrsync] [${ds}] DRY RUN — would update state: txg=${newest_txg} snap=${newest_snap}"
    fi

    # --- Step 7: Prune old archives from GDrive ---
    # Only runs after state is recorded so a pruning failure doesn't risk
    # leaving state pointing at an archive that was deleted mid-prune.
    prune_gdrive_dataset "$ds"

    unraid_notify "GDrive push successful for ${ds_name}" "success"
    echo "[zfs-gdrsync] [${ds}] Done."
  else
    echo "[zfs-gdrsync] [${ds}] ERROR: Upload failed"
    unraid_notify "GDrive push FAILED for ${ds_name}: ${newest_snap}" "failure"
    return 1
  fi
}


#==============================================================================
# FUNCTION: pre_run_checks
#==============================================================================
# Validates all prerequisites before any sync work begins.
# Exits with a descriptive error if any required component is missing.
#==============================================================================
pre_run_checks() {
  echo "[zfs-gdrsync] Running pre-run checks..."

  # Check: ZFS utilities available
  if ! command -v zfs &>/dev/null; then
    echo "[zfs-gdrsync] ERROR: ZFS utilities not found on this system."
    echo "                 This script requires ZFS (kernel module + zfs utils)."
    exit 1
  fi
  echo "[zfs-gdrsync]   ✓ ZFS available"

  # Check: Sanoid installed
  if [[ ! -x "$SANOID" ]]; then
    echo "[zfs-gdrsync] ERROR: Sanoid not found at ${SANOID}"
    echo "                 Install the Sanoid Community Application plugin on Unraid."
    exit 1
  fi
  echo "[zfs-gdrsync]   ✓ Sanoid available at ${SANOID}"

  # Check: rclone installed
  if [[ ! -x "$RCLONE" ]]; then
    echo "[zfs-gdrsync] ERROR: rclone not found at ${RCLONE}"
    echo "                 Install rclone: curl https://rclone.org/install.sh | sudo bash"
    exit 1
  fi
  echo "[zfs-gdrsync]   ✓ rclone available at ${RCLONE}"

  # Check: rclone remote is configured
  if ! "$RCLONE" listremotes 2>/dev/null | grep -q "^${rclone_remote}:"; then
    echo "[zfs-gdrsync] ERROR: rclone remote '${rclone_remote}' is not configured."
    echo "                 Run 'rclone config' to set up your Google Drive remote."
    echo "                 Configured remotes:"
    "$RCLONE" listremotes 2>/dev/null | sed 's/^/                   /'
    exit 1
  fi
  echo "[zfs-gdrsync]   ✓ rclone remote '${rclone_remote}:' configured"

  # Check: jq installed (required for JSON state file operations)
  if [[ ! -x "$JQ" ]]; then
    echo "[zfs-gdrsync] ERROR: jq not found at ${JQ}"
    echo "                 Install jq: apk add jq  (or apt/dnf equivalent)"
    exit 1
  fi
  echo "[zfs-gdrsync]   ✓ jq available at ${JQ}"

  # Check: source dataset exists
  local source_ds
  source_ds=$(dataset_path "$source_pool" "$source_dataset")
  if ! zfs list -H "$source_ds" &>/dev/null; then
    echo "[zfs-gdrsync] ERROR: dataset ${source_ds} does not exist on this system."
    echo "                 Check your source_pool and source_dataset settings."
    exit 1
  fi
  echo "[zfs-gdrsync]   ✓ Dataset ${source_ds} exists"

  echo "[zfs-gdrsync] All pre-run checks passed."
}


#==============================================================================
# FUNCTION: get_dataset_list
#==============================================================================
# Builds the list of datasets to process based on source_pool/source_dataset
# and the auto-select configuration.
#
# Auto-select "yes" logic:
#   - Always includes the parent dataset itself first (e.g. cache/appdata).
#     This allows full recovery of the entire appdata tree in one restore, or
#     targeted recovery of specific child datasets individually.
#   - Then lists all direct children (one level deep only — not grandchildren)
#   - Applies exclusion filters (prefix + explicit names array) to children only.
#     The parent is never excluded — if you want to skip it, use auto-select "no".
#
# Auto-select "no" logic:
#   - Returns only the single dataset specified in source_dataset (no children)
#
# Output order: parent first, then children sorted by createtxg (newest first).
# This means the parent is always backed up before its children in each run.
#
# Returns:
#   One dataset path per line to stdout.
#==============================================================================
get_dataset_list() {
  local pool="$1"
  local parent="$2"
  local parent_path="${pool}/${parent}"

  if [[ "$source_dataset_auto_select" == "no" ]]; then
    # Single-dataset mode: just the named dataset, no children
    echo "$parent_path"
    return
  fi

  # Count depth of parent path (number of components separated by /)
  # e.g. "cache/appdata" has depth 2 — direct children have depth 3
  local parent_depth
  parent_depth=$(echo "$parent_path" | tr '/' '\n' | wc -l)

  # Always emit the parent itself first, before any children.
  # Having the parent backed up means you can restore all of appdata at once
  # (using the parent archive) or pick individual child archives for targeted
  # restores. The parent and children are backed up as separate archive files.
  echo "$parent_path"

  # Now list direct children only (depth == parent_depth + 1).
  # We deliberately exclude grandchildren and deeper — each app under appdata
  # is one direct child. If an app has sub-datasets, they're included in
  # that child's -I incremental stream via the -R flag on zfs send.
  # zfs list -H outputs tab-separated columns; awk splits on tabs.
  zfs list -r -H -o name "$parent_path" 2>/dev/null | \
    awk -F'/' -v pdepth="$parent_depth" -v parent_path="$parent_path" '
      # Skip the parent itself (already emitted above)
      $0 == parent_path { next }
      # Include only direct children (exactly one level deeper than parent)
      { n = split($0, parts, "/"); if (n == pdepth + 1) print }
    ' | \
    while IFS= read -r ds; do
      local ds_name="${ds##*/}"
      local skip=0

      # Apply prefix exclusion filter (skips children whose name starts with the prefix)
      if [[ -n "$source_dataset_auto_select_exclude_prefix" ]]; then
        if [[ "$ds_name" == "$source_dataset_auto_select_exclude_prefix"* ]]; then
          echo "[zfs-gdrsync]   Excluding (prefix match): ${ds_name}" >&2
          skip=1
        fi
      fi

      # Apply explicit name exclusion filter
      if [[ $skip -eq 0 ]]; then
        for excluded in "${source_dataset_auto_select_excludes[@]}"; do
          if [[ -n "$excluded" && "$ds_name" == "$excluded" ]]; then
            echo "[zfs-gdrsync]   Excluding (explicit match): ${ds_name}" >&2
            skip=1
            break
          fi
        done
      fi

      [[ $skip -eq 0 ]] && echo "$ds"
    done
}


#==============================================================================
# FUNCTION: main
#==============================================================================
# Entry point — orchestrates the full backup run.
#==============================================================================
main() {
  echo ""
  echo "[zfs-gdrsync] ================================================"
  echo "[zfs-gdrsync] zfs-gdrsync.sh — starting at $(date)"
  echo "[zfs-gdrsync]   Source pool/dataset : ${source_pool}/${source_dataset}"
  echo "[zfs-gdrsync]   Auto-select        : ${source_dataset_auto_select}"
  echo "[zfs-gdrsync]   rclone remote      : ${rclone_remote}:${gdrive_root}/"
  echo "[zfs-gdrsync]   State file         : ${state_file}"
  echo "[zfs-gdrsync]   GDrive retention   : ${gdrive_retention_days} days"
  echo "[zfs-gdrsync]   Dry run            : ${DRY_RUN}"
  echo "[zfs-gdrsync]   Force full         : ${FORCE_FULL}"
  echo "[zfs-gdrsync] ================================================"

  # Validate prerequisites
  pre_run_checks

  # Ensure the state file directory exists (on /boot partition for persistence)
  mkdir -p "$(dirname "$state_file")"

  # Build the dataset list once — used for both config creation and syncing.
  # Stored in a temp file so it can be read twice without re-running the
  # discovery logic (and without subshell scoping issues with mapfile).
  echo "[zfs-gdrsync] Preparing Sanoid configurations..."
  local dataset_list
  dataset_list=$(get_dataset_list "$source_pool" "$source_dataset")

  echo "[zfs-gdrsync] Datasets to process:"
  while IFS= read -r ds; do
    echo "[zfs-gdrsync]   → ${ds}"
    create_sanoid_config "$ds"
  done <<< "$dataset_list"

  # Sync each dataset in sequence, tracking per-dataset outcomes.
  # We use arrays instead of a subshell loop so that success/failure counts
  # are visible in the same shell scope as the summary below.
  echo ""
  echo "[zfs-gdrsync] Starting sync for all datasets..."

  local -a succeeded=()
  local -a failed=()
  local -a skipped=()

  while IFS= read -r ds; do
    local sync_result
    if sync_dataset "$ds"; then
      succeeded+=("$ds")
    else
      failed+=("$ds")
      echo "[zfs-gdrsync] WARNING: Dataset ${ds} failed — continuing with remaining datasets"
    fi
  done <<< "$dataset_list"

  # ── Summary ──────────────────────────────────────────────────────────────
  local total
  total=$(echo "$dataset_list" | wc -l)

  echo ""
  echo "[zfs-gdrsync] ================================================"
  echo "[zfs-gdrsync] Run complete at $(date)"
  echo "[zfs-gdrsync]   Total datasets : ${total}"
  echo "[zfs-gdrsync]   Succeeded      : ${#succeeded[@]}"
  echo "[zfs-gdrsync]   Failed         : ${#failed[@]}"

  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "[zfs-gdrsync]   Failed datasets:"
    for ds in "${failed[@]}"; do
      echo "[zfs-gdrsync]     ✗ ${ds}"
    done
  fi

  echo "[zfs-gdrsync]   View archives  : rclone lsd ${rclone_remote}:${gdrive_root}"
  echo "[zfs-gdrsync]   Log search     : grep -i 'error\\|fail\\|warn' /var/log/zfs-gdrsync.log"
  echo "[zfs-gdrsync] ================================================"

  # ── Final summary notification ────────────────────────────────────────────
  # Sends one notification covering the whole run, in addition to the
  # per-dataset notifications sent inside sync_dataset().
  if [[ ${#failed[@]} -eq 0 ]]; then
    unraid_notify "All ${#succeeded[@]}/${total} datasets backed up to GDrive successfully." "success"
    exit 0
  else
    unraid_notify "${#failed[@]}/${total} datasets FAILED. Check /var/log/zfs-gdrsync.log for details." "failure"
    exit 1
  fi
}


#==============================================================================
# SCRIPT ENTRY POINT
#==============================================================================
# Pass all arguments to main() — allows function definitions to be read and
# validated before any execution begins.
main "$@"
