#!/bin/bash
#
# lib.sh -- shared constants and helpers for the runtime scripts of the
#           unraid-plugin-komari-agent Unraid plugin.
#
# This file is sourced by the other scripts, it is never executed on its own.
# It deliberately enables no shell error mode and installs no trap: the Unraid
# plugin installer treats a non-zero exit status of an install or remove
# command as a failed install, moves the .plg to /boot/config/plugins-error/
# and drops the plugin from the Plugins page, so the user could not remove it
# from the WebGUI any more. Every script in this plugin has to survive its own
# errors and exit 0.
#
# Layout reminder (see the repository README for the full picture):
#
#   /boot/config/plugins/<name>/            flash, survives a reboot
#     komari-agent.cfg                      INI, written by /update.php
#     komari-agent-linux-amd64              pinned upstream binary, not executable
#     net_static.json                       traffic counters, written by the agent
#     <name>-<version>-x86_64-1.txz         the Slackware package
#   /usr/local/sbin/komari-agent            executable copy of the binary
#   /etc/rc.d/rc.komari-agent               start|stop|restart|status
#   /usr/local/emhttp/plugins/<name>/       WebGUI pages and these scripts
#   /var/log/komari-agent.log               tmpfs, wiped on reboot
#   /var/run/komari-agent.pid               supervisor pid, tmpfs
#
# /usr and /etc live on an overlay that is rebuilt from the flash device on
# every boot, which is why the plugin installer copies everything back into
# place at boot time.

# --------------------------------------------------------------- constants

PLUGIN_NAME="unraid-plugin-komari-agent"

PLUGIN_DIR="/usr/local/emhttp/plugins/${PLUGIN_NAME}"
PLUGIN_INFO="${PLUGIN_DIR}/plugin.info"
SCRIPT_DIR="${PLUGIN_DIR}/scripts"

FLASH_DIR="/boot/config/plugins/${PLUGIN_NAME}"
CFG_FILE="${FLASH_DIR}/komari-agent.cfg"
BIN_CACHE="${FLASH_DIR}/komari-agent-linux-amd64"
NET_STATIC="${FLASH_DIR}/net_static.json"

BIN_DST="/usr/local/sbin/komari-agent"
RC_SCRIPT="/etc/rc.d/rc.komari-agent"
LOGROTATE_FILE="/etc/logrotate.d/komari-agent"

LOG_FILE="/var/log/komari-agent.log"
LOG_MAX_BYTES=2097152
PID_FILE="/var/run/komari-agent.pid"

# The agent is matched by the exact start of its command line. pgrep is asked
# to stay inside our PID namespace so that an identically named process in a
# Docker container is never mistaken for the host daemon.
AGENT_PGREP_PATTERN='^/usr/local/sbin/komari-agent'

# ----------------------------------------------------------------- helpers

log_line() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

append_log() {
  log_line "$*" >>"${LOG_FILE}" 2>/dev/null
}

# Strip leading and trailing whitespace without forking a subprocess.
_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# ini_get FILE KEY [DEFAULT]
#
# Read one key from a flat INI file such as komari-agent.cfg or plugin.info.
# Both write their values as double quoted strings; single quotes and bare
# values are accepted as well so that a hand edited file keeps working.
# Nothing is eval'd, so a value may contain spaces, quotes, semicolons and
# shell metacharacters without any risk.
ini_get() {
  local file="$1" key="$2" default="${3-}" line k v
  if [ ! -r "${file}" ]; then
    printf '%s' "${default}"
    return 0
  fi
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%$'\r'}"
    case "${line}" in
      ''|'#'*|';'*) continue ;;
    esac
    case "${line}" in
      *=*) ;;
      *) continue ;;
    esac
    k="$(_trim "${line%%=*}")"
    [ "${k}" = "${key}" ] || continue
    v="$(_trim "${line#*=}")"
    case "${v}" in
      \"*\") v="${v#\"}"; v="${v%\"}" ;;
      \'*\') v="${v#\'}"; v="${v%\'}" ;;
    esac
    printf '%s' "${v}"
    return 0
  done <"${file}"
  printf '%s' "${default}"
}

cfg_get() {
  ini_get "${CFG_FILE}" "$@"
}

# cfg_has KEY -- true when the key is present, even when its value is empty.
# The distinction matters: an absent key falls back to the documented default,
# an explicitly emptied key is a user decision.
cfg_has() {
  local key="$1" line k
  if [ ! -r "${CFG_FILE}" ]; then
    return 1
  fi
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%$'\r'}"
    case "${line}" in
      *=*) ;;
      *) continue ;;
    esac
    k="$(_trim "${line%%=*}")"
    [ "${k}" = "${key}" ] && return 0
  done <"${CFG_FILE}"
  return 1
}

