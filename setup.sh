#!/usr/bin/env bash
# =============================================================================
# Navidrome Setup Script
# =============================================================================
# Run this on a fresh Raspberry Pi OS Lite (64-bit) with:
#
#   curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/setup.sh | sudo bash
#
# It is safe to run again on an already-configured Pi — nothing will break.
#
# NOTE: This script must be run as root (via sudo).
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# =============================================================================
# ── CONFIG — edit these values before pushing to GitHub ──────────────────────
# =============================================================================

GITHUB_REPO="${GITHUB_REPO:-"KieranWynn/local-pi-navidrome"}"
GITHUB_BRANCH="${GITHUB_BRANCH:-"main"}"

# Where things live on the Pi
APP_DIR="${APP_DIR:-"/opt/navidrome"}"                       # compose.yml + navidrome.toml
NAVIDROME_DATA_DIR="${NAVIDROME_DATA_DIR:-"/var/lib/navidrome"}"  # Navidrome DB/cache

# NAS — single NFS export (the top-level shared folder on your NAS)
# The user will be asked for the NAS IP at runtime; paths are fixed here.
NAS_EXPORT="${NAS_EXPORT:-"/share/nas-storage"}"         # NFS export path (QNAP top-level share)

# Subdirectory paths within the share for music and backups
NAS_MUSIC_SUBDIR="${NAS_MUSIC_SUBDIR:-"music"}"
NAS_BACKUP_SUBDIR="${NAS_BACKUP_SUBDIR:-"backup/navidrome-backups"}"

# Where the NAS share gets mounted on the Pi, and derived subpaths
NAS_MOUNT_BASE="${NAS_MOUNT_BASE:-"/mnt/nas"}"
NAS_SHARE_MOUNT="${NAS_MOUNT_BASE}/nas-storage"
NAS_MUSIC_MOUNT="${NAS_SHARE_MOUNT}/${NAS_MUSIC_SUBDIR}"
NAS_BACKUP_MOUNT="${NAS_SHARE_MOUNT}/${NAS_BACKUP_SUBDIR}"

# Navidrome web UI port
NAVIDROME_PORT="${NAVIDROME_PORT:-"4533"}"

# =============================================================================

FSTAB_MARKER="# navidrome-setup managed"

# ── Helpers ───────────────────────────────────────────────────────────────────

say() {
    echo -e "\n${BLUE}${BOLD}▶  $*${NC}"
}

ok() {
    echo -e "   ${GREEN}✔  $*${NC}"
}

warn() {
    echo -e "   ${YELLOW}⚠  $*${NC}"
}

die() {
    echo -e "\n${RED}${BOLD}✘  ERROR: $*${NC}" >&2
    echo -e "${RED}   Setup did not complete. Please read the message above and try again.${NC}\n" >&2
    exit 1
}

ask() {
    # ask <varname> <prompt> [default]
    local var="$1" prompt="$2" default="${3:-}"
    local hint=""
    [[ -n "$default" ]] && hint=" [press Enter for: ${default}]"
    echo -ne "\n   ${BOLD}${prompt}${hint}: ${NC}"
    local input
    read -r input </dev/tty
    [[ -z "$input" && -n "$default" ]] && input="$default"
    printf -v "$var" '%s' "$input"
}

ask_secret() {
    # ask_secret <varname> <prompt>  — input is not echoed to the screen
    local var="$1" prompt="$2"
    echo -ne "\n   ${BOLD}${prompt}: ${NC}"
    local input
    read -rs input </dev/tty
    echo
    printf -v "$var" '%s' "$input"
}

confirm() {
    # confirm <prompt>  →  0 = yes, 1 = no
    echo -ne "\n   ${BOLD}$* (y/n): ${NC}"
    local yn
    read -r yn </dev/tty
    [[ "$yn" =~ ^[Yy]$ ]]
}

check_root() {
    [[ "$EUID" -eq 0 ]] || die "This script must be run as root. Try:  sudo bash setup.sh"
}

require_internet() {
    say "Checking internet connection..."
    curl -fsS --max-time 10 https://github.com >/dev/null 2>&1 \
        || die "No internet detected. Please connect and try again."
    ok "Internet is reachable."
}

# ── Banner ────────────────────────────────────────────────────────────────────

