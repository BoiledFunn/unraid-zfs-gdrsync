# zfs-gdrsync — Unraid ZFS Snapshot Backup to Google Drive

A self-updating Unraid plugin that pushes ZFS snapshots to Google Drive via rclone.

- **Snapshot management:** Sanoid (local retention policy)
- **Upload transport:** rclone streaming (`zfs send | gzip | rclone rcat`)
- **Persistence:** All config and state survive OS updates — stored on `/boot/config/`
- **Update model:** Private GitHub release → plugin update via Unraid Plugins UI

---

## Architecture

```
Sanoid (plugin on Unraid host)
  └─ Creates daily snapshots at 23:59
  └─ Prunes per retention policy (7 daily, 4 weekly, 3 monthly)

zfs-gdrsync.sh (runs at 00:30 daily via User Scripts)
  └─ For each dataset (cache/appdata + all children):
       ├─ Find newest snapshot (sorted by createtxg, not name)
       ├─ Determine full vs incremental send based on state file
       ├─ zfs send [-I base] target | gzip -n | rclone rcat → GDrive
       └─ Update /boot/config/zfs-gdrsync-state.json
```
/root/zfs-gdrsync/                   ← canonical script location (ext4, executable)
  └─ zfs-gdrsync.sh                  (chmod +x, runs via bash)
  └─ config (reference copy)

/boot/config/zfs-gdrsync/            ← reference/data location (FAT32, not executable)
  ├─ config                          (user settings — source of truth for script)
  ├─ zfs-gdrsync.sh (reference copy only — script reads config from here)
  └─ zfs-gdrsync-state.json          (per-dataset sync state)
  ├─ rclone.conf                     (GDrive auth — survives OS updates)
  └─ plugins/user.scripts/scripts/zfs-gdrsync/  (User Scripts entry)

