#!/usr/bin/env bash
# fedora_os_update.sh — universal non-interactive OS refresh for Fedora and the
# dnf-based RHEL family, with KDE Plasma specifics. No host-specific assumptions.
#
#   sudo ./fedora_os_update.sh                       # normal run
#   ./fedora_os_update.sh --dry-run                  # plan only, no root, no changes
#   sudo ./fedora_os_update.sh --yes                 # also update global npm packages
#   sudo ./fedora_os_update.sh --firmware            # also flash firmware via fwupdmgr (risky)
#   sudo ./fedora_os_update.sh --prune-docker        # also run docker system prune (deletes!)
#   sudo ./fedora_os_update.sh --release-upgrade --releasever 46   # stage the next release
#
# Design rules:
#   * NO `set -e`: a failed section is recorded and the run continues;
#   * every section is bounded by a timeout (--timeout, 0 = no limit);
#   * nothing destructive by default: prune / firmware / release upgrade are opt-in;
#   * a release upgrade is only STAGED — the reboot is left to the operator unless --reboot;
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
RELEASEVER=""
DO_REBOOT=0
NO_USER_TOOLS=0
TARGET_USER_ARG=""
MIN_FREE_WARN_MB=2048
MIN_FREE_HARD_MB=256
DNF_READY=1
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
$PROG — non-interactive OS refresh for Fedora / dnf-based hosts (KDE aware)

Usage: sudo $PROG [options]

  --dry-run              print the plan, change nothing (works without root)
  --yes, -y              assume yes (affects npm -g)
  --firmware             update firmware via fwupdmgr (physically risky!)
  --prune-docker         docker system prune -f (DELETES stopped containers,
                         unused networks and dangling images)
  --release-upgrade      stage a Fedora release upgrade with dnf system-upgrade
                         (requires --releasever; the reboot stays manual unless --reboot)
  --releasever N         target Fedora release for --release-upgrade, e.g. 46
  --reboot               actually run 'dnf system-upgrade reboot' after staging
  --no-user-tools        do not touch rustup / pipx / npm
  --user NAME            whose user toolchains and KDE cache to update
                         (default: SUDO_USER; under cron without it those are skipped)
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
        --releasever)      shift; RELEASEVER=${1:-} ;;
        --reboot)          DO_REBOOT=1 ;;
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
if ((RELEASE_UPGRADE)); then
    [[ $RELEASEVER =~ ^[0-9]+$ ]] || { printf -- '--release-upgrade needs --releasever N (e.g. --releasever 46)\n' >&2; exit 64; }
fi

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

# Lock: two runs must not fight over the dnf/rpmdb lock.
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

# dnf never prompts for conffiles, but a PAGER or a terminal prompt would stall a
# non-interactive run; a plain environment keeps it non-interactive.
export LC_ALL=C LANG=C
export SYSTEMD_PAGER=cat PAGER=cat

OS_ID=unknown
OS_NAME=unknown
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID=${ID:-unknown}
    OS_NAME=${PRETTY_NAME:-$OS_ID}
fi

# User whose personal toolchains and KDE cache get refreshed.
TARGET_USER=""
if [[ -n "$TARGET_USER_ARG" ]]; then
    TARGET_USER=$TARGET_USER_ARG
elif [[ -n "${SUDO_USER:-}" && ${SUDO_USER} != root ]]; then
    TARGET_USER=$SUDO_USER
elif ((EUID != 0)); then
    TARGET_USER=$(id -un)
fi

# dnf flags: -y everywhere, and never trust a cached metadata set.
declare -a DNF=(dnf -y)

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

# Report-only section: a non-zero exit is not an error (dnf check-update exits 100).
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

# Metadata refresh. A dead repository makes dnf exit non-zero and leaves the cache
# stale, so the failure is reported here instead of surfacing as a mystery later.
dnf_metadata_refresh() {
    local out="" rc=0
    local -a pre=()
    out=$(mktemp) || return 1
    if ((TIMEOUT_S > 0)) && have timeout; then
        pre=(timeout --kill-after=30 "$TIMEOUT_S")
    fi
    ${pre[@]+"${pre[@]}"} "${DNF[@]}" --refresh makecache >"$out" 2>&1 || rc=$?
    tee -a "$LOG_FILE" <"$out"
    # dnf5 keeps exiting 0 on a dead repository and only prints ">>> Curl error (7)"
    # or "Status code: 404" (verified), so a partial failure must be detected here.
    if grep -qE 'Curl error|Failed to download|Cannot download|Status code: [45][0-9][0-9]' "$out"; then
        log "    ${C_Y}[WARN]${C_0} some repositories failed — packages from them will not update"
        [[ $rc -eq 0 ]] && rc=3
    fi
    rm -f "$out"
    return "$rc"
}

