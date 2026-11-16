#!/usr/bin/env bash
# ubuntu_os_update.sh — universal non-interactive OS refresh for apt-based hosts
# (Ubuntu / Debian / Kali and derivatives). No host-specific assumptions.
#
#   sudo ./ubuntu_os_update.sh                       # normal run
#   ./ubuntu_os_update.sh --dry-run                  # plan only, no root, no changes
#   sudo ./ubuntu_os_update.sh --yes                 # also update global npm packages
#   sudo ./ubuntu_os_update.sh --firmware            # also flash firmware via fwupdmgr (risky)
#   sudo ./ubuntu_os_update.sh --prune-docker        # also run docker system prune (deletes!)
#   sudo ./ubuntu_os_update.sh --release-upgrade     # Ubuntu: next release (needs --yes)
#                                                    # Kali: rolling dist-upgrade
#
# Design rules:
#   * NO `set -e`: a failed section is recorded and the run continues;
#   * every section is bounded by a timeout (--timeout, 0 = no limit);
#   * nothing destructive by default: prune / firmware / release upgrade are opt-in;
#   * the final summary lists what was updated, skipped, failed and whether a reboot is due.
#
# Exit codes: 0 all good; 1 some sections failed; 2 preconditions not met;
#             64 bad usage; 75 another run holds the lock; 130 interrupted by a signal.
set -uo pipefail

PROG=${0##*/}
TIMEOUT_S=2400
KEEP_LOGS=20
DRY_RUN=0
ASSUME_YES=0
DO_FIRMWARE=0
PRUNE_DOCKER=0
RELEASE_UPGRADE=0
NO_USER_TOOLS=0
TARGET_USER_ARG=""
MIN_FREE_WARN_MB=2048
MIN_FREE_HARD_MB=256
APT_READY=1
LOG_DIR=""
LOG_FILE=""

declare -a SUMMARY_OK=()
declare -a SUMMARY_DRY=()
declare -a SUMMARY_SKIP=()
declare -a SUMMARY_FAIL=()

# -------------------------------------------------------------------- args ---

ORIG_ARGS=("$@")
usage() {
    cat <<EOF
$PROG — non-interactive OS refresh for apt-based hosts (Ubuntu/Debian/Kali)

Usage: sudo $PROG [options]

  --dry-run              print the plan, change nothing (works without root)
  --yes, -y              assume yes (affects npm -g and the Ubuntu release upgrade)
  --firmware             update firmware via fwupdmgr (physically risky!)
  --prune-docker         docker system prune -f (DELETES stopped containers,
                         unused networks and dangling images)
  --release-upgrade      Ubuntu: do-release-upgrade to the next release (needs --yes)
                         Kali:   rolling release upgrade via apt dist-upgrade
  --no-user-tools        do not touch rustup / pipx / npm
  --user NAME            whose user toolchains to update
                         (default: SUDO_USER; under cron without it the section is skipped)
  --timeout SEC          per-section limit, 0 = unlimited (default $TIMEOUT_S)
  --keep N               how many logs to keep in /var/log, 0 = all (default $KEEP_LOGS)
  -h, --help             this help

Exit codes: 0 ok, 1 some sections failed, 2 preconditions not met,
            64 bad usage, 75 another run holds the lock, 130 interrupted.
EOF
}

while (($#)); do
    case "$1" in
        --dry-run)         DRY_RUN=1 ;;
        --yes|-y)          ASSUME_YES=1 ;;
        --firmware)        DO_FIRMWARE=1 ;;
        --prune-docker)    PRUNE_DOCKER=1 ;;
        --release-upgrade) RELEASE_UPGRADE=1 ;;
        --no-user-tools)   NO_USER_TOOLS=1 ;;
        --user)            shift; TARGET_USER_ARG=${1:-} ;;
        --timeout)         shift; TIMEOUT_S=${1:-} ;;
        --keep)            shift; KEEP_LOGS=${1:-} ;;
        -h|--help)         usage; exit 0 ;;
        *) printf 'Unknown option: %s (see --help)\n' "$1" >&2; exit 64 ;;
    esac
    shift
done