NOTE: The main script lives at /root/zfs-gdrsync/zfs-gdrsync.sh (ext4 array disk)
because FAT32 (/boot) does not support Unix execute bits. The script reads its
config from /boot/config/zfs-gdrsync/config which is on FAT32 — this is fine since
config is just data, not executable code.
```

**Why ZFS incremental streams instead of rsync:**
Google Drive doesn't support hardlinks (`--link-dest` approach breaks). ZFS incremental streams (`-I`) handle deduplication at the block level before the stream is generated — GDrive just sees a large binary blob per snapshot.

**Why createtxg instead of snapshot name:**
Sanoid recursive snapshots give all child datasets identical names (e.g., `@2026-05-27-040706`). Using the ZFS transaction group number (`createtxg`) uniquely identifies each snapshot even when names are identical.

---

## Critical Notes for Unraid Users

### Boot persistence — why the go file matters

Unraid runs its OS from a RAM disk rebuilt from USB on every boot. `/root/`, `/etc/`, `/var/`, and `/usr/local/sbin/` are all **tmpfs — wiped on every reboot**.

`install.sh` adds entries to `/boot/config/go` (Unraid's persistent startup script) so that scripts are automatically redeployed to tmpfs after every reboot. Without this, the nightly backup silently fails after every restart.

If you ever reinstall the plugin or restore from backup, verify the go file entries are present:

```bash
grep "zfs-gdrsync" /boot/config/go
```

### rclone config must live on /boot

The rclone config (GDrive auth) must be stored at `/boot/config/rclone/rclone.conf` — **not** at `~/.config/rclone/rclone.conf`, which is tmpfs and wiped on reboot.

`install.sh` handles this automatically on fresh install. The go file entries redeploy it to tmpfs on every boot. The script also has a self-healing fallback that restores it at runtime if missing.

### autosnapshots must be "yes" on most Unraid systems

With `autosnapshots="no"` (the old default), the plugin only pushes existing snapshots — it never creates them. On most Unraid systems there is no external Sanoid cron, so `autosnapshots="no"` means **the backup silently does nothing every night**.

Set `autosnapshots="yes"` in `/boot/config/zfs-gdrsync/config` unless you have a verified external Sanoid schedule already running.

### Google Advanced Protection Program blocks OAuth

If your Google account uses **Advanced Protection Program**, rclone OAuth will be permanently blocked. You must use **service account authentication** instead.

#### Service account setup (required for Advanced Protection Program users)

1. Go to [Google Cloud Console](https://console.cloud.google.com/) → create or select a project
2. Enable the **Google Drive API** for the project
3. **IAM & Admin** → **Service Accounts** → **Create Service Account**
   - Name: `rclone-gdrive` (or any name)
   - No role required — click through
4. Click the service account → **Keys** → **Add Key** → **Create new key** → **JSON**
   - Download the JSON key file
   - Store it at `/boot/config/rclone/service-account.json` on Unraid (persistent)
   - **Never commit this file to any repository**
5. Share your GDrive backup folder with the service account email (found in the JSON key as `client_email`)
   - Open Google Drive → right-click your backup folder → **Share**
   - Paste the service account email → **Editor** access
   - Copy the folder ID from the URL: `drive.google.com/drive/folders/<FOLDER_ID>`
6. Create `/boot/config/rclone/rclone.conf` with:
   ```ini
   [gdrive]
   type = drive
   scope = drive
   service_account_file = /boot/config/rclone/service-account.json
   root_folder_id = <YOUR_FOLDER_ID>
   team_drive =
   ```

### Sanoid plugin vs zfs-gdrsync snapshot management

The Sanoid plugin provides the `sanoid` and `syncoid` binaries — that's all zfs-gdrsync needs from it. zfs-gdrsync manages its **own per-dataset Sanoid configs** stored under `/boot/config/sanoid-gdrsync/`. The Sanoid plugin's own config and scheduling are **not used** by zfs-gdrsync.

### --dry-run warning

Avoid `--dry-run` on a system that has pending incremental uploads. In v1.0.x, `--dry-run` skips the upload but still updates the state file, breaking the incremental chain. Fixed in v1.1.0.

---

## Prerequisites (One-Time Setup)

### 1. Install Sanoid Plugin

From the Unraid Community Applications:
- Search "Sanoid" → install the "Sanoid" plugin (not the Docker)
- Syncoid is bundled with the Sanoid plugin on Unraid

Verify:
```bash
/usr/local/sbin/sanoid --version
/usr/local/sbin/syncoid --version
```

### 2. Install rclone

```bash
curl https://rclone.org/install.sh | sudo bash
```

Verify:
```bash
rclone version
```

### 3. Configure Google Drive Remote

**Note:** If you use Google Advanced Protection Program, OAuth is blocked — see the [Service account setup](#service-account-setup-required-for-advanced-protection-program-users) section above instead.

```bash
mkdir -p /boot/config/rclone
rclone config --config /boot/config/rclone/rclone.conf
```

Follow the prompts:
- **Name:** `gdrive` (must match whatever is in your `config` file)
- **Storage type:** `drive`
- **Client ID/Secret:** leave blank (use rclone's public Google OAuth)
- **Scope:** `Full access` (or `root` if you prefer limited access)
- **Auto config:** `y` (opens browser on your local machine for OAuth)

### 4. Verify rclone config is at the persistent path

The config must be at `/boot/config/rclone/rclone.conf` (on `/boot`, which persists across OS updates). The go file entries added by `install.sh` redeploy it to tmpfs on every boot.

```bash
ls /boot/config/rclone/rclone.conf   # should exist
rclone listremotes --config /boot/config/rclone/rclone.conf  # should show gdrive:
```

On every plugin install/update, `install.sh` also copies the config to `~/.config/rclone/rclone.conf` for the current session.

---

## Installation (First Time)

### Step 1 — Create GitHub Repository

1. Go to github.com → sign in → click **New repository**
2. **Repository name:** `unraid-zfs-gdrsync`
3. **Description:** `ZFS snapshot backup from Unraid cache pool to Google Drive via rclone`
4. **Visibility:** ⚠️ Select **Private** (critical — your GDrive auth is in the rclone config)
5. **Don't initialize with README** (you'll create your own)

### Step 2 — Generate a Personal Access Token (PAT)

1. Go to github.com → your profile → **Settings** → **Developer Settings** → **Personal access tokens** → **Tokens (classic)**
2. Click **Generate new token (classic)**
3. **Name:** `unraid-plugin-upload`
4. **Expiration:** 90 days (or 1 year if you prefer less maintenance)
5. **Scopes:** ✅ `repo` (full control of private repositories)
6. Click Generate — **copy the token immediately** and save it somewhere safe

### Step 3 — Create the Release Package

On your local machine (not on Unraid):

```bash
cd /path/to/unraid-zfs-gdrsync/plugin