# cfg_bool KEY DEFAULT -- prints 1 or 0.
cfg_bool() {
  local key="$1" default="${2:-0}" v
  if cfg_has "${key}"; then
    v="$(cfg_get "${key}" '')"
  else
    v="${default}"
  fi
  v="$(printf '%s' "${v}" | tr '[:upper:]' '[:lower:]')"
  case "${v}" in
    1|true|yes|on) printf '1' ;;
    *) printf '0' ;;
  esac
}

# cfg_int KEY DEFAULT MIN MAX -- prints a clamped integer.
cfg_int() {
  local key="$1" default="$2" min="$3" max="$4" v
  v="$(cfg_get "${key}" "${default}")"
  case "${v}" in
    ''|*[!0-9]*) v="${default}" ;;
  esac
  [ "${v}" -lt "${min}" ] && v="${min}"
  [ "${v}" -gt "${max}" ] && v="${max}"
  printf '%s' "${v}"
}

# file_size PATH / file_mtime PATH -- 0 when the file does not exist.
file_size() {
  local s
  if [ ! -f "$1" ]; then
    printf '0'
    return 0
  fi
  s="$(stat -c '%s' "$1" 2>/dev/null)"
  case "${s}" in
    ''|*[!0-9]*) s=0 ;;
  esac
  printf '%s' "${s}"
}

file_mtime() {
  local s
  if [ ! -f "$1" ]; then
    printf '0'
    return 0
  fi
  s="$(stat -c '%Y' "$1" 2>/dev/null)"
  case "${s}" in
    ''|*[!0-9]*) s=0 ;;
  esac
  printf '%s' "${s}"
}

# proc_uptime PID -- elapsed seconds, 0 when unknown.
#
# /proc is read first because it is always present on Linux and does not
# depend on which fields the installed ps happens to support; "etimes" is a
# procps-ng extension that BusyBox ps and other implementations lack.
#
# field 22 of /proc/<pid>/stat is the start time in clock ticks since boot,
# and /proc/uptime is the seconds since boot, so the difference is the age of
# the process. The comm field can contain spaces and parentheses, which is why
# the stat line is split on the last ')' rather than by column position.
proc_uptime() {
  local pid="$1" t uptime_s start_ticks hz
  if [ -z "${pid}" ]; then
    printf '0'
    return 0
  fi
  if [ -r "/proc/${pid}/stat" ] && [ -r /proc/uptime ]; then
    uptime_s="$(awk '{print int($1)}' /proc/uptime 2>/dev/null)"
    start_ticks="$(awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/${pid}/stat" 2>/dev/null)"
    hz="$(getconf CLK_TCK 2>/dev/null)"
    case "${hz}" in
      ''|*[!0-9]*) hz=100 ;;
    esac
    case "${uptime_s}" in ''|*[!0-9]*) uptime_s=0 ;; esac
    case "${start_ticks}" in ''|*[!0-9]*) start_ticks=0 ;; esac
    if [ "${uptime_s}" -gt 0 ] && [ "${start_ticks}" -gt 0 ]; then
      t=$(( uptime_s - start_ticks / hz ))
      [ "${t}" -lt 0 ] && t=0
      printf '%s' "${t}"
      return 0
    fi
  fi
  t="$(ps -o etimes= -p "${pid}" 2>/dev/null | tr -d ' ')"
  case "${t}" in
    ''|*[!0-9]*) t=0 ;;
  esac
  printf '%s' "${t}"
}

# _pgrep_ns_option -- prints "--ns <pid>" when this pgrep supports it.
#
# Unraid 7 ships procps-ng, whose pgrep takes --ns. The probe tells the two
# possible failures apart: exit status 1 means "the option was accepted and
# nothing matched", anything else means the option is not understood. When in
# doubt the option is dropped, because a wrong --ns would hide a running agent
# while a missing one can only ever report too much.
_pgrep_ns_option() {
  if ! command -v pgrep >/dev/null 2>&1; then
    return 0
  fi
  pgrep --ns "$$" -f '__komari_agent_namespace_probe__' >/dev/null 2>&1
  if [ $? -eq 1 ]; then
    printf -- '--ns %s' "$$"
  fi
  return 0
}