[[ $TIMEOUT_S =~ ^[0-9]+$ ]] || { printf -- '--timeout: a number is required\n' >&2; exit 64; }
[[ $KEEP_LOGS =~ ^[0-9]+$ ]] || { printf -- '--keep: a number is required\n' >&2; exit 64; }

# ------------------------------------------------------------ preconditions --

have() { command -v "$1" >/dev/null 2>&1; }

# Not root: re-exec ourselves through sudo. --dry-run needs no privileges.
if ((EUID != 0)) && ((DRY_RUN == 0)); then
    if ! have sudo; then
        printf 'Root privileges required and sudo is not installed. Run as root.\n' >&2
        exit 2
    fi
    printf 'Re-executing through sudo...\n' >&2
    exec sudo -- bash "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
fi

# Log directory: /var/log as root, otherwise TMPDIR (for --dry-run).
if ((EUID == 0)) && [[ -d /var/log && -w /var/log ]]; then
    LOG_DIR=/var/log
else
    LOG_DIR=${TMPDIR:-/tmp}
fi
LOG_FILE="$LOG_DIR/${PROG%.sh}_$(date +%Y%m%d_%H%M%S).log"
: >"$LOG_FILE" 2>/dev/null || { printf 'Cannot write to %s\n' "$LOG_DIR" >&2; exit 2; }
chmod 600 "$LOG_FILE" 2>/dev/null || true

# Lock: two runs must not fight over the dpkg lock.
if ((EUID == 0)) && have flock; then
    LOCK_FILE=/run/${PROG%.sh}.lock
    [[ -d /run ]] || LOCK_FILE=/var/lock/${PROG%.sh}.lock
    exec 9>"$LOCK_FILE" 2>/dev/null || true
    if ! flock -n 9; then
        printf 'Another run is already in progress (%s). Exiting.\n' "$LOCK_FILE" >&2
        exit 75
    fi
fi

if [[ -t 1 ]] && ((DRY_RUN == 0)); then
    C_G=$'\033[0;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[0;31m'; C_0=$'\033[0m'
else
    C_G=""; C_Y=""; C_R=""; C_0=""
fi