# Verify all files are in place
ls -la
# Should show: PLUGIN, install.sh, uninstall.sh, config, scripts/, sanoid/

# Create the .plg package (it's a tar.gz of everything)
tar -cvzf ../zfs-gdrsync-1.0.0.plg \
  PLUGIN \
  install.sh \
  uninstall.sh \
  config \
  scripts/ \
  sanoid/

# Verify contents
tar -tzf ../zfs-gdrsync-1.0.0.plg
```

### Step 4 — Create GitHub Release

1. Go to your repo on github.com
2. Click **Releases** → **Create a new release**
3. **Tag version:** `v1.0.0`
4. **Release title:** `zfs-gdrsync v1.0.0`
5. **Description:**
   ```
   Initial release — ZFS snapshot backup to Google Drive via rclone.
   Requires Sanoid plugin and rclone configured with a GDrive remote.
   See README for installation instructions.
   ```
6. **Attach the `.plg` file** — drag `zfs-gdrsync-1.0.0.plg` into the attachments area
7. Click **Publish release**

### Step 5 — Install Plugin on Unraid

1. Copy the download URL: `https://github.com/BoiledFunn/unraid-zfs-gdrsync/releases/download/v1.0.0/zfs-gdrsync-1.0.0.plg`
2. Unraid web UI → **Plugins** → **Install** → paste the URL
3. Click **Install**

### Step 6 — Watch the Install Log

```bash
# From your local terminal:
ssh unraid "tail -f /var/log/syslog | grep zfs-gdrsync"

# Or on Unraid's terminal:
tail -f /var/log/syslog | grep zfs-gdrsync
```

You should see:
```
zfs-gdrsync-install: starting install
zfs-gdrsync-install: deploying scripts to /boot/config/plugins/zfs-gdrsync
zfs-gdrsync-install: user config deployed to /boot/config/zfs-gdrsync/config
zfs-gdrsync-install: snap hooks deployed to /usr/local/sbin
zfs-gdrsync-install: restoring rclone config from /boot/config/rclone/rclone.conf
zfs-gdrsync-install: rclone remote 'gdrive' verified
zfs-gdrsync-install: user scripts entry created
zfs-gdrsync-install: install complete
```

### Step 7 — Verify the Setup

```bash
# Check the main script is in place (ext4, executable)
ls -la /root/zfs-gdrsync/

# Verify rclone remote is accessible
rclone listremotes
# Should show: gdrive:

# Dry run (preview what would happen)
# Wait until 00:30 for the first scheduled run, or trigger manually:
bash /root/zfs-gdrsync/zfs-gdrsync.sh --dry-run

# Watch the dry run output
tail -f /var/log/zfs-gdrsync.log
```

---

## First Real Run

The first upload will take a while — it sends full snapshots for `cache/appdata` and all children:

- **jellyfin** (~63GB used, ~1-2GB compressed stream for a full)
- **immich** (~840MB used)
- **binhex-radarr** (~736MB used)
- **binhex-sonarr** (~250MB used)
- Everything else: under 100MB each

```bash
# Run manually the first time so you can monitor it:
bash /root/zfs-gdrsync/zfs-gdrsync.sh

# Watch output in another terminal:
ssh unraid "tail -f /var/log/zfs-gdrsync.log"
```

**Estimated first-run time:** 30–90 minutes depending on your internet upload speed.

---

## Verifying the Backup

```bash
# Check GDrive folder structure appeared
rclone lsd gdrive:zfs-archives/cache/appdata

# Check state file (per-dataset tracking)
cat /boot/config/zfs-gdrsync-state.json | jq '.'

# View Sanoid snapshots locally
zfs list -t snapshot -r cache/appdata

# Check what was uploaded
rclone ls gdrive:zfs-archives/cache/appdata | head -20
```

**Expected GDrive structure:**
```
gdrive:zfs-archives/cache/appdata/
  cache/appdata/jellyfin@2026-05-27-235959.zfs.gz
  cache/appdata/immich@2026-05-27-235959.zfs.gz
  cache/appdata/binhex-radarr@2026-05-27-235959.zfs.gz
  cache/appdata/binhex-sonarr@2026-05-27-235959.zfs.gz
  ...
```