# agent_pids -- the pids of the running agent processes, one per line.
agent_pids() {
  local opt
  if ! command -v pgrep >/dev/null 2>&1; then
    return 0
  fi
  opt="$(_pgrep_ns_option)"
  if [ -n "${opt}" ]; then
    # Unquoted on purpose: this is a pre-validated two word option list.
    pgrep ${opt} -f "${AGENT_PGREP_PATTERN}" 2>/dev/null
  else
    pgrep -f "${AGENT_PGREP_PATTERN}" 2>/dev/null
  fi
  return 0
}

# supervisor_pid -- the pid recorded in the pidfile, when it is still the
# supervisor and not a recycled pid.
supervisor_pid() {
  local pid
  if [ ! -r "${PID_FILE}" ]; then
    return 0
  fi
  pid="$(head -n 1 "${PID_FILE}" 2>/dev/null | tr -cd '0-9')"
  if [ -z "${pid}" ]; then
    return 0
  fi
  kill -0 "${pid}" 2>/dev/null || return 0
  # A pid alone proves nothing after a reboot: make sure the process really is
  # our supervisor and not some unrelated program that inherited the number.
  tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null | grep -q 'supervise\.sh' || return 0
  printf '%s' "${pid}"
}

# service_running -- true when a supervisor or an agent process is alive.
service_running() {
  if [ -n "$(supervisor_pid)" ]; then
    return 0
  fi
  if [ -n "$(agent_pids)" ]; then
    return 0
  fi
  return 1
}

# ensure_binary -- make sure /usr/local/sbin/komari-agent exists and is
# executable, restoring it from the flash cache when necessary.
#
# The flash device is mounted vfat, which cannot carry an executable bit, so
# the cached copy can only ever be a source to copy from.
ensure_binary() {
  if [ -x "${BIN_DST}" ]; then
    return 0
  fi
  if [ -f "${BIN_CACHE}" ]; then
    mkdir -p "$(dirname "${BIN_DST}")" 2>/dev/null
    # A running executable cannot be overwritten ("Text file busy"), so drop
    # the old inode first. Any process still running keeps its own copy.
    rm -f "${BIN_DST}" 2>/dev/null
    if cp -f "${BIN_CACHE}" "${BIN_DST}" 2>/dev/null; then
      chmod 0755 "${BIN_DST}" 2>/dev/null
      if [ -x "${BIN_DST}" ]; then
        append_log "restored ${BIN_DST} from the flash cache"
        return 0
      fi
    fi
  fi
  return 1
}

# rotate_log_if_needed -- keep the tmpfs log bounded.
#
# The log lives in RAM (/var/log is a tmpfs), so an agent that logs a lot must
# not be allowed to grow it without bound.
#
# The file is truncated in place, never renamed: the supervisor and the agent
# hold it open through a redirect and do not reopen it on a signal, so a
# rename would leave them writing into an unlinked inode while the visible log
# stayed empty and the disk usage never came back. Truncation in place is the
# same approach /etc/logrotate.d/komari-agent uses with copytruncate.
rotate_log_if_needed() {
  local size
  if [ ! -f "${LOG_FILE}" ]; then
    return 0
  fi
  size="$(file_size "${LOG_FILE}")"
  [ "${size}" -lt "${LOG_MAX_BYTES}" ] && return 0
  # One generation is kept so that the reason for a crash survives a rotation.
  cp -f "${LOG_FILE}" "${LOG_FILE}.1" 2>/dev/null
  : >"${LOG_FILE}" 2>/dev/null
  return 0
}

# json_str VALUE -- prints VALUE as a JSON string literal.
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/}"
  s="${s//$'\n'/}"
  s="${s//$'\r'/}"
  printf '"%s"' "${s}"
}