print_banner() {
    echo -e "\n${BOLD}"
    echo "   ╔══════════════════════════════════════════════╗"
    echo "   ║      Navidrome Pi Setup  🎵                  ║"
    echo "   ║      Your music server, coming right up      ║"
    echo "   ╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "   This script will set up your Raspberry Pi as a music server."
    echo "   It will ask you a couple of questions, then handle everything else."
    echo "   You can run it again at any time — it is completely safe to repeat."
    echo
}

# ── Step 1 — Gather inputs upfront (so the user can walk away after ~2 questions) ──

gather_inputs() {
    say "A couple of quick questions before we start..."

    ask NAS_HOST \
        "What is the IP address of your NAS? (e.g. 192.168.1.100)" \
        ""
    [[ -z "$NAS_HOST" ]] && die "NAS address is required."

    ask_secret CLOUDFLARE_TUNNEL_TOKEN \
        "Cloudflare Tunnel token (press Enter to skip if not using a tunnel)"

    echo
    echo -e "   ${BOLD}Here is what will be set up:${NC}"
    echo "   • NAS address     : ${NAS_HOST}"
    echo "   • NAS share       : ${NAS_HOST}:${NAS_EXPORT}  →  ${NAS_SHARE_MOUNT}"
    echo "   • Music library   : ${NAS_SHARE_MOUNT}/${NAS_MUSIC_SUBDIR}"
    echo "   • Backups         : ${NAS_SHARE_MOUNT}/${NAS_BACKUP_SUBDIR}"
    echo "   • Config files    : ${APP_DIR}"
    echo "   • Navidrome data  : ${NAVIDROME_DATA_DIR}"
    echo "   • Web address     : http://$(hostname -I | awk '{print $1}'):${NAVIDROME_PORT}"
    local tunnel_status
    [[ -n "$CLOUDFLARE_TUNNEL_TOKEN" ]] && tunnel_status="✔ token provided" || tunnel_status="skipped"
    echo "   • Cloudflare tunnel: ${tunnel_status}"
    echo

    confirm "Does that all look correct?" \
        || die "No problem — please re-run the script when you're ready."
}

# ── Step 2 — System update ────────────────────────────────────────────────────

update_system() {
    say "Updating the Pi's software (may take a few minutes)..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    ok "System software is up to date."

    say "Installing required tools..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl \
        git \
        ca-certificates \
        gnupg \
        lsb-release \
        nfs-common \
        rsync
    ok "Tools are installed."
}

# ── Step 3 — Install Docker ───────────────────────────────────────────────────

install_docker() {
    say "Setting up Docker..."

    if command -v docker &>/dev/null; then
        ok "Docker is already installed ($(docker --version | cut -d' ' -f3 | tr -d ',')).  Skipping."
    else
        # Official Docker convenience script — handles Pi ARM64 architecture correctly
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh --quiet
        rm -f /tmp/get-docker.sh
        ok "Docker installed."
    fi

    # Add the primary non-root user (uid 1000, typically 'pi') to the docker group
    local default_user
    default_user=$(getent passwd 1000 | cut -d: -f1 2>/dev/null || echo "pi")
    if id "$default_user" &>/dev/null && ! groups "$default_user" | grep -q docker; then
        usermod -aG docker "$default_user"
        ok "Added '${default_user}' to the docker group."
    fi

    systemctl enable --quiet docker
    systemctl start docker
    ok "Docker is running and set to start on boot."
}

# ── Step 4 — Mount the NAS via NFS ───────────────────────────────────────────