---

## Updating the Plugin

When you want to update to a new version (new script features, bug fixes):

### On Your Local Machine

```bash
cd /path/to/unraid-zfs-gdrsync

# Make your changes to the plugin files
# Then rebuild the .plg:
cd plugin
tar -cvzf ../zfs-gdrsync-1.1.0.plg \
  PLUGIN \
  install.sh \
  uninstall.sh \
  config \
  scripts/ \
  sanoid/

# Commit and tag
cd ..
git add -A
git commit -m "v1.1.0 — add new feature X"
git tag v1.1.0
git push origin main
git push origin v1.1.0
```

### On GitHub

1. Go to your repo → **Releases** → **Create a new release**
2. Tag: `v1.1.0`, title: `zfs-gdrsync v1.1.0`
3. Attach the new `.plg` file
4. Publish

### On Unraid

1. Unraid UI → **Plugins** → find `zfs-gdrsync` → click **Update**
2. Watch `/var/log/syslog` for completion
3. State file and rclone config are untouched — only scripts are updated

---

## Configuration

Edit `/boot/config/zfs-gdrsync/config` to change any setting. The file survives OS updates — you only need to do this once.

**Key settings:**

```bash
source_pool="cache"
source_dataset="appdata"
source_dataset_auto_select="yes"           # backup all children too
gdrive_retention_days="14"                  # keep 14 days on GDrive
rclone_remote="gdrive"                      # must match your rclone config
snapshot_days="7"                           # Sanoid local retention
```

---

## Manual Operations

```bash
# Dry run (preview what would be pushed, no changes)
bash /root/zfs-gdrsync/zfs-gdrsync.sh --dry-run

# Force full send (ignores state file, re-uploads everything)
bash /root/zfs-gdrsync/zfs-gdrsync.sh --force-full

# Remove state file to start fresh (full re-upload on next run)
rm /boot/config/zfs-gdrsync-state.json
bash /root/zfs-gdrsync/zfs-gdrsync.sh

# View recent log
tail -30 /var/log/zfs-gdrsync.log

# Search log for errors
grep -i 'error\|fail\|warn' /var/log/zfs-gdrsync.log
```

---

## What Survives What

| Item | Survives OS update? | Location |
|---|---|---|
| Main script (`zfs-gdrsync.sh`) | ✅ Yes | `/root/zfs-gdrsync/zfs-gdrsync.sh` (ext4, executable) |
| Reference copy of script | ✅ Yes | `/boot/config/zfs-gdrsync/zfs-gdrsync.sh` (FAT32, not executable — reference only) |
| User config (`config`) | ✅ Yes | `/boot/config/zfs-gdrsync/config` |
| State file | ✅ Yes | `/boot/config/zfs-gdrsync-state.json` |
| rclone auth token | ✅ Yes | `/boot/config/rclone/rclone.conf` (persistent), copied to tmpfs by go file |
| Sanoid config | ✅ Yes | `/etc/sanoid/sanoid.conf` |
| User Scripts entry | ✅ Yes | `/boot/config/plugins/user.scripts/` |
| rclone binary | ✅ Yes (reinstalled via curl on each update) | `/usr/bin/rclone` or `/usr/local/bin/rclone` |
| Sanoid binary | ✅ Yes | `/usr/local/sbin/sanoid` (plugin survives reinstallation) |
| Snap hooks (`snap-pre.sh`, `snap-post.sh`) | ⚠️ Re-deployed on each plugin update | `/usr/local/sbin/` (may not survive OS updates) |

**Note:** If an OS update removes `snap-pre.sh` / `snap-post.sh` from `/usr/local/sbin/`, re-running the plugin update will restore them.

**⚠️ FAT32 `/boot` execute permission issue:** The USB flash drive holding the Unraid OS is FAT32, which does not support Unix execute bits. The main script `zfs-gdrsync.sh` MUST be run from a Linux filesystem (ext4), not from `/boot`. The install script automatically places it at `/root/zfs-gdrsync/zfs-gdrsync.sh` which is on your array disk (ext4). If you ever see "Permission denied" when running the script, check that you're using the `/root/` location, not the `/boot/config/zfs-gdrsync/` reference copy.

---

## Uninstall