log()     { printf '%s\n' "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
section() { log "${C_G}==> $*${C_0}"; }

# -------------------------------------------------------------- environment --

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export LC_ALL=C LANG=C

OS_ID=unknown
OS_NAME=unknown
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID=${ID:-unknown}
    OS_NAME=${PRETTY_NAME:-$OS_ID}
fi

# Human-readable current release; re-read after an upgrade.
os_release_name() {
    if [[ -r /etc/os-release ]]; then
        ( # shellcheck disable=SC1091
          . /etc/os-release; printf '%s\n' "${PRETTY_NAME:-${ID:-unknown}}" )
    else
        printf 'unknown\n'
    fi
}

# User whose personal toolchains get updated.
TARGET_USER=""
if [[ -n "$TARGET_USER_ARG" ]]; then
    TARGET_USER=$TARGET_USER_ARG
elif [[ -n "${SUDO_USER:-}" && ${SUDO_USER} != root ]]; then
    TARGET_USER=$SUDO_USER
elif ((EUID != 0)); then
    TARGET_USER=$(id -un)
fi

# apt flags: without them the run hangs on conffile prompts and in a non-tty.
declare -a APT=(
    apt-get -y
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
    -o Dpkg::Use-Pty=0
    -o Acquire::Retries=3
    -o DPkg::Lock::Timeout=120
)

free_mb() { df -Pm "$1" 2>/dev/null | awk 'NR==2{print $4}'; }

# --------------------------------------------------------------- execution ---

# Run a command: output goes to the console and to the log, exit code preserved.
run_capture() {
    local -a pre=()
    # timeout cannot run shell functions — those apply the limit themselves.
    if ((TIMEOUT_S > 0)) && have timeout && ! declare -F "$1" >/dev/null 2>&1; then
        pre=(timeout --kill-after=30 "$TIMEOUT_S")
    fi
    ${pre[@]+"${pre[@]}"} "$@" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
}

# A section whose failure must NOT abort the run. Always returns 0.
step() {
    local name=$1; shift
    section "$name"
    if ((DRY_RUN)); then
        log "    [dry-run] would run: $name"
        SUMMARY_DRY+=("$name")
        return 0
    fi
    local t0=$SECONDS rc=0
    run_capture "$@" || rc=$?
    if ((rc == 0)); then
        log "    ${C_G}[ OK ]${C_0} $name ($((SECONDS - t0))s)"
        SUMMARY_OK+=("$name")
    elif ((rc == 124 || rc == 137)); then
        log "    ${C_R}[FAIL]${C_0} $name — timed out after ${TIMEOUT_S}s, continuing"
        SUMMARY_FAIL+=("$name (timeout)")
    else
        log "    ${C_R}[FAIL]${C_0} $name — exit $rc, continuing"
        SUMMARY_FAIL+=("$name (exit $rc)")
    fi
    return 0
}

# Report-only section: a non-zero exit is not an error (npm/gem behave that way).
report() {
    local name=$1; shift
    section "$name"
    if ((DRY_RUN)); then
        log "    [dry-run] would run: $name"
        SUMMARY_DRY+=("$name")
        return 0
    fi
    run_capture "$@" || true
    return 0
}

skip() {
    log "    ${C_Y}[SKIP]${C_0} $1"
    SUMMARY_SKIP+=("$1")
}

# Report implemented as a shell function (timeout does not apply to functions).
report_fn() {
    local name=$1 fn=$2
    section "$name"
    if ((DRY_RUN)); then
        log "    [dry-run] would run: $name"
        SUMMARY_DRY+=("$name")
        return 0
    fi
    "$fn" 2>&1 | tee -a "$LOG_FILE" || true
    return 0
}

# Index refresh. apt-get update returns 0 even when some sources fail to
# download (verified), so that case is promoted to a section failure.
apt_index_refresh() {
    local out="" rc=0
    local -a pre=()
    out=$(mktemp) || return 1
    if ((TIMEOUT_S > 0)) && have timeout; then
        pre=(timeout --kill-after=30 "$TIMEOUT_S")
    fi
    ${pre[@]+"${pre[@]}"} "${APT[@]}" --allow-releaseinfo-change update >"$out" 2>&1 || rc=$?
    tee -a "$LOG_FILE" <"$out"
    if grep -q 'Some index files failed to download' "$out"; then
        log "    ${C_Y}[WARN]${C_0} some indexes failed to download — nothing will be updated from those repos"
        [[ $rc -eq 0 ]] && rc=3
    fi
    rm -f "$out"
    return "$rc"
}

# What exactly is going to be upgraded — before applying anything.
apt_preview() {
    "${APT[@]}" -s full-upgrade 2>/dev/null | awk '
        /^Inst / { n++; if (n <= 20) printf "    %s\n", $2 }
        END      { printf "    total packages: %d\n", n + 0 }'
}

# Packages pinned with apt-mark hold: a frequent answer to "why did nothing update".
apt_holds() {
    local h=""
    h=$(apt-mark showhold 2>/dev/null | tr '\n' ' ')
    if [[ -n $h ]]; then
        printf '    held: %s\n' "$h"
    else
        printf '    held: none\n'
    fi
}

# Run a command as the target user; login shell for PATH-dependent toolchains.
as_user() {
    local u=$1; shift
    [[ -n $u ]] || return 127
    if [[ $(id -un) == "$u" ]]; then
        "$@"; return $?
    fi
    if have sudo; then
        sudo -H -u "$u" -- "$@"
    elif have runuser; then
        runuser -u "$u" -- "$@"
    else
        return 127
    fi
}

as_user_login() {
    local u=$1; shift
    local cmd=""
    local -a pre=()
    printf -v cmd '%q ' "$@"
    if ((TIMEOUT_S > 0)) && have timeout; then
        pre=(timeout --kill-after=30 "$TIMEOUT_S")
    fi
    as_user "$u" ${pre[@]+"${pre[@]}"} bash -lc "$cmd"
}

# --------------------------------------------------------------- pre-flight --

log "${C_G}${PROG}${C_0} — log: $LOG_FILE"
if ((DRY_RUN)); then
    log "${C_Y}DRY-RUN: nothing will be changed${C_0}"
fi
log "System: $OS_NAME ($OS_ID), kernel $(uname -r)"
log "Toolchain user: ${TARGET_USER:-not determined}"

section "Environment checks"

if ! have apt-get; then
    APT_READY=0
    skip "apt not available on this host — nothing to update"
fi

if ((APT_READY)); then
    ROOT_FREE=$(free_mb /)
    BOOT_FREE=$(free_mb /boot)
    BOOT_FREE=${BOOT_FREE:-0}
    log "    /: ${ROOT_FREE:-?}MB free, /boot: ${BOOT_FREE}MB"
    if [[ ${ROOT_FREE:-0} -lt $MIN_FREE_HARD_MB ]]; then
        APT_READY=0
        skip "less than ${MIN_FREE_HARD_MB}MB free on / — apt sections skipped (dpkg could be damaged)"
    elif [[ ${ROOT_FREE:-0} -lt $MIN_FREE_WARN_MB ]]; then
        log "    ${C_Y}[WARN]${C_0} low free space on / (${ROOT_FREE}MB) — the upgrade may not fit"
    fi
fi

# A half-configured dpkg breaks every apt call — repair it up front.
if ((APT_READY)); then
    if [[ -n "$(dpkg --audit 2>/dev/null)" ]]; then
        log "    ${C_Y}dpkg is in an unfinished state — repairing${C_0}"
        step "dpkg repair" dpkg --configure -a
        step "dependency repair" "${APT[@]}" -f install
    else
        log "    dpkg: clean"
    fi
fi

# -------------------------------------------------------------------- apt ----

if ((APT_READY)); then
    step "APT: index refresh" apt_index_refresh

    report_fn "APT: pending upgrades" apt_preview

    step "APT: full-upgrade" "${APT[@]}" full-upgrade
    step "APT: autoremove --purge" "${APT[@]}" autoremove --purge
    step "APT: cache cleanup" "${APT[@]}" clean

    report_fn "APT: held packages" apt_holds
else
    skip "APT: index refresh"
    skip "APT: full-upgrade"
fi

# ------------------------------------------------------- package managers ----

if have snap; then
    step "Snap: refresh" snap refresh
else
    skip "Snap: refresh"
fi

if have flatpak; then
    step "Flatpak: update" flatpak update -y
    step "Flatpak: remove unused" flatpak uninstall --unused -y
else
    skip "Flatpak: update"
fi

if ((DO_FIRMWARE)); then
    if have fwupdmgr; then
        step "Firmware: refresh" fwupdmgr refresh --force
        step "Firmware: update" fwupdmgr update -y
    else
        skip "Firmware (fwupdmgr not installed)"
    fi
else
    skip "Firmware (needs --firmware)"
fi

# ----------------------------------------------------------------- docker ----

if have docker && docker info >/dev/null 2>&1; then
    if ((PRUNE_DOCKER)); then
        step "Docker: system prune" docker system prune -f
    else
        skip "Docker: system prune (needs --prune-docker)"
    fi

    # Images without a registry host are local builds: pulling them is pointless.
    if ((DRY_RUN)); then
        section "Docker: image refresh"
        log "    [dry-run] would run: pull images that live in a registry"
        SUMMARY_DRY+=("Docker: image refresh")
    else
        section "Docker: image refresh"
        declare -a imgs=()
        mapfile -t imgs < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
            | grep -v '<none>' | grep '/' | sort -u)
        pulled=0; skipped_local=0; failed=0
        for img in ${imgs[@]+"${imgs[@]}"}; do
            case "$img" in
                *@sha256:*|sha256:*) skipped_local=$((skipped_local + 1)); continue ;;
            esac
            if run_capture docker pull "$img"; then
                pulled=$((pulled + 1))
            else
                failed=$((failed + 1))
                log "    ${C_Y}[WARN]${C_0} could not refresh $img (tag removed / local build)"
            fi
        done
        log "    images: refreshed $pulled, local/skipped $skipped_local, failed $failed"
        if ((pulled > 0 || failed == 0)); then
            SUMMARY_OK+=("Docker: image refresh")
        else
            SUMMARY_FAIL+=("Docker: image refresh (0 of $failed)")
        fi
    fi

    # Compose stacks: pull by config file. Without -f compose cannot find the
    # project ("no configuration file provided") — verified. Services are not restarted.
    if docker compose version >/dev/null 2>&1; then
        if ((DRY_RUN)); then
            section "Docker Compose: image refresh"
            log "    [dry-run] would run: compose pull for running projects"
            SUMMARY_DRY+=("Docker Compose: image refresh")
        else
            declare -a cfgs=()
            mapfile -t cfgs < <(docker compose ls --format json 2>/dev/null \
                | grep -o '"ConfigFiles":"[^"]*"' | sed -e 's/^"ConfigFiles":"//' -e 's/"$//')
            if ((${#cfgs[@]} == 0)); then
                skip "Docker Compose: no running projects"
            fi
            for f in ${cfgs[@]+"${cfgs[@]}"}; do
                case "$f" in
                    *,*) skip "Compose: multiple config files ($f)"; continue ;;
                esac
                if [[ ! -r $f ]]; then
                    log "    ${C_Y}[WARN]${C_0} config not readable: $f"
                    continue
                fi
                step "Docker Compose: pull ${f##*/} (${f%/*})" \
                    docker compose -f "$f" pull --ignore-pull-failures
            done
        fi
    else
        skip "Docker Compose (plugin not installed)"
    fi
else
    skip "Docker (not installed or daemon unreachable)"
fi

# ------------------------------------------------------ user toolchains ------

if ((NO_USER_TOOLS)); then
    skip "User toolchains (--no-user-tools)"
elif [[ -z $TARGET_USER ]]; then
    skip "User toolchains (no user determined: cron without SUDO_USER, pass --user NAME)"
else
    if as_user_login "$TARGET_USER" bash -c 'command -v rustup' >/dev/null 2>&1; then
        step "rustup update" as_user_login "$TARGET_USER" rustup update
    else
        skip "rustup (not installed)"
    fi

    if as_user_login "$TARGET_USER" bash -c 'command -v pipx' >/dev/null 2>&1; then
        step "pipx upgrade-all" as_user_login "$TARGET_USER" pipx upgrade-all
    else
        skip "pipx (not installed)"
    fi

    if as_user_login "$TARGET_USER" bash -c 'command -v npm' >/dev/null 2>&1; then
        report "npm: outdated (global)" \
            as_user_login "$TARGET_USER" bash -c 'npm outdated -g --depth=0 || true'
        if ((ASSUME_YES)); then
            # The npm prefix usually belongs to root, so a user-level update fails
            # with EACCES; under root we update as root when npm is on its PATH.
            if ((EUID == 0)) && [[ $TARGET_USER != root ]] && have npm; then
                step "npm update -g" npm update -g
            else
                step "npm update -g" as_user_login "$TARGET_USER" npm update -g
            fi
        else
            skip "npm update -g (needs --yes)"
        fi
    else
        skip "npm (not installed)"
    fi
fi

# ------------------------------------------------------ kernel and loader ----

if have update-initramfs; then
    step "initramfs: rebuild (all kernels)" update-initramfs -u -k all
else
    skip "initramfs (update-initramfs not installed)"
fi

if have update-grub; then
    step "GRUB: update config" env GRUB_DISABLE_OS_PROBER=true update-grub
else
    skip "GRUB (update-grub not installed)"
fi

# -------------------------------------------------------- release upgrade ----

if ((RELEASE_UPGRADE)); then
    case "$OS_ID" in
        kali)
            # Kali has no do-release-upgrade: it is a rolling release, so the
            # supported release upgrade is a full dist-upgrade against kali-rolling.
            log "    Kali is a rolling release — using apt dist-upgrade instead of do-release-upgrade"
            if have kali-check-apt-sources; then
                report "Kali: APT sources sanity check" kali-check-apt-sources
            else
                skip "Kali: APT sources sanity check (kali-check-apt-sources not installed)"
            fi
            step "Kali: index refresh" apt_index_refresh
            step "Kali: dist-upgrade (rolling release)" "${APT[@]}" dist-upgrade
            if ((DRY_RUN == 0)); then
                log "    release after upgrade: $(os_release_name)"
            fi
            ;;
        *)
            if ! have do-release-upgrade; then
                skip "Release upgrade (do-release-upgrade not installed — not Ubuntu?)"
            elif ((ASSUME_YES == 0)); then
                skip "Release upgrade (needs --yes)"
            else
                if do-release-upgrade -c 2>/dev/null | grep -q 'New release'; then
                    step "Ubuntu release upgrade" do-release-upgrade -f DistUpgradeViewNonInteractive
                    if ((DRY_RUN == 0)); then
                        log "    release after upgrade: $(os_release_name)"
                    fi
                else
                    skip "Release upgrade (no new release available)"
                fi
            fi
            ;;
    esac