mount_nas() {
    say "Connecting to your NAS over NFS..."

    # Create the share mount point (subdirs are just filesystem paths within it)
    mkdir -p "${NAS_SHARE_MOUNT}"

    # Add a single fstab entry — idempotent via marker comment
    if grep -q "$FSTAB_MARKER" /etc/fstab 2>/dev/null; then
        ok "NAS mount entry already exists in /etc/fstab — leaving it alone."
    else
        cat >> /etc/fstab <<EOF

${FSTAB_MARKER}
${NAS_HOST}:${NAS_EXPORT}  ${NAS_SHARE_MOUNT}  nfs  rw,nfsvers=3,nofail,_netdev,x-systemd.automount,timeo=30,retrans=3  0  0
EOF
        ok "Added NAS mount to /etc/fstab (will reconnect automatically on reboot)."
    fi

    # Attempt to mount now
    if mountpoint -q "${NAS_SHARE_MOUNT}"; then
        ok "${NAS_SHARE_MOUNT} is already mounted."
    else
        mount "${NAS_SHARE_MOUNT}" 2>/dev/null \
            && ok "Mounted ${NAS_SHARE_MOUNT}." \
            || true
    fi

    # Verify the share is accessible
    if ! mountpoint -q "${NAS_SHARE_MOUNT}"; then
        die "Could not mount the NAS share (${NAS_HOST}:${NAS_EXPORT}).

       Things to check on your NAS (QNAP):
         • Is NFS enabled?  (Control Panel → Network & File Services → NFS Service)
         • Is 'nas-storage' configured as an NFS export and does it allow this Pi's IP?
           (File Station → right-click 'nas-storage' → Properties → NFS Host Access)
         • Can the Pi reach the NAS?  Run:  ping ${NAS_HOST}
         • Is the export path correct? QNAP exports are usually /share/<foldername>
           Current value: ${NAS_EXPORT}

       Fix the issue and run this script again."
    fi

    # Verify expected subdirectories exist within the share
    if [[ ! -d "${NAS_MUSIC_MOUNT}" ]]; then
        warn "Music subdirectory not found at ${NAS_MUSIC_MOUNT}."
        warn "Creating it now — make sure your music files are placed there."
        mkdir -p "${NAS_MUSIC_MOUNT}"
    fi

    if [[ ! -d "${NAS_BACKUP_MOUNT}" ]]; then
        ok "Backup subdirectory not found — creating ${NAS_BACKUP_MOUNT}."
        mkdir -p "${NAS_BACKUP_MOUNT}"
    fi

    ok "NAS is mounted and accessible at ${NAS_SHARE_MOUNT}."
}

# ── Step 5 — Download config from GitHub ─────────────────────────────────────

pull_config() {
    say "Downloading the latest configuration from GitHub..."

    local raw_base="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}"
    mkdir -p "${APP_DIR}"

    for filename in "compose.yml" "navidrome.toml"; do
        local url="${raw_base}/${filename}"
        local dest="${APP_DIR}/${filename}"
        local tmp="${dest}.tmp"

        if curl -fsSL "$url" -o "$tmp" 2>/dev/null; then
            if [[ -f "$dest" ]] && cmp -s "$dest" "$tmp"; then
                ok "${filename} is already up to date."
                rm -f "$tmp"
            else
                mv "$tmp" "$dest"
                ok "Downloaded latest ${filename}."
            fi
        else
            rm -f "$tmp"
            if [[ -f "$dest" ]]; then
                warn "Could not reach GitHub — using the existing copy of ${filename}."
            else
                die "Could not download ${filename} from GitHub.
       URL: ${url}
       Check that GITHUB_REPO='${GITHUB_REPO}' is correct and the file is committed."
            fi
        fi
    done

    # Replace {{PLACEHOLDERS}} in compose.yml with runtime values
    sed -i \
        -e "s|{{NAS_MUSIC_MOUNT}}|${NAS_MUSIC_MOUNT}|g" \
        -e "s|{{NAS_BACKUP_MOUNT}}|${NAS_BACKUP_MOUNT}|g" \
        -e "s|{{NAVIDROME_DATA_DIR}}|${NAVIDROME_DATA_DIR}|g" \
        -e "s|{{NAVIDROME_PORT}}|${NAVIDROME_PORT}|g" \
        -e "s|{{CLOUDFLARE_TUNNEL_TOKEN}}|${CLOUDFLARE_TUNNEL_TOKEN}|g" \
        "${APP_DIR}/compose.yml"

    # Permissions: owned by root:docker, not world-readable
    chown -R root:docker "${APP_DIR}"
    chmod 750 "${APP_DIR}"
    find "${APP_DIR}" -type f -exec chmod 640 {} \;

    ok "Configuration is in place at ${APP_DIR}."
}

# ── Step 6 — Restore Navidrome backup from NAS ───────────────────────────────

