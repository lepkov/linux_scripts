#!/usr/bin/env bash
# deploy_os_update_cron.sh — idempotent deployment of the weekly OS refresh to a
# remote apt host that has no Ansible repository of its own (the Kali VM on the
# Hyper-V Default Switch is the first user).
#
# It copies ubuntu_os_update.sh and ubuntu_os_update_cron.sh over SSH, installs
# the Telegram credentials, writes /etc/cron.d/ubuntu-os-update, removes the
# declared legacy jobs and reads the result back. Every write is guarded by a
# sha256 comparison, so a second run reports changed=0.
#
#   ./deploy_os_update_cron.sh --address 172.26.249.148 --user kali \
#       --host-label "kali (172.26.249.148)" --telegram-env ~/.telegram.env
#
#   ./deploy_os_update_cron.sh ... --legacy-job /etc/cron.weekly/old-update
#
# The schedule is Sunday 05:00 owner time (UTC+5): the script reads the host
# timezone with `date +%z`, refuses to write when it does not match
# --expected-tz and only then installs --cron-spec. Kali keeps the default
# weekly set: --release-upgrade is never passed.
#
# Exit codes: 0 deployed (or already up to date), 1 a check failed, 64 bad usage.
set -uo pipefail

PROG=${0##*/}
ADDRESS=""
SSH_USER=""
SSH_PORT=22
SSH_KEY=""
HOST_LABEL=""
TELEGRAM_ENV=""
EXPECTED_TZ="+0500"
CRON_SPEC="0 5 * * 0"
CRON_FILE=/etc/cron.d/ubuntu-os-update
UPDATE_SCRIPT=/usr/local/sbin/ubuntu_os_update.sh
WRAPPER=/usr/local/sbin/ubuntu_os_update_cron.sh
ENV_FILE=/etc/ubuntu_os_update.env
LEGACY_JOBS=()
SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
    cat <<EOF
$PROG — idempotent deploy of the weekly OS refresh over SSH

Usage: $PROG --address HOST --user NAME --host-label LABEL --telegram-env FILE [options]

  --address HOST       remote host name or IP (required)
  --user NAME          SSH user with passwordless sudo (required)
  --host-label LABEL   host identifier used in the Telegram message (required)
  --telegram-env FILE  local file with TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID (required)
  --cron-spec SPEC     cron expression in the host timezone (default "$CRON_SPEC")
  --expected-tz TZ     expected \`date +%z\` of the host (default "$EXPECTED_TZ")
  --legacy-job PATH    weekly update job to remove (repeatable)
  --ssh-port PORT      SSH port (default $SSH_PORT)
  --ssh-key FILE       private key passed to ssh/scp
  -h, --help           this help

Exit codes: 0 ok, 1 a check failed, 64 bad usage.
EOF
}

while (($#)); do
    case "$1" in
        --address)      shift; ADDRESS=${1:-} ;;
        --user)         shift; SSH_USER=${1:-} ;;
        --host-label)   shift; HOST_LABEL=${1:-} ;;
        --telegram-env) shift; TELEGRAM_ENV=${1:-} ;;
        --cron-spec)    shift; CRON_SPEC=${1:-} ;;
        --expected-tz)  shift; EXPECTED_TZ=${1:-} ;;
        --legacy-job)   shift; LEGACY_JOBS+=("${1:-}") ;;
        --ssh-port)     shift; SSH_PORT=${1:-} ;;
        --ssh-key)      shift; SSH_KEY=${1:-} ;;
        -h|--help)      usage; exit 0 ;;
        *) printf 'Unknown option: %s (see --help)\n' "$1" >&2; exit 64 ;;
    esac
    shift
done

for required in ADDRESS SSH_USER HOST_LABEL TELEGRAM_ENV; do
    [[ -n ${!required} ]] || { printf -- '--%s is required (see --help)\n' \
        "$(printf '%s' "$required" | tr '[:upper:]_' '[:lower:]-')" >&2; exit 64; }
done
[[ $CRON_SPEC =~ ^[0-9*/,-]+\ [0-9*/,-]+\ [0-9*/,-]+\ [0-9*/,-]+\ [0-9*/,-]+$ ]] \
    || { printf -- '--cron-spec: five cron fields are required\n' >&2; exit 64; }
[[ $EXPECTED_TZ =~ ^[+-][0-9]{4}$ ]] \
    || { printf -- '--expected-tz: the +HHMM form is required\n' >&2; exit 64; }
[[ -r $TELEGRAM_ENV ]] || { printf 'Cannot read %s\n' "$TELEGRAM_ENV" >&2; exit 64; }
[[ -f $SOURCE_DIR/ubuntu_os_update.sh && -f $SOURCE_DIR/ubuntu_os_update_cron.sh ]] \
    || { printf 'ubuntu_os_update.sh / ubuntu_os_update_cron.sh are missing next to %s\n' "$PROG" >&2; exit 1; }
bash -n "$SOURCE_DIR/ubuntu_os_update.sh" || { printf 'ubuntu_os_update.sh does not parse\n' >&2; exit 1; }
bash -n "$SOURCE_DIR/ubuntu_os_update_cron.sh" || { printf 'ubuntu_os_update_cron.sh does not parse\n' >&2; exit 1; }

ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -p "$SSH_PORT")
scp_opts=(-q -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -P "$SSH_PORT")
[[ -n $SSH_KEY ]] && ssh_opts+=(-i "$SSH_KEY") && scp_opts+=(-i "$SSH_KEY")
TARGET="$SSH_USER@$ADDRESS"
remote() { ssh "${ssh_opts[@]}" "$TARGET" "$@"; }
push() { scp "${scp_opts[@]}" "$1" "$TARGET:$2"; }

changed=0
fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }

# --- reachability, sudo, timezone ------------------------------------------
remote true 2>/dev/null || fail "cannot reach $TARGET over SSH"
remote 'sudo -n true' 2>/dev/null || fail "$SSH_USER needs passwordless sudo on $ADDRESS"

host_tz=$(remote 'date +%z') || fail 'cannot read the host timezone'
host_tz=${host_tz//[$'\r\n']/}
[[ $host_tz == "$EXPECTED_TZ" ]] || fail \
    "the host runs $host_tz, but the schedule is declared for $EXPECTED_TZ; fix --expected-tz and --cron-spec together"
printf 'timezone: %s (expected %s)\n' "$host_tz" "$EXPECTED_TZ"

# --- scripts ---------------------------------------------------------------
# install_file SRC DEST MODE — copy only when the sha256 differs.
install_file() {
    local src=$1 dest=$2 mode=$3 want got
    want=$(sha256sum "$src" | awk '{print $1}')
    got=$(remote "sudo sha256sum $dest 2>/dev/null | awk '{print \$1}'")
    got=${got//[$'\r\n']/}
    if [[ $want == "$got" ]]; then
        printf 'unchanged: %s\n' "$dest"
        return 1
    fi
    push "$src" "/tmp/${PROG%.sh}.$$" || fail "scp $src failed"
    remote "sudo install -m $mode -o root -g root /tmp/${PROG%.sh}.$$ $dest && rm -f /tmp/${PROG%.sh}.$$" \
        || fail "installing $dest failed"
    printf 'changed: %s\n' "$dest"
    return 0
}

install_file "$SOURCE_DIR/ubuntu_os_update.sh" "$UPDATE_SCRIPT" 0755 && ((changed++))
install_file "$SOURCE_DIR/ubuntu_os_update_cron.sh" "$WRAPPER" 0755 && ((changed++))

# --- Telegram credentials --------------------------------------------------
token=$(grep -E '^[[:space:]]*(export[[:space:]]+)?TELEGRAM_BOT_TOKEN=' "$TELEGRAM_ENV" | head -n 1 | cut -d= -f2- | tr -d '\r')
chat=$(grep -E '^[[:space:]]*(export[[:space:]]+)?TELEGRAM_CHAT_ID=' "$TELEGRAM_ENV" | head -n 1 | cut -d= -f2- | tr -d '\r')
token=${token%\"}; token=${token#\"}; token=${token%\'}; token=${token#\'}
chat=${chat%\"}; chat=${chat#\"}; chat=${chat%\'}; chat=${chat#\'}
[[ -n $token && -n $chat ]] || fail "$TELEGRAM_ENV must define TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/os-update-deploy.XXXXXX") || fail 'cannot create a temporary directory'
trap 'rm -rf "$WORK_DIR"' EXIT
printf 'TELEGRAM_BOT_TOKEN="%s"\nTELEGRAM_CHAT_ID="%s"\nTELEGRAM_THREAD_ID="1"\n' \
    "$token" "$chat" > "$WORK_DIR/ubuntu_os_update.env"
chmod 600 "$WORK_DIR/ubuntu_os_update.env"
install_file "$WORK_DIR/ubuntu_os_update.env" "$ENV_FILE" 0600 && ((changed++))

# --- cron entry ------------------------------------------------------------
cat > "$WORK_DIR/ubuntu-os-update" <<EOF
# Managed by linux_scripts/deploy_os_update_cron.sh — do not edit on the host.
# Sunday 05:00 UTC+5 (owner time) == Sunday 05:00 $EXPECTED_TZ (this host).
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
$CRON_SPEC root $WRAPPER --host "$HOST_LABEL"
EOF
install_file "$WORK_DIR/ubuntu-os-update" "$CRON_FILE" 0644 && ((changed++))

# --- legacy jobs -----------------------------------------------------------
for job in ${LEGACY_JOBS[@]+"${LEGACY_JOBS[@]}"}; do
    if remote "sudo test -e $job" 2>/dev/null; then
        remote "sudo rm -f $job" || fail "cannot remove $job"
        printf 'changed: removed %s\n' "$job"
        ((changed++))
    else
        printf 'unchanged: %s is absent\n' "$job"
    fi
done

# --- read-back and assertions ---------------------------------------------
want_update=$(sha256sum "$SOURCE_DIR/ubuntu_os_update.sh" | awk '{print $1}')
want_wrapper=$(sha256sum "$SOURCE_DIR/ubuntu_os_update_cron.sh" | awk '{print $1}')
read_update=$(remote "sudo sha256sum $UPDATE_SCRIPT" | awk '{print $1}')
read_wrapper=$(remote "sudo sha256sum $WRAPPER" | awk '{print $1}')
[[ $read_update == "$want_update" ]] || fail "$UPDATE_SCRIPT does not match the repository"
[[ $read_wrapper == "$want_wrapper" ]] || fail "$WRAPPER does not match the repository"
remote "sudo bash -n $UPDATE_SCRIPT && sudo bash -n $WRAPPER" || fail 'the deployed scripts do not parse'

cron_text=$(remote "sudo cat $CRON_FILE") || fail "cannot read back $CRON_FILE"
[[ $cron_text == *"$CRON_SPEC root $WRAPPER"* ]] || fail 'the cron entry lost its schedule or command'
[[ $cron_text == *"$HOST_LABEL"* ]] || fail 'the cron entry lost the host label'
[[ $cron_text != *"--release-upgrade"* ]] || fail 'Kali must not run the rolling dist-upgrade'

root_crontab=$(remote 'crontab -l -u root 2>/dev/null || true')
[[ $root_crontab != *ubuntu_os_update* ]] || fail 'the root crontab duplicates the weekly OS refresh'

leftovers=$(remote "find /etc/cron.weekly /etc/cron.d -maxdepth 1 -type f \
    \\( -name '*auto-update*' -o -name '*os_update*' -o -name '*ubuntu-os-update*' \\) 2>/dev/null | grep -v '^$CRON_FILE\$' || true")
[[ -z ${leftovers//[$'\r\n ']/} ]] || fail "another weekly update job is still installed: $leftovers"

printf 'read-back %s:\n' "$CRON_FILE"
printf '%s\n' "$cron_text" | sed 's/^/  /'
printf 'sha256 %s %s\n' "$UPDATE_SCRIPT" "$read_update"
printf 'sha256 %s %s\n' "$WRAPPER" "$read_wrapper"
printf 'summary: host=%s tz=%s cron=%s changed=%d failed=0\n' \
    "$ADDRESS" "$host_tz" "$CRON_SPEC" "$changed"
exit 0
