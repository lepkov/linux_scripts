#!/usr/bin/env bash
# ubuntu_os_update_cron.sh — scheduled wrapper around ubuntu_os_update.sh.
#
# It runs the OS refresh, then the host-local custom updates script (if any),
# sends exactly one short Telegram message with the aggregated result and
# reboots the host only after Telegram confirmed the delivery.
# The refresh itself stays in ubuntu_os_update.sh (single source of truth);
# this wrapper adds scheduling, host-only steps, reporting and the reboot gate.
#
#   sudo ./ubuntu_os_update_cron.sh                          # update + notify + reboot
#   sudo ./ubuntu_os_update_cron.sh --no-reboot              # update + notify, no reboot
#   sudo ./ubuntu_os_update_cron.sh --notify-only            # Telegram delivery smoke test
#   sudo ./ubuntu_os_update_cron.sh --dry-run                # plan only, no notify, no reboot
#
# Contract:
#   * one message, at most two lines, the host identifier first:
#       ✅ <host>: обновление прошло успешно
#       ⚠️ <host>: надо разобраться (код N, лог <path>)
#     the full log is never sent to Telegram;
#   * delivery counts only when the Bot API answers "ok":true — up to
#     --attempts tries (default 3), at least --retry-delay seconds apart
#     (default 30), first into the All topic (message_thread_id) and then
#     without it;
#   * the reboot happens once and only after a confirmed delivery. Without a
#     confirmed delivery the log says "REBOOT SKIPPED (notification not
#     delivered)" and the exit code is non-zero;
#   * --notify-only and --no-reboot exist so the pipeline can be checked
#     without touching the running host.
#
# Exit codes: 0 success; 1 the OS refresh or the custom updates script failed;
#             2 the log cannot be written; 3 the notification was not delivered;
#             64 bad usage.
set -uo pipefail

PROG=${0##*/}
HOST_ID=${UBUNTU_OS_UPDATE_HOST:-$(hostname -s 2>/dev/null || uname -n)}
ENV_FILE=/etc/ubuntu_os_update.env
UPDATE_SCRIPT=/usr/local/sbin/ubuntu_os_update.sh
LOG_DIR=/var/log
CUSTOM_UPDATES=""
NOTIFY_ONLY=0
NO_REBOOT=0
DRY_RUN=0
ATTEMPTS=3
RETRY_DELAY=30
THREAD_ID=1
declare -a UPDATE_ARGS=()

usage() {
    cat <<EOF
$PROG — scheduled OS refresh with Telegram result and gated reboot

Usage: sudo $PROG [options] [-- update-script options]

  --host NAME            host identifier in the message (default: $(hostname -s 2>/dev/null || echo hostname))
  --env-file PATH        credentials file (default: $ENV_FILE)
  --update-script PATH   refresh script (default: $UPDATE_SCRIPT)
  --custom-updates PATH  host-local updates script run after the refresh
                         (its exit code is part of the aggregated result)
  --notify-only          only send the notification; no refresh, no reboot
  --no-reboot            run and notify, but never reboot
  --dry-run              run the refresh with --dry-run; no notify, no reboot
  --log-dir DIR          where this wrapper writes its log (default: $LOG_DIR)
  --attempts N           delivery attempts, 1..5 (default: $ATTEMPTS)
  --retry-delay SEC      pause between attempts, >= 1 (default: $RETRY_DELAY)
  --thread-id ID         Telegram topic id, 0 = no topic (default: $THREAD_ID)
  -h, --help             this help

Exit codes: 0 ok, 1 refresh/hook failed, 2 log not writable,
            3 notification not delivered, 64 bad usage.
EOF
}

while (($#)); do
    case "$1" in
        --host)          shift; HOST_ID=${1:-} ;;
        --env-file)      shift; ENV_FILE=${1:-} ;;
        --update-script) shift; UPDATE_SCRIPT=${1:-} ;;
        --custom-updates) shift; CUSTOM_UPDATES=${1:-} ;;
        --notify-only)   NOTIFY_ONLY=1 ;;
        --no-reboot)     NO_REBOOT=1 ;;
        --dry-run)       DRY_RUN=1 ;;
        --log-dir)       shift; LOG_DIR=${1:-} ;;
        --attempts)      shift; ATTEMPTS=${1:-} ;;
        --retry-delay)   shift; RETRY_DELAY=${1:-} ;;
        --thread-id)     shift; THREAD_ID=${1:-} ;;
        -h|--help)       usage; exit 0 ;;
        --)              shift; UPDATE_ARGS+=("$@"); break ;;
        *) printf 'Unknown option: %s (see --help)\n' "$1" >&2; exit 64 ;;
    esac
    shift
done

[[ -n $HOST_ID ]] || { printf -- '--host: a non-empty host identifier is required\n' >&2; exit 64; }
[[ $ATTEMPTS =~ ^[0-9]+$ ]] && ((ATTEMPTS >= 1 && ATTEMPTS <= 5)) \
    || { printf -- '--attempts: an integer 1..5 is required\n' >&2; exit 64; }
[[ $RETRY_DELAY =~ ^[0-9]+$ ]] && ((RETRY_DELAY >= 1)) \
    || { printf -- '--retry-delay: an integer >= 1 is required\n' >&2; exit 64; }
[[ $THREAD_ID =~ ^[0-9]+$ ]] || { printf -- '--thread-id: a number is required\n' >&2; exit 64; }

mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR=${TMPDIR:-/tmp}
CRON_LOG="$LOG_DIR/${PROG%.sh}.log"
: >>"$CRON_LOG" 2>/dev/null || { printf 'Cannot write %s\n' "$CRON_LOG" >&2; exit 2; }
exec >>"$CRON_LOG" 2>&1

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Credentials: TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID / TELEGRAM_THREAD_ID.
if [[ -r $ENV_FILE ]]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi
TELEGRAM_THREAD_ID=${TELEGRAM_THREAD_ID:-$THREAD_ID}
[[ $TELEGRAM_THREAD_ID == 0 ]] && TELEGRAM_THREAD_ID=""

# One delivery attempt. Returns 0 only when the Bot API answered "ok":true.
try_send() {
    local text=$1 thread=${2:-} body=""
    local -a args=(
        --silent --show-error --connect-timeout 10 --max-time 30
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
        -d "chat_id=${TELEGRAM_CHAT_ID}"
        --data-urlencode "text=${text}"
    )
    [[ -n $thread ]] && args+=(-d "message_thread_id=${thread}")
    body=$(curl "${args[@]}" 2>/dev/null) || { log "telegram: curl failed (rc=$?)"; return 1; }
    if [[ $body == *'"ok":true'* ]]; then
        return 0
    fi
    log "telegram: not delivered — ${body:0:300}"
    return 1
}

# Up to ATTEMPTS tries, RETRY_DELAY seconds apart, topic first then no topic.
deliver() {
    local text=$1 attempt
    if [[ -z ${TELEGRAM_BOT_TOKEN:-} || -z ${TELEGRAM_CHAT_ID:-} ]]; then
        log "telegram: credentials are not configured ($ENV_FILE)"
        return 1
    fi
    for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
        if try_send "$text" "$TELEGRAM_THREAD_ID"; then
            log "telegram: delivered (attempt $attempt${TELEGRAM_THREAD_ID:+, thread $TELEGRAM_THREAD_ID})"
            return 0
        fi
        if [[ -n $TELEGRAM_THREAD_ID ]] && try_send "$text" ""; then
            log "telegram: delivered without message_thread_id (attempt $attempt)"
            return 0
        fi
        log "telegram: attempt $attempt/$ATTEMPTS failed"
        if ((attempt < ATTEMPTS)); then
            sleep "$RETRY_DELAY"
        fi
    done
    return 1
}

log "=== $PROG start: host=$HOST_ID, update=$UPDATE_SCRIPT, mode=$(
    if ((NOTIFY_ONLY)); then printf 'notify-only'
    elif ((DRY_RUN)); then printf 'dry-run'
    else printf 'full'
    fi) ==="

rc=0
if ((NOTIFY_ONLY)); then
    log "notify-only: the OS refresh is skipped"
elif ((DRY_RUN)); then
    log "dry-run: $UPDATE_SCRIPT --dry-run"
    "$UPDATE_SCRIPT" --dry-run ${UPDATE_ARGS[@]+"${UPDATE_ARGS[@]}"} || rc=$?
else
    log "running: $UPDATE_SCRIPT ${UPDATE_ARGS[*]-}"
    "$UPDATE_SCRIPT" ${UPDATE_ARGS[@]+"${UPDATE_ARGS[@]}"} || rc=$?
    log "refresh exit code: $rc"

    # Host-local software that only exists on this host (for example a panel
    # self-update) belongs here, not in ubuntu_os_update.sh.
    if [[ -n $CUSTOM_UPDATES ]]; then
        if [[ -x $CUSTOM_UPDATES ]]; then
            log "custom updates: $CUSTOM_UPDATES"
            custom_rc=0
            "$CUSTOM_UPDATES" || custom_rc=$?
            if ((custom_rc)); then
                log "custom updates failed: $custom_rc"
                ((rc == 0)) && rc=$custom_rc
            else
                log "custom updates: ok"
            fi
        else
            log "custom updates script is missing or not executable: $CUSTOM_UPDATES"
            ((rc == 0)) && rc=127
        fi
    fi
fi

if ((DRY_RUN)); then
    log "dry-run: no notification, no reboot"
    exit "$rc"
fi

# Newest refresh log — that is what the warning message points at.
UPDATE_LOG=$(ls -1t "$LOG_DIR"/ubuntu_os_update_*.log 2>/dev/null | head -n 1)
UPDATE_LOG=${UPDATE_LOG:-$LOG_DIR/ubuntu_os_update_<timestamp>.log}

if ((rc == 0)); then
    MSG="✅ ${HOST_ID}: обновление прошло успешно"
else
    MSG="⚠️ ${HOST_ID}: надо разобраться (код ${rc}, лог ${UPDATE_LOG})"
fi
log "message: $MSG"

delivered=0
deliver "$MSG" && delivered=1

if ((NOTIFY_ONLY)); then
    log "REBOOT SKIPPED (--notify-only)"
    ((delivered)) || exit 3
    exit "$rc"
fi
if ((NO_REBOOT)); then
    log "REBOOT SKIPPED (--no-reboot)"
    ((delivered)) || exit 3
    exit "$rc"
fi
if ((delivered == 0)); then
    log "REBOOT SKIPPED (notification not delivered)"
    exit 3
fi

log "reboot: issuing (notification delivered)"
rcb=0
if command -v reboot >/dev/null 2>&1; then
    reboot || rcb=$?
else
    systemctl reboot || rcb=$?
fi
log "reboot: the command returned rc=$rcb (unexpected — the host did not go down)"
((rc == 0)) && rc=$rcb
exit "$rc"
