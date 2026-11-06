#!/bin/bash
#
# stop.sh -- stop the komari agent.
#
# Order matters: the supervisor is asked to stop first, because it is the
# process that would otherwise restart the agent a second later. It forwards
# the signal to its child, and the agent flushes its traffic counters to
# ./net_static.json on SIGTERM before it exits.
#
# The script is idempotent: stopping an already stopped service succeeds.
# It always exits 0, see the note in lib.sh.

# ---------------------------------------------------------------- location

SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

if [ -r "${SELF_DIR}/lib.sh" ]; then
  . "${SELF_DIR}/lib.sh"
else
  echo "[!] ${SELF_DIR}/lib.sh is missing; the plugin is not installed correctly."
  exit 0
fi

STOPPED=0
WAITED=0
SUPERVISOR=""
PIDS=""

# _wait_for_exit PID TIMEOUT -- wait until PID is gone, at most TIMEOUT seconds.
_wait_for_exit() {
  local pid="$1" timeout="$2" waited=0
  while [ "${waited}" -lt "${timeout}" ]; do
    kill -0 "${pid}" 2>/dev/null || return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# ---------------------------------------------------------------- supervisor

SUPERVISOR="$(supervisor_pid)"
if [ -n "${SUPERVISOR}" ]; then
  echo "Stopping the supervisor (pid ${SUPERVISOR})..."
  kill -TERM "${SUPERVISOR}" 2>/dev/null
  if _wait_for_exit "${SUPERVISOR}" 10; then
    echo "  The supervisor has stopped."
  else
    echo "  The supervisor did not stop within 10 seconds, sending SIGKILL."
    kill -KILL "${SUPERVISOR}" 2>/dev/null
    _wait_for_exit "${SUPERVISOR}" 3
  fi
  STOPPED=1
fi

# ------------------------------------------------------------ stray agents

# The supervisor terminates its own child, so this only catches processes that
# were started before a supervisor existed, or a supervisor that was killed
# before it could clean up.
PIDS="$(agent_pids | tr '\n' ' ')"
if [ -n "${PIDS// /}" ]; then
  echo "Stopping the agent process(es): ${PIDS}"
  for P in ${PIDS}; do
    kill -TERM "${P}" 2>/dev/null
  done
  WAITED=0
  for P in ${PIDS}; do
    if ! _wait_for_exit "${P}" 10; then
      echo "  pid ${P} did not stop within 10 seconds, sending SIGKILL."
      kill -KILL "${P}" 2>/dev/null
    fi
    WAITED=1
  done
  [ "${WAITED}" -eq 1 ] && STOPPED=1
fi

# ------------------------------------------------------------------ cleanup

rm -f "${PID_FILE}" 2>/dev/null

if [ "${STOPPED}" -eq 1 ]; then
  echo "The komari agent has been stopped."
else
  echo "The komari agent is not running."
fi

# The last traffic counters are flushed by the agent itself on SIGTERM. If it
# had to be killed, the counters since the last periodic save (10 minutes) are
# lost; that is expected and not reported as an error.
exit 0