```bash
# Run the uninstall script from the plugin directory
# (accessible at /boot/config/plugins/zfs-gdrsync/uninstall.sh after install)
/boot/config/plugins/zfs-gdrsync/uninstall.sh

# Or remove manually:
rm -f /boot/config/zfs-gdrsync/zfs-gdrsync.sh
rm -rf /boot/config/plugins/zfs-gdrsync
rm -rf /boot/config/plugins/user.scripts/scripts/zfs-gdrsync
```

**Preserved on uninstall (by design):**
- `/boot/config/zfs-gdrsync-state.json` — state file
- `/boot/config/rclone/rclone.conf` — GDrive auth
- `/boot/config/rclone/service-account.json` — service account key (if used)

---

## Restoring from Backup

### Single Dataset (e.g., binhex-radarr)

```bash
# 1. Find the snapshot on GDrive
rclone lsd gdrive:zfs-archives/cache/appdata/binhex-radarr

# 2. Download the archive (replace SNAPSHOT_NAME with actual filename)
/boot/config/zfs-gdrsync/scripts/rsync/rclone copy "gdrive:zfs-archives/cache/appdata/binhex-radarr/SNAPSHOT_NAME.zfs.gz" /tmp/restore.zfs.gz

# 3. Decompress
gunzip /tmp/restore.zfs.gz  # produces /tmp/restore.zfs

# 4. Receive to a new dataset (or existing — ZFS will warn on conflict)
zfs receive -v cache/appdata/binhex-radarr-restored < /tmp/restore.zfs

# 5. Verify
zfs list -t snapshot -r cache/appdata/binhex-radarr-restored
```

### Full Dataset Tree (cache/appdata itself)

```bash
# Download the cache/appdata archive
rclone copy "gdrive:zfs-archives/cache/appdata/cache@appdata_2026-05-27-235959.zfs.gz" /tmp/restore.zfs.gz
gunzip /tmp/restore.zfs.gz
zfs receive -v cache/appdata-restored < /tmp/restore.zfs
```

**Note:** The restore creates a new dataset — it doesn't overwrite your existing data. Use `zfs receive -F` to force overwrite if needed (⚠️ destructive).

---

## Troubleshooting

### "rclone remote 'gdrive' not found"
```bash
# Re-check your rclone config
rclone listremotes
# If empty or wrong name:
rclone config
# Delete and recreate, or edit /boot/config/zfs-gdrsync/config to match
```

### "zfs-gdrsync-install: WARNING: rclone config not found"
```bash
# Config not found at /boot/config/rclone/rclone.conf
# Run rclone config to create it at the persistent path:
mkdir -p /boot/config/rclone
rclone config --config /boot/config/rclone/rclone.conf

# Then deploy to tmpfs for the current session:
mkdir -p /root/.config/rclone
cp /boot/config/rclone/rclone.conf /root/.config/rclone/rclone.conf

# Then verify:
rclone listremotes
```

### "jq not found"
```bash
# Install jq via Community Apps or manually:
apk add jq  # if available
# Or: curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /usr/bin/jq && chmod +x /usr/bin/jq
```

### First upload takes forever
This is expected. The first run sends full snapshots for all child datasets. Jellyfin (63GB used, ~1-2GB compressed per snapshot stream) is the slowest. Subsequent runs use incremental streams.

### "No new snapshots since last sync" but you know there are new ones
The state file tracks by `createtxg`. If Sanoid's recursive snapshots all share the same createtxg (which is normal), and that txg was already synced, the script correctly reports nothing new. This is correct behavior — the createtxg IS the same because Sanoid created them in a single transaction.

---

## File Structure

```
unraid-zfs-gdrsync/               ← GitHub repo root
├── PLUGIN                        ← Unraid plugin manifest (install.sh on both install and update)
├── install.sh                    ← Main install/update script (idempotent)
├── uninstall.sh                  ← Removal script
├── config                        ← User settings (pool, dataset, retention, remote name)
├── scripts/
│   ├── zfs-gdrsync.sh            ← Main backup script
│   ├── snap-pre.sh               ← Stops Docker containers before snapshot
│   └── snap-post.sh              ← Restarts containers after snapshot
├── sanoid/
│   └── sanoid.conf               ← Sanoid config for cache/appdata + all children
└── README.md                     ← This file
```

Releases are `.plg` files (tar.gz of the above structure) attached to GitHub releases.