#!/bin/bash
# sudo bash ubuntu_os_update.sh
# sudo bash ubuntu_os_update.sh --release-upgrade
set -uo pipefail

LOGFILE="/var/log/ubuntu_os_update_$(date +%Y%m%d_%H%M%S).log"
RELEASE_UPGRADE=false

for arg in "$@"; do
    case "$arg" in
        --release-upgrade) RELEASE_UPGRADE=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

declare -a SUCCESSES=()
declare -a SKIPPED=()
declare -a FAILURES=()

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg" | tee -a "$LOGFILE" 2>/dev/null
}

section() {
    log "${GREEN}==> $1${NC}"
}

warn() {
    log "${YELLOW}    [SKIP] $1${NC}"
}

fail() {
    log "${RED}    [FAIL] $1${NC}"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

run_section() {
    local name="$1"
    shift
    section "$name"
    if "$@"; then
        SUCCESSES+=("$name")
    else
        fail "$name"
        FAILURES+=("$name")
    fi
}

skip_section() {
    warn "$1 — $2 not found, skipping."
    SKIPPED+=("$1")
}

# --- Pre-flight check ---

if ! sudo -v 2>/dev/null; then
    echo -e "${RED}Error: sudo access is required. Exiting.${NC}"
    exit 1
fi

log "Update started. Log: $LOGFILE"

# --- APT ---

run_section "APT update & upgrade" bash -c \
    'sudo apt-get update -y && sudo apt-get upgrade -y && sudo apt-get dist-upgrade -y'

run_section "APT cleanup" bash -c \
    'sudo apt-get autoremove -y && sudo apt-get autoclean -y'

# --- Snap ---

if command_exists snap; then
    run_section "Snap refresh" sudo snap refresh
else
    skip_section "Snap refresh" "snap"
fi

# --- Flatpak ---

if command_exists flatpak; then
    run_section "Flatpak update" flatpak update -y
else
    skip_section "Flatpak update" "flatpak"
fi

# --- Firmware ---

if command_exists fwupdmgr; then
    run_section "Firmware update" bash -c \
        'sudo fwupdmgr refresh --force 2>/dev/null; sudo fwupdmgr update -y 2>/dev/null'
else
    skip_section "Firmware update" "fwupdmgr"
fi

# --- Docker ---

if command_exists docker; then
    run_section "Docker prune" sudo docker system prune -f

    section "Docker image pull"
    mapfile -t images < <(sudo docker images --format '{{.Repository}}:{{.Tag}}' \
        | grep -v '<none>' | sort -u)
    if [[ ${#images[@]} -gt 0 ]]; then
        docker_ok=true
        for img in "${images[@]}"; do
            log "    Pulling $img"
            if ! sudo docker pull "$img"; then
                fail "Failed to pull $img"
                docker_ok=false
            fi
        done
        $docker_ok && SUCCESSES+=("Docker image pull") || FAILURES+=("Docker image pull")
    else
        warn "No Docker images to update."
        SKIPPED+=("Docker image pull")
    fi
else
    skip_section "Docker update" "docker"
fi

# --- Rust ---

if command_exists rustup; then
    run_section "Rust update" rustup update
else
    skip_section "Rust update" "rustup"
fi

# --- Node.js / npm ---

if command_exists npm; then
    run_section "npm global update" bash -c \
        'sudo npm install -g npm && sudo npm update -g'
else
    skip_section "npm global update" "npm"
fi

# --- Kernel / GRUB (only when the tools exist) ---

if command_exists update-initramfs; then
    run_section "Rebuild initramfs" sudo update-initramfs -u
else
    skip_section "Rebuild initramfs" "update-initramfs"
fi

if command_exists update-grub; then
    run_section "Update GRUB" sudo update-grub
else
    skip_section "Update GRUB" "update-grub"
fi

# --- Ubuntu release upgrade (opt-in only) ---

if $RELEASE_UPGRADE; then
    if command_exists do-release-upgrade; then
        if sudo do-release-upgrade -c 2>/dev/null | grep -q "New release"; then
            run_section "Ubuntu release upgrade" \
                sudo do-release-upgrade -f DistUpgradeViewNonInteractive
        else
            log "Already on the latest Ubuntu release."
            SKIPPED+=("Ubuntu release upgrade")
        fi
    else
        skip_section "Ubuntu release upgrade" "do-release-upgrade"
    fi
else
    log "Release upgrade skipped (pass --release-upgrade to enable)."
    SKIPPED+=("Ubuntu release upgrade")
fi

# --- Reboot check ---

echo ""
if [ -f /var/run/reboot-required ]; then
    log "${YELLOW}Reboot is required to finish applying updates.${NC}"
else
    log "No reboot required."
fi

# --- Summary ---

echo ""
log "${GREEN}===== Update Summary =====${NC}"
[[ ${#SUCCESSES[@]} -gt 0 ]] && log "${GREEN}  Succeeded: ${SUCCESSES[*]}${NC}"
[[ ${#SKIPPED[@]}  -gt 0 ]] && log "${YELLOW}  Skipped:   ${SKIPPED[*]}${NC}"
[[ ${#FAILURES[@]} -gt 0 ]] && log "${RED}  Failed:    ${FAILURES[*]}${NC}"
echo ""
log "Full log: $LOGFILE"

[[ ${#FAILURES[@]} -gt 0 ]] && exit 1
exit 0