restore_backup() {
    say "Checking for a Navidrome backup on the NAS..."

    mkdir -p "${NAVIDROME_DATA_DIR}"
    chown 1000:1000 "${NAVIDROME_DATA_DIR}"

    # Don't restore if data already exists — protect a running installation
    if [[ -f "${NAVIDROME_DATA_DIR}/navidrome.db" ]]; then
        ok "Navidrome database already exists — skipping restore."
        warn "To force a restore, delete ${NAVIDROME_DATA_DIR} and re-run this script."
        return
    fi

    if [[ ! -d "${NAS_BACKUP_MOUNT}" ]]; then
        warn "Backup directory not found on NAS — skipping restore."
        ok "Navidrome will start fresh (your music library on the NAS is untouched)."
        return
    fi

    # Find the most recent backup archive
    local latest_backup=""
    latest_backup=$(find "${NAS_BACKUP_MOUNT}" -maxdepth 2 \
        -name "navidrome_backup_*.tar.gz" 2>/dev/null \
        | sort | tail -n1)

    # Fall back to a plain directory copy if no archive found
    if [[ -z "$latest_backup" && -d "${NAS_BACKUP_MOUNT}/navidrome_data" ]]; then
        latest_backup="${NAS_BACKUP_MOUNT}/navidrome_data"
    fi

    if [[ -z "$latest_backup" ]]; then
        ok "No backup found on the NAS — Navidrome will start fresh."
        ok "(This is completely normal for a first-time setup.)"
        return
    fi

    echo "   Found backup: $(basename "${latest_backup}")"

    if confirm "Restore this backup now? (Recommended if you have used Navidrome before)"; then
        if [[ "$latest_backup" == *.tar.gz ]]; then
            tar -xzf "$latest_backup" -C "${NAVIDROME_DATA_DIR}" --strip-components=1
        else
            rsync -a "${latest_backup}/" "${NAVIDROME_DATA_DIR}/"
        fi
        chown -R 1000:1000 "${NAVIDROME_DATA_DIR}"
        ok "Backup restored successfully."
    else
        ok "Skipped — Navidrome will start fresh."
    fi
}

# ── Step 7 — Start Navidrome via Docker Compose ───────────────────────────────

start_navidrome() {
    say "Starting the Navidrome music server..."

    # Ensure data directory exists with correct UID (matches container user)
    mkdir -p "${NAVIDROME_DATA_DIR}"
    chown -R 1000:1000 "${NAVIDROME_DATA_DIR}"

    cd "${APP_DIR}"

    # Pull latest image (silently skip if offline — cached image will be used)
    if docker compose pull --quiet 2>/dev/null; then
        ok "Pulled latest Navidrome image."
    else
        warn "Could not pull a fresh image — using cached version."
    fi

    docker compose up -d --remove-orphans
    ok "Navidrome container is starting."

    # Wait up to 60 s for the health endpoint to respond
    say "Waiting for Navidrome to be ready..."
    local attempts=0
    local ready=false
    while [[ $attempts -lt 20 ]]; do
        if curl -fs "http://localhost:${NAVIDROME_PORT}/ping" &>/dev/null; then
            ready=true
            break
        fi
        sleep 3
        ((attempts++))
    done

    if $ready; then
        ok "Navidrome is up and responding."
    else
        warn "Navidrome is taking longer than expected to start."
        warn "Give it another minute, then open the web address in your browser."
    fi

    ok "Navidrome will start automatically whenever the Pi is powered on."
}

# ── Step 8 — Final summary ────────────────────────────────────────────────────

print_summary() {
    local ip
    ip=$(hostname -I | awk '{print $1}')

    echo
    echo -e "${GREEN}${BOLD}"
    echo "   ╔══════════════════════════════════════════════════════╗"
    echo "   ║           🎵  Setup complete!  🎵                    ║"
    echo "   ╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "   Open this address in any browser on your network:\n"
    echo -e "   ${BLUE}${BOLD}      http://${ip}:${NAVIDROME_PORT}${NC}\n"
    echo    "   ─────────────────────────────────────────────────────"
    echo    "   If something stops working:"
    echo    "     • Make sure both the Pi and the NAS are turned on"
    echo    "     • Run this setup script again — it is safe to repeat"
    echo    "     • Check what's running:"
    echo    "         sudo docker compose -f ${APP_DIR}/compose.yml ps"
    echo    "     • View recent logs:"
    echo    "         sudo docker compose -f ${APP_DIR}/compose.yml logs --tail=50"
    echo    "   ─────────────────────────────────────────────────────"
    echo    "   Music library  :  ${NAS_MUSIC_MOUNT}"
    echo    "   Navidrome data :  ${NAVIDROME_DATA_DIR}"
    echo    "   Config files   :  ${APP_DIR}"
    echo
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    check_root
    print_banner
    require_internet
    gather_inputs
    update_system
    install_docker
    mount_nas
    pull_config
    restore_backup
    start_navidrome
    print_summary
}

main "$@"