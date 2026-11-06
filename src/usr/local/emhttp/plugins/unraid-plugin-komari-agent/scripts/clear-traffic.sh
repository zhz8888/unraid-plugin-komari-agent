#!/bin/bash
#
# clear-traffic.sh -- reset the agent's traffic counters.
#
# The agent keeps its counters in ./net_static.json in its working directory,
# which is the plugin directory on the flash device. Two ways to reset them:
#
#   1. Ask the running agent to drop them. Not possible from here: the agent
#      exposes no control socket, and its own Clear() is only reachable from
#      the WebSSH/RCE channel we deliberately disable by default.
#   2. Replace the file. The agent loads it at startup and rewrites it every
#      10 minutes, so the file has to be replaced while the agent is not
#      running, otherwise the in-memory state overwrites it again.
#
# So the reset is: stop, replace, start. That is a few seconds of missed
# reporting, which is the honest cost of not having a control channel.
#
# Usage:
#   clear-traffic.sh           stop the agent, reset the counters, start it
#   clear-traffic.sh --keep-running
#                              reset only if the agent is stopped, otherwise
#                              explain and do nothing
#
# Always exits 0, see the note in lib.sh.

SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

KEEP_RUNNING=0
case "${1-}" in
  --keep-running) KEEP_RUNNING=1 ;;
esac

if [ ! -r "${SELF_DIR}/lib.sh" ]; then
  echo "[!] ${SELF_DIR}/lib.sh is missing; the plugin is not installed correctly."
  exit 0
fi
. "${SELF_DIR}/lib.sh"

WAS_RUNNING=0
if service_running; then
  WAS_RUNNING=1
fi

if [ "${WAS_RUNNING}" -eq 1 ] && [ "${KEEP_RUNNING}" -eq 1 ]; then
  echo "The komari agent is running, so the counters cannot be reset safely."
  echo "The agent keeps them in memory and rewrites ${NET_STATIC} every 10 minutes."
  echo "Stop the agent first, or run ${SELF_DIR}/clear-traffic.sh without --keep-running"
  echo "to stop it, reset the counters and start it again."
  exit 0
fi

if [ "${WAS_RUNNING}" -eq 1 ]; then
  echo "Stopping the agent so that the counters can be reset..."
  /bin/bash "${SELF_DIR}/stop.sh"
  echo ""
fi

# Keep one backup. The counters are not critical data, but a user who clears
# them by accident should not have to lose the history to find that out.
if [ -f "${NET_STATIC}" ]; then
  if cp -f "${NET_STATIC}" "${NET_STATIC}.bak" 2>/dev/null; then
    echo "Previous counters saved to ${NET_STATIC}.bak"
  else
    echo "[!] Could not back up ${NET_STATIC}; continuing anyway."
  fi
  rm -f "${NET_STATIC}" 2>/dev/null
  if [ -f "${NET_STATIC}" ]; then
    echo "[!] Could not remove ${NET_STATIC}."
    echo "    Check that the flash device is mounted read-write and that the file is not locked."
  else
    echo "Traffic counters cleared. The agent creates the file again on its next save."
  fi
else
  echo "There is no ${NET_STATIC} to clear."
fi

# A stale temporary file would be picked up by nothing, but it confuses the
# next save and takes space on the flash device.
rm -f "${NET_STATIC}.tmp" 2>/dev/null

if [ "${WAS_RUNNING}" -eq 1 ]; then
  echo ""
  echo "Starting the agent again..."
  /bin/bash "${SELF_DIR}/start.sh"
fi

exit 0