else
    skip "Release upgrade (needs --release-upgrade)"
fi

# ------------------------------------------------------- post-update checks --

section "Post-update checks"
if ((DRY_RUN)); then
    log "    [dry-run] checks skipped"
else
    if have apt-get && ((APT_READY)); then
        if apt-get check >/dev/null 2>&1; then
            log "    dpkg/apt: state is consistent"
        else
            log "    ${C_R}[FAIL]${C_0} apt-get check reported problems"
            SUMMARY_FAIL+=("apt-get check")
        fi
    fi

    if [[ -f /var/run/reboot-required ]]; then
        REBOOT_PKGS=""
        [[ -f /var/run/reboot-required.pkgs ]] && REBOOT_PKGS=$(sort -u /var/run/reboot-required.pkgs | tr '\n' ' ')
        log "    ${C_Y}reboot required${C_0}${REBOOT_PKGS:+ (packages: $REBOOT_PKGS)}"
    else
        log "    reboot not required"
    fi

    if have needrestart; then
        if needrestart -b 2>/dev/null | grep -q 'NEEDRESTART-SVC'; then
            log "    ${C_Y}services are running with old libraries (needrestart)${C_0}"
        else
            log "    no service restarts needed"
        fi
    fi

    if have systemctl; then
        FAILED_UNITS=$(systemctl list-units --state=failed --no-legend --no-pager 2>/dev/null | wc -l)
        if [[ ${FAILED_UNITS:-0} -gt 0 ]]; then
            log "    ${C_Y}failed systemd units: $FAILED_UNITS${C_0}"
        else
            log "    no failed systemd units"
        fi
    fi