# json_bool 0|1 -- prints true or false.
json_bool() {
  if [ "$1" = "1" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

# ------------------------------------------------------- environment export

# export_str ENV_NAME CFG_KEY -- export when the value is non-empty.
export_str() {
  local envname="$1" key="$2" v
  v="$(cfg_get "${key}" '')"
  if [ -n "${v}" ]; then
    export "${envname}=${v}"
  else
    unset "${envname}"
  fi
}

# export_bool ENV_NAME CFG_KEY DEFAULT
#
# The upstream agent only overrides a boolean setting when the environment
# variable holds "1" or "true"; leaving the variable unset therefore keeps the
# compiled-in default, which is what a disabled option means.
export_bool() {
  local envname="$1" key="$2" default="${3:-0}" v
  v="$(cfg_bool "${key}" "${default}")"
  if [ "${v}" = "1" ]; then
    export "${envname}=1"
  else
    unset "${envname}"
  fi
}

export_int() {
  local envname="$1" key="$2" default="$3" min="$4" max="$5" v
  v="$(cfg_int "${key}" "${default}" "${min}" "${max}")"
  if [ -n "${v}" ]; then
    export "${envname}=${v}"
  else
    unset "${envname}"
  fi
}

# build_agent_env -- translate komari-agent.cfg into the AGENT_* environment
# the upstream binary reads, and into the extra command line arguments.
#
# Sets:
#   ENABLED     1|0   from cfg ENABLED
#   CONFIGURED  1|0   1 when both ENDPOINT and TOKEN are present
#   ENDPOINT          the configured panel URL
#   AGENT_ARGV        array of additional arguments (EXTRA_ARGS)
#
# The endpoint and the token are handed over in the environment only. Unlike
# a command line argument an environment variable is not shown by `ps` to
# other users, so the token never appears in the process list.
build_agent_env() {
  local interval extra

  ENDPOINT="$(cfg_get ENDPOINT '')"
  TOKEN_VALUE="$(cfg_get TOKEN '')"
  ENABLED="$(cfg_bool ENABLED 1)"

  CONFIGURED=0
  if [ -n "${ENDPOINT}" ] && [ -n "${TOKEN_VALUE}" ]; then
    CONFIGURED=1
  fi

  AGENT_ARGV=()

  export AGENT_ENDPOINT="${ENDPOINT}"
  export AGENT_TOKEN="${TOKEN_VALUE}"

  interval="$(cfg_get INTERVAL '3')"
  case "${interval}" in
    ''|*[!0-9.]*) interval='3' ;;
  esac
  export AGENT_INTERVAL="${interval}"

  export_bool AGENT_DISABLE_AUTO_UPDATE     DISABLE_AUTO_UPDATE     1
  export_bool AGENT_DISABLE_WEB_SSH         DISABLE_WEB_SSH         1
  export_bool AGENT_IGNORE_UNSAFE_CERT      IGNORE_UNSAFE_CERT      0
  export_bool AGENT_MEMORY_INCLUDE_CACHE    MEMORY_INCLUDE_CACHE    1
  export_bool AGENT_MEMORY_REPORT_RAW_USED  MEMORY_REPORT_RAW_USED  0
  export_bool AGENT_ENABLE_GPU              ENABLE_GPU              0

  export_str  AGENT_INCLUDE_NICS            INCLUDE_NICS
  export_str  AGENT_EXCLUDE_NICS            EXCLUDE_NICS
  export_str  AGENT_INCLUDE_MOUNTPOINTS     INCLUDE_MOUNTPOINTS
  export_str  AGENT_CUSTOM_DNS              CUSTOM_DNS

  export_int  AGENT_MONTH_ROTATE            MONTH_ROTATE            0 0 31

  # The upstream agent refuses to start on any other value, so an unexpected
  # value is dropped instead of being passed through.
  case "$(cfg_get PREFER_IP_VERSION '')" in
    4|6) export AGENT_PREFER_IP_VERSION="$(cfg_get PREFER_IP_VERSION '')" ;;
    *)   unset AGENT_PREFER_IP_VERSION ;;
  esac

  extra="$(cfg_get EXTRA_ARGS '')"
  if [ -n "${extra}" ]; then
    # A token on the command line would defeat the whole point of keeping it
    # in the environment, so the extra arguments are ignored entirely rather
    # than silently half applied.
    case " ${extra} " in
      *' --token '*|*' --token='*|*' -t '*)
        append_log "EXTRA_ARGS contains a token flag; ignoring EXTRA_ARGS so the token cannot leak into the process list"
        extra=''
        ;;
    esac
  fi
  if [ -n "${extra}" ]; then
    # Word splitting on whitespace is intended here: EXTRA_ARGS is a list of
    # arguments. read -a splits on IFS without performing pathname expansion,
    # so a value such as "--include-nics eth*" stays literal instead of being
    # expanded against the files in the working directory.
    read -r -a AGENT_ARGV <<<"${extra}"
  fi

  return 0
}
