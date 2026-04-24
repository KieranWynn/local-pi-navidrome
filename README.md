# Navidrome Pi Setup

A one-command setup script to turn a fresh Raspberry Pi into a self-hosted music server using [Navidrome](https://www.navidrome.org/), with music stored on a NAS.

---

## Part 1 — Raspberry Pi initial setup

Follow these steps on a brand new Pi, or whenever you need to reinstall the operating system from scratch.

### Step 1: Flash the operating system

1. Unplug the Raspberry Pi.
2. Remove the USB flash drive or SD card from the Pi and insert it into another computer.
3. Download and install **Raspberry Pi Imager** from [raspberrypi.com/software](https://www.raspberrypi.com/software/).
4. Open the Imager and configure as follows:
   - **Device:** Raspberry Pi 4 Model B
   - **Operating System:** Raspberry Pi OS (Other) → Raspberry Pi OS Lite (64-bit)
   - **Storage:** select your USB flash drive or SD card
5. Click **Edit Settings** (or the ⚙ icon) and customise:

   | Setting | Value |
   |---|---|
   | Hostname | `raspberrycheesecake` |
   | Username | `pi` |
   | Password | Choose something memorable — you'll need it shortly |
   | Timezone | Your country / your city |
   | Keyboard layout | `US` |
   | Wi-Fi | Leave blank — we'll use a wired ethernet connection |
   | SSH | ✅ Enabled, password authentication |
   | Raspberry Pi Connect | Disabled |

6. Write the image to the storage medium. **This will erase everything on it.**
7. Once writing and verification are complete, remove the drive and put it back in the Pi.
8. Connect the Pi to your router via ethernet, then plug the power in. Give it a few minutes to boot up.

### Step 2: Log in and run the setup script

1. On your computer, open a terminal (e.g. `Terminal.app` on macOS) and connect to the Pi:

   ```bash
   ssh pi@raspberrycheesecake.local
   ```

2. If the connection fails after a while, check your ethernet cable and router, then retry the step above.

3. If this is your first time connecting, you'll see a warning that the device's authenticity can't be verified — this is expected. Type `yes` and press Enter to trust it.

4. Enter the password you chose above and press Enter.

5. If the prompt changes to `pi@raspberrycheesecake:~ $` you're in. ✅

6. Run the setup script:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/KieranWynn/local-pi-navidrome/main/setup.sh | sudo bash
   ```

7. When prompted, enter your password again and press Enter. The script will take it from here.

---

## Part 2 — What the setup script does

1. **Updates** the Pi's software
2. **Installs Docker** (the engine that runs Navidrome)
3. **Mounts your NAS** so the Pi can read your music library (and access backups)
4. **Downloads the latest config** from this GitHub repo
5. **Restores a Navidrome backup** from the NAS, if one exists
6. **Starts Navidrome** and ensures it restarts automatically when the Pi reboots

The script is **safe to run more than once** — it won't break an already working setup.

---

## Part 3 — After setup

### Re-running / disaster recovery

If something goes wrong (Pi dies, SD card corrupts, etc.), just flash a fresh Raspberry Pi OS Lite 64-bit image and run the same `curl` command above. Your music library lives on the NAS and is untouched.

---

### Customising the setup

You can override any default by setting environment variables before running the script:

```bash
GITHUB_REPO="KieranWynn/local-pi-navidrome" \
NAVIDROME_PORT="4533" \
NAS_MUSIC_EXPORT="/music" \
curl -fsSL https://raw.githubusercontent.com/KieranWynn/local-pi-navidrome/main/setup.sh | sudo bash
```

| Variable | Default | Description |
|---|---|---|
| `GITHUB_REPO` | `KieranWynn/local-pi-navidrome` | GitHub repo containing this config |
| `GITHUB_BRANCH` | `main` | Branch to pull config from |
| `APP_DIR` | `/opt/navidrome` | Where compose + config files live on the Pi |
| `NAVIDROME_DATA_DIR` | `/var/lib/navidrome` | Where Navidrome stores its database |
| `NAS_MOUNT_BASE` | `/mnt/nas` | Base mount point on the Pi |
| `NAS_EXPORT` | `/share/nas-storage` | NFS export path (top-level shared folder on the NAS) |
| `NAS_MUSIC_SUBDIR` | `music` | Subdirectory within the share for the music library |
| `NAS_BACKUP_SUBDIR` | `backup/navidrome-backups` | Subdirectory within the share for backups |
| `NAVIDROME_PORT` | `4533` | Port Navidrome listens on |

---

### NAS folder structure expected

```
your-nas/
├── music/                           ← your music library (read-only access)
│   ├── Artist/
│   │   └── Album/
│   │       └── track.flac
└── backup/
    └── navidrome-backups/           ← Navidrome backups (written automatically)
        └── navidrome_backup_*.tar.gz
```

---

### Backup

Backups are handled automatically — no extra configuration needed. Navidrome is configured to back up its database to the NAS every Friday at midday, keeping the 20 most recent backups. The backup files are written directly to your NAS backup share, so they're safe even if the Pi dies.

If you want to change the schedule or retention count, edit the relevant lines in `compose.yml`:

| Variable | Default | Description |
|---|---|---|
| `ND_BACKUP_SCHEDULE` | `0 12 * * 5` | When to back up, in [cron syntax](https://en.wikipedia.org/wiki/Cron#CRON_expression). The default is every Friday at midday. |
| `ND_BACKUP_COUNT` | `20` | How many backups to keep. Older ones are deleted automatically. |

The backup destination is your NAS backup share, mounted at `/mnt/nas/backups` on the Pi. To use a different location, update `NAS_BACKUP_EXPORT` in the setup script and `ND_BACKUP_PATH` in `compose.yml` to match.

---

### Useful commands

```bash
# Check Navidrome is running
sudo docker compose -f /opt/navidrome/compose.yml ps

# View recent logs
sudo docker compose -f /opt/navidrome/compose.yml logs --tail=50

# Restart Navidrome
sudo docker compose -f /opt/navidrome/compose.yml restart

# Update Navidrome to the latest version
sudo docker compose -f /opt/navidrome/compose.yml pull
sudo docker compose -f /opt/navidrome/compose.yml up -d

# Check NAS is mounted
mountpoint /mnt/nas/music && echo "✔ Music NAS is mounted" || echo "✘ Not mounted"
```

---

### Files in this repo

| File | Purpose |
|---|---|
| `setup.sh` | The main setup script |
| `compose.yml` | Docker Compose definition for Navidrome |
| `navidrome.toml` | Navidrome configuration |

---

### Requirements

- Raspberry Pi 3B+ or newer (tested on Pi 4)
- Raspberry Pi OS Lite **64-bit** (fresh install recommended)
- NAS with SMB or NFS share for music
- Internet connection during setup