fi

# ----------------------------------------------------------------- summary ---

print_summary() {
    local rc=$1
    log ""
    log "${C_G}===== SUMMARY =====${C_0}"
    if ((${#SUMMARY_OK[@]})); then
        log "  ${C_G}Succeeded (${#SUMMARY_OK[@]}):${C_0} $(printf '%s, ' ${SUMMARY_OK[@]+"${SUMMARY_OK[@]}"} | sed 's/, $//')"
    fi
    if ((${#SUMMARY_DRY[@]})); then
        log "  ${C_Y}Would run (${#SUMMARY_DRY[@]}):${C_0} $(printf '%s, ' "${SUMMARY_DRY[@]}" | sed 's/, $//')"
    fi
    if ((${#SUMMARY_SKIP[@]})); then
        log "  ${C_Y}Skipped (${#SUMMARY_SKIP[@]}):${C_0} $(printf '%s, ' ${SUMMARY_SKIP[@]+"${SUMMARY_SKIP[@]}"} | sed 's/, $//')"
    fi
    if ((${#SUMMARY_FAIL[@]})); then
        log "  ${C_R}Failed (${#SUMMARY_FAIL[@]}):${C_0} $(printf '%s, ' ${SUMMARY_FAIL[@]+"${SUMMARY_FAIL[@]}"} | sed 's/, $//')"
    fi
    log "  Log: $LOG_FILE"
    log "  Duration: $((SECONDS))s"
    if ((rc == 0)); then
        log "  ${C_G}Result: success${C_0}"
    else
        log "  ${C_R}Result: completed with errors — see the list above${C_0}"
    fi
}

on_signal() {
    log "${C_R}Interrupted by a signal${C_0} — dpkg may need 'dpkg --configure -a'"
    print_summary 1
    exit 130
}
trap on_signal INT TERM

# Log rotation (nothing is deleted in dry-run).
if ((DRY_RUN == 0)) && ((KEEP_LOGS > 0)); then
    # shellcheck disable=SC2012  # log names are generated here: no spaces
    ls -1t "$LOG_DIR/${PROG%.sh}"_*.log 2>/dev/null | tail -n +$((KEEP_LOGS + 1)) \
        | while IFS= read -r old; do rm -f "$old"; done
fi

if ((${#SUMMARY_FAIL[@]})); then
    print_summary 1
    exit 1
fi
print_summary 0
exit 0
