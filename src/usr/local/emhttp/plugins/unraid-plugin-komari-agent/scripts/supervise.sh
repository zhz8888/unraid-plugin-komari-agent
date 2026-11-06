#!/bin/bash
#
# supervise.sh -- keep the komari agent running.
#
# Unraid has no systemd, so this loop is the supervisor: start.sh launches it
# with setsid, it runs the agent in the foreground of its own session and
# restarts it whenever it exits. The pid of this script is the pid written to
# /var/run/komari-agent.pid.
#
# The loop exits only when it is asked to: stop.sh sends SIGTERM, which
# terminates the current agent child and ends the loop instead of triggering
# one more restart.
#
# Everything this script prints is redirected to /var/log/komari-agent.log by
# start.sh.
#
# No "set -e" and no "set -u" on purpose: a supervisor that dies on an
# unexpected condition would silently stop monitoring the whole machine.

# ---------------------------------------------------------------- location

# The plugin directory is derived from where this script lives, so the script
# keeps working when the plugin is unpacked somewhere else for testing.
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
PLUGIN_DIR="$(dirname "${SELF_DIR}")"

if [ -r "${SELF_DIR}/lib.sh" ]; then
  . "${SELF_DIR}/lib.sh"
else
  # Minimal fallback so that a broken installation cannot turn into an
  # invisible crash loop.
  PLUGIN_NAME="unraid-plugin-komari-agent"
  FLASH_DIR="/boot/config/plugins/${PLUGIN_NAME}"
  BIN_DST="/usr/local/sbin/komari-agent"
  LOG_FILE="/var/log/komari-agent.log"
  append_log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"${LOG_FILE}" 2>/dev/null; }
  ensure_binary() { [ -x "${BIN_DST}" ]; }
  build_agent_env() { ENABLED=1; CONFIGURED=1; AGENT_ARGV=(); return 0; }
fi

# Seconds to wait before restarting a crashed agent. This is not a
# configuration key: the WebGUI has no field for it, and a user who needs a
# different value can export it before starting the service by hand.
RESTART_DELAY="${KOMARI_RESTART_DELAY:-10}"
case "${RESTART_DELAY}" in
  ''|*[!0-9]*) RESTART_DELAY=10 ;;
esac

AGENT_CHILD=""
STOPPING=0
RC=0

# --------------------------------------------------------------- shutdown

# terminate_child -- send SIGTERM to the agent and give it time to flush
# ./net_static.json before it is killed outright.
terminate_child() {
  local child="$1" waited=0
  if [ -z "${child}" ]; then
    return 0
  fi
  kill -0 "${child}" 2>/dev/null || return 0
  kill -TERM "${child}" 2>/dev/null
  while [ "${waited}" -lt 10 ]; do
    kill -0 "${child}" 2>/dev/null || return 0
    sleep 1
    waited=$((waited + 1))
  done
  kill -KILL "${child}" 2>/dev/null
  return 0
}

on_signal() {
  STOPPING=1
  append_log "supervisor: stop requested, terminating the agent (pid ${AGENT_CHILD:-none})"
  terminate_child "${AGENT_CHILD}"
  release_pidfile
  exit 0
}

# The pidfile records this supervisor, not the shell that started it.
#
# start.sh cannot simply use $! for that: when the supervisor is launched
# through setsid, setsid may fork, so the pid of the backgrounded job is not
# necessarily the pid of this script. Writing $$ from here is unambiguous.
#
# The file is only removed when it still contains our own pid, so a supervisor
# that is being replaced never deletes the pidfile of its successor.
claim_pidfile() {
  printf '%s\n' "$$" >"${PID_FILE}" 2>/dev/null
}

release_pidfile() {
  local recorded
  recorded="$(head -n 1 "${PID_FILE}" 2>/dev/null | tr -cd '0-9')"
  if [ "${recorded}" = "$$" ]; then
    rm -f "${PID_FILE}" 2>/dev/null
  fi
}

claim_pidfile

trap on_signal TERM INT HUP

# ------------------------------------------------------------------- loop

append_log "supervisor: started (pid $$, restart delay ${RESTART_DELAY}s)"

# The agent writes its traffic counters to ./net_static.json, so the working
# directory has to be the persistent flash directory. It is vfat: there is no
# execute bit, but plain file writes work, which is all the agent needs.
if [ -d "${FLASH_DIR}" ]; then
  cd "${FLASH_DIR}" 2>/dev/null
else
  append_log "supervisor: ${FLASH_DIR} is missing, running from /var/tmp; traffic counters will not survive a reboot"
  cd /var/tmp 2>/dev/null
fi

while [ "${STOPPING}" -eq 0 ]; do

  # Re-read the configuration on every restart, so that a change which did not
  # go through restart.sh still takes effect after the next crash.
  build_agent_env

  if [ "${ENABLED}" != "1" ]; then
    append_log "supervisor: the plugin is disabled in the settings, not restarting the agent"
    exit 0
  fi

  if ! ensure_binary; then
    append_log "supervisor: ${BIN_DST} is missing and could not be restored from ${BIN_CACHE}"
    sleep "${RESTART_DELAY}"
    continue
  fi

  append_log "supervisor: starting the agent"
  # The token is in the environment, never in the argument list.
  "${BIN_DST}" "${AGENT_ARGV[@]}" &
  AGENT_CHILD=$!
  wait "${AGENT_CHILD}"
  RC=$?
  AGENT_CHILD=""

  if [ "${STOPPING}" -eq 1 ]; then
    break
  fi

  case "${RC}" in
    0)  append_log "supervisor: the agent exited with status 0, restarting in ${RESTART_DELAY}s" ;;
    42) append_log "supervisor: the agent asked for a restart (status 42), restarting in ${RESTART_DELAY}s" ;;
    *)  append_log "supervisor: the agent exited with status ${RC}, restarting in ${RESTART_DELAY}s" ;;
  esac

  sleep "${RESTART_DELAY}"
done

release_pidfile
append_log "supervisor: stopped (pid $$)"
exit 0
