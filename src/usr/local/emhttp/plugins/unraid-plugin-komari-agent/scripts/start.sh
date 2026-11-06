#!/bin/bash
#
# start.sh -- start the komari agent.
#
# Called by the plugin installer at every boot, by /etc/rc.d/rc.komari-agent,
# by restart.sh and by the WebGUI. Every call has to be harmless: the script
# exits 0 in every case, including "already running" and "not configured".
#
# The agent is not started directly. A supervisor loop (supervise.sh) is
# launched instead, which runs the agent and restarts it when it exits. The
# pid of that loop is what the pidfile records.
#
# Exit status is always 0: the Unraid plugin installer aborts the installation
# and unregisters the plugin when an install command returns non-zero.

# ---------------------------------------------------------------- location

SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

if [ -r "${SELF_DIR}/lib.sh" ]; then
  . "${SELF_DIR}/lib.sh"
else
  echo "[!] ${SELF_DIR}/lib.sh is missing; the plugin is not installed correctly."
  exit 0
fi

# --------------------------------------------------------------- preflight

# 1. Disabled in the settings? Then this is not a failure.
if [ "$(cfg_bool ENABLED 1)" != "1" ]; then
  echo "The plugin is disabled in the settings (ENABLED=0). Not starting the agent."
  exit 0
fi

# 2. Configured? Without an endpoint and a token there is nothing to report to.
build_agent_env
if [ "${CONFIGURED}" != "1" ]; then
  echo "The agent is not configured yet: both ENDPOINT and TOKEN have to be set."
  echo "Open Settings > Komari Agent and fill in the panel address and the agent token."
  exit 0
fi

# 3. Already running? Then leave it alone.
if [ -n "$(supervisor_pid)" ]; then
  echo "The komari agent is already running (supervisor pid $(supervisor_pid))."
  exit 0
fi
if [ -n "$(agent_pids)" ]; then
  echo "A komari agent process is already running without a supervisor (pid $(agent_pids | tr '\n' ' '))."
  echo "Run ${SELF_DIR}/restart.sh to take it over, or stop it by hand."
  exit 0
fi

# 4. The executable lives on the overlay and is restored from flash at boot.
if ! ensure_binary; then
  echo "[!] ${BIN_DST} is missing and could not be restored from ${BIN_CACHE}."
  echo "    Reinstall the plugin from the Plugins page to restore the binary."
  exit 0
fi

# --------------------------------------------------------------- launch

mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null
rotate_log_if_needed

# The supervisor is the last thing started from this shell. setsid detaches it
# from our session so that it survives the exit of the WebGUI request that
# started it; the triple redirect keeps it from inheriting the pipe the Unraid
# installer reads this script's output from. An inherited pipe would keep that
# read open until the agent exits, which is never.
#
# The pidfile is not written here. supervise.sh writes its own $$ into it,
# because setsid may fork and $! would then name the wrong process.
rm -f "${PID_FILE}" 2>/dev/null
if command -v setsid >/dev/null 2>&1; then
  setsid /bin/bash "${SELF_DIR}/supervise.sh" >>"${LOG_FILE}" 2>&1 </dev/null &
else
  /bin/bash "${SELF_DIR}/supervise.sh" >>"${LOG_FILE}" 2>&1 </dev/null &
fi

# Give the supervisor a moment to come up, then verify it really did.
sleep 2
SUPERVISOR_PID="$(supervisor_pid)"
if [ -z "${SUPERVISOR_PID}" ]; then
  echo "[!] The supervisor did not come up. Last log lines:"
  tail -n 20 "${LOG_FILE}" 2>/dev/null | sed 's/^/    /'
  echo "    The plugin stays registered so that it can be removed or updated"
  echo "    from the WebGUI."
  exit 0
fi

echo "The komari agent has been started (supervisor pid ${SUPERVISOR_PID})."
echo "Endpoint: ${ENDPOINT}"
echo "Log:      ${LOG_FILE}"
exit 0