# What exactly is going to be upgraded — before applying anything.
dnf_preview() {
    local out="" rc=0
    out=$("${DNF[@]}" --refresh check-update 2>/dev/null) || rc=$?
    if ((rc != 0 && rc != 100)); then
        printf '    check-update failed (exit %d)\n' "$rc"
        return 0
    fi
    printf '%s\n' "$out" | awk '
        /^[A-Za-z0-9._+-]+\.[A-Za-z0-9_]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+$/ {
            n++; if (n <= 20) printf "    %s\n", $1
        }
        END { printf "    total packages: %d\n", n + 0 }'
}

# Packages pinned with dnf versionlock: a frequent answer to "why did nothing update".
dnf_versionlock_report() {
    local out
    if ! "${DNF[@]}" versionlock list >/dev/null 2>&1; then
        printf '    versionlock plugin not available\n'
        return 0
    fi
    out=$("${DNF[@]}" versionlock list 2>/dev/null)
    if [[ -n $out ]]; then
        printf '    locked:\n%s\n' "$out"
    else
        printf '    locked: none\n'
    fi
}

# Running vs newest installed kernel: the fallback reboot check when
# needs-restarting (dnf-plugins-core) is not installed.
newest_kernel() {
    rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V | tail -1
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

if ! have dnf; then
    DNF_READY=0
    skip "dnf not available on this host — nothing to update"
fi

if ((DNF_READY)); then
    ROOT_FREE=$(free_mb /)
    BOOT_FREE=$(free_mb /boot)
    BOOT_FREE=${BOOT_FREE:-0}
    log "    /: ${ROOT_FREE:-?}MB free, /boot: ${BOOT_FREE}MB"
    if [[ ${ROOT_FREE:-0} -lt $MIN_FREE_HARD_MB ]]; then
        DNF_READY=0
        skip "less than ${MIN_FREE_HARD_MB}MB free on / — dnf sections skipped (rpmdb could be damaged)"
    elif [[ ${ROOT_FREE:-0} -lt $MIN_FREE_WARN_MB ]]; then
        log "    ${C_Y}[WARN]${C_0} low free space on / (${ROOT_FREE}MB) — the upgrade may not fit"
    fi
fi

# A broken rpmdb makes every dnf call fail — detect it, do not silently rebuild it.
if ((DNF_READY)); then
    if rpm -q rpm >/dev/null 2>&1; then
        log "    rpmdb: readable"
    else
        log "    ${C_Y}[WARN]${C_0} rpmdb looks damaged — run 'rpm --rebuilddb' manually first"
    fi
fi

# KDE Plasma version, recorded so the run can tell whether the session must restart.
kde_version() {
    rpm -q --qf '%{VERSION}-%{RELEASE}\n' plasma-workspace 2>/dev/null || printf 'not installed\n'
}
KDE_BEFORE=$(kde_version)

# -------------------------------------------------------------------- dnf ----

if ((DNF_READY)); then
    log "    KDE Plasma: ${KDE_BEFORE%%-*}"

    step "DNF: metadata refresh" dnf_metadata_refresh

    report_fn "DNF: pending updates" dnf_preview

    step "DNF: upgrade" "${DNF[@]}" --refresh upgrade
    step "DNF: autoremove" "${DNF[@]}" autoremove
    step "DNF: cache cleanup" "${DNF[@]}" clean all

    report_fn "DNF: versionlocked packages" dnf_versionlock_report
else
    skip "DNF: metadata refresh"
    skip "DNF: upgrade"
fi

# ------------------------------------------------------- package managers ----

if have flatpak; then
    step "Flatpak: update" flatpak update -y
    step "Flatpak: remove unused" flatpak uninstall --unused -y
else
    skip "Flatpak: update"
fi

if have snap; then
    step "Snap: refresh" snap refresh
else
    skip "Snap: refresh"
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

# -------------------------------------------------------------- KDE Plasma ---

# KDE applications ship both as RPMs (Plasma, KF6 apps) and as Flatpaks; RPMs and
# Flatpaks are handled above, so what remains is refreshing the desktop caches and
# telling the operator whether the running session is now stale.
if have rpm && rpm -q plasma-workspace >/dev/null 2>&1; then
    if ((DRY_RUN)); then
        section "KDE: session cache refresh"
        log "    [dry-run] would run: rebuild the KDE service cache for ${TARGET_USER:-the session user}"
        SUMMARY_DRY+=("KDE: session cache refresh")
    elif [[ -n $TARGET_USER ]]; then
        if as_user_login "$TARGET_USER" bash -c 'command -v kbuildsycoca6' >/dev/null 2>&1; then
            step "KDE: service cache refresh (kbuildsycoca6)" \
                as_user_login "$TARGET_USER" kbuildsycoca6 --noincremental
        elif as_user_login "$TARGET_USER" bash -c 'command -v kbuildsycoca5' >/dev/null 2>&1; then
            step "KDE: service cache refresh (kbuildsycoca5)" \
                as_user_login "$TARGET_USER" kbuildsycoca5 --noincremental
        else
            skip "KDE: kbuildsycoca not installed"
        fi
    else
        skip "KDE: cache refresh (no session user determined, pass --user NAME)"
    fi

    KDE_AFTER=$(kde_version)
    if [[ $KDE_BEFORE != "$KDE_AFTER" ]]; then
        log "    ${C_Y}Plasma was upgraded (${KDE_BEFORE%%-*} -> ${KDE_AFTER%%-*}) —"
        log "    ${C_Y}log out and back in (or reboot) to load the new session${C_0}"
    else
        log "    Plasma unchanged (${KDE_AFTER%%-*}) — session restart not required"
    fi
else
    skip "KDE (plasma-workspace not installed)"
fi

# ------------------------------------------------------ kernel and loader ----

# Fedora boots through Boot Loader Specification entries that dnf regenerates on
# every kernel install, so grub2-mkconfig is intentionally NOT run here.
if have rpm; then
    report "Kernel: installed images" bash -c \
        'rpm -q kernel --qf "%{VERSION}-%{RELEASE}.%{ARCH}\n" 2>/dev/null | sort -V | sed "s/^/    /"; echo "    running: $(uname -r)"'
else
    skip "Kernel: report (rpm not available)"
fi

# -------------------------------------------------------- release upgrade ----

if ((RELEASE_UPGRADE)); then
    if ! have dnf; then
        skip "Release upgrade (dnf not available)"
    elif ! dnf system-upgrade --help >/dev/null 2>&1; then
        skip "Release upgrade (dnf-plugin-system-upgrade not installed)"
    else
        log "    staging a Fedora release upgrade to version ${RELEASEVER}"
        step "Release upgrade: download to ${RELEASEVER}" \
            "${DNF[@]}" system-upgrade download --releasever "$RELEASEVER"
        if ((DO_REBOOT)); then
            log "    ${C_Y}rebooting into the staged upgrade now (--reboot)${C_0}"
            step "Release upgrade: reboot into offline transaction" \
                "${DNF[@]}" system-upgrade reboot
        else
            skip "Release upgrade: reboot (staged — run 'sudo dnf system-upgrade reboot' when ready)"
        fi
    fi
else
    skip "Release upgrade (needs --release-upgrade --releasever N)"
fi

# ------------------------------------------------------- post-update checks --

section "Post-update checks"
if ((DRY_RUN)); then
    log "    [dry-run] checks skipped"
else
    if ((DNF_READY)) && have dnf; then
        check_rc=0
        "${DNF[@]}" check-upgrade >/dev/null 2>&1 || check_rc=$?
        # dnf exits 100 when updates are available — that is not an error.
        if ((check_rc == 0 || check_rc == 100)); then
            log "    dnf: dependency state is consistent"
        else
            log "    ${C_R}[FAIL]${C_0} dnf check-upgrade reported a problem (exit $check_rc)"
            SUMMARY_FAIL+=("dnf check-upgrade")
        fi
    fi

    # needs-restarting ships in dnf-plugins-core and is the authoritative answer.
    REBOOT_NEEDED=""
    if have needs-restarting; then
        if ! needs-restarting -r >/dev/null 2>&1; then
            REBOOT_NEEDED=1
        fi
    else
        NEWEST=$(newest_kernel)
        if [[ -n $NEWEST && $NEWEST != "$(uname -r)" ]]; then
            REBOOT_NEEDED=1
        fi
    fi
    if [[ -n $REBOOT_NEEDED ]]; then
        log "    ${C_Y}reboot required${C_0} (newer kernel or core libraries are installed)"
    else
        log "    reboot not required"
    fi

    if have needs-restarting; then
        SVC=$(needs-restarting -s 2>/dev/null | wc -l)
        if [[ ${SVC:-0} -gt 0 ]]; then
            log "    ${C_Y}services running with old libraries: $SVC (needs-restarting -s)${C_0}"
        else
            log "    no service restarts needed"
        fi
    fi

    if have systemctl && systemctl list-units >/dev/null 2>&1; then
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
    log "${C_R}Interrupted by a signal${C_0} — a dnf transaction may need 'dnf history rollback'"
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
