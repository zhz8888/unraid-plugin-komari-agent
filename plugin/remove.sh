# No shell error mode is enabled on purpose: the Unraid plugin installer
# treats a non-zero exit status as a failed removal, restores the plugin
# symlink and leaves the plugin installed, which is worse than a removal that
# reports a partial cleanup. The trap is the safety net for that rule.
trap 'exit 0' EXIT

PLUGIN_NAME="@@PLUGIN_NAME@@"
CONFIG_DIR="/boot/config/plugins/${PLUGIN_NAME}"
BIN_DST="/usr/local/sbin/komari-agent"
BIN_CACHE="${CONFIG_DIR}/@@BIN_NAME@@"
PLUGIN_DIR="/usr/local/emhttp/plugins/${PLUGIN_NAME}"
CFG_FILE="${CONFIG_DIR}/komari-agent.cfg"
NET_STATIC="${CONFIG_DIR}/net_static.json"
PID_FILE="/var/run/komari-agent.pid"
LOG_FILE="/var/log/komari-agent.log"

echo ""
echo "-----------------------------------------------------------"
echo " Removing ${PLUGIN_NAME}"
echo "-----------------------------------------------------------"

# ---- 1. Stop the service before anything it needs is deleted ------------
# The agent flushes its traffic counters to ./net_static.json on SIGTERM, and
# the supervisor would restart it a second later if it were left running while
# its scripts are removed. Stopping first is what makes the counter file on
# flash up to date at the moment it is preserved below.
echo "[1/5] Stopping the komari agent..."
if [ -x "${PLUGIN_DIR}/scripts/stop.sh" ]; then
  /bin/bash "${PLUGIN_DIR}/scripts/stop.sh"
else
  # The scripts are already gone (a half removed installation, or a removal
  # that follows a failed unpack). Fall back to the rc script, then to the
  # pidfile, so that a leftover daemon cannot survive the uninstall.
  if [ -x /etc/rc.d/rc.komari-agent ]; then
    /bin/bash /etc/rc.d/rc.komari-agent stop
  fi
fi

# A supervisor that survived the above would restart the agent from a deleted
# directory. Nothing below can work while it runs.
if [ -r "${PID_FILE}" ]; then
  SUPERVISOR_PID="$(head -n 1 "${PID_FILE}" 2>/dev/null | tr -cd '0-9')"
  if [ -n "${SUPERVISOR_PID}" ] && kill -0 "${SUPERVISOR_PID}" 2>/dev/null; then
    echo "      Stopping a remaining supervisor (pid ${SUPERVISOR_PID})"
    kill -TERM "${SUPERVISOR_PID}" 2>/dev/null
    sleep 2
    kill -KILL "${SUPERVISOR_PID}" 2>/dev/null
  fi
fi
rm -f "${PID_FILE}" 2>/dev/null

# ---- 2. Remove the Slackware package -----------------------------------
# removepkg removes /usr/local/emhttp/plugins/<name>/ (the WebGUI pages and
# the runtime scripts), /etc/rc.d/rc.komari-agent and the logrotate
# configuration, because all of those belong to the package.
echo "[2/5] Removing the plugin package..."
if command -v removepkg >/dev/null 2>&1; then
  removepkg "${PLUGIN_NAME}" 2>&1 || true
else
  echo "      removepkg is not available; removing the files by hand."
fi

# ---- 3. Remove what the install script created outside the package ------
# The executable is copied from the flash cache into the overlay by the
# install script, so it is not part of the package and removepkg leaves it
# behind.
echo "[3/5] Removing the installed files..."
rm -f "${BIN_DST}" 2>/dev/null
rm -f /etc/rc.d/rc.komari-agent 2>/dev/null
rm -f /etc/logrotate.d/komari-agent 2>/dev/null
rm -rf "${PLUGIN_DIR}" 2>/dev/null
rm -f "${LOG_FILE}" 2>/dev/null
rm -f "${LOG_FILE}.1" 2>/dev/null

# ---- 4. Clean up the flash cache, keep the user data -------------------
# The downloaded binary and the package are build artifacts of a specific
# release; leaving them behind would waste flash space and could confuse a
# later install. The configuration file and the traffic counters are user
# data: reinstalling the plugin should not throw away the panel URL, the
# token or the accumulated traffic history.
echo "[4/5] Cleaning up the flash cache..."
rm -f "${CONFIG_DIR}"/*.txz 2>/dev/null
rm -f "${BIN_CACHE}" 2>/dev/null
rm -f "${CONFIG_DIR}"/*.part 2>/dev/null
rm -f "${CONFIG_DIR}"/*.tmp 2>/dev/null

# ---- 5. Report what was kept -------------------------------------------
echo "[5/5] Checking the preserved user data..."
KEPT=0
if [ -f "${CFG_FILE}" ]; then
  echo "      Kept: ${CFG_FILE}"
  KEPT=1
fi
if [ -f "${NET_STATIC}" ]; then
  echo "      Kept: ${NET_STATIC}"
  KEPT=1
fi

if [ "${KEPT}" -eq 1 ]; then
  # The directory has to stay for the kept files to stay. It is only removed
  # when it is empty, which keeps /boot/config/plugins tidy after a removal
  # of a plugin that had never been configured.
  rmdir "${CONFIG_DIR}" 2>/dev/null
  echo ""
  echo " The configuration and the traffic counters were preserved, so that a"
  echo " reinstall keeps your panel URL, token and traffic history."
  echo " To delete them as well, run:"
  echo "   rm -rf ${CONFIG_DIR}"
else
  rmdir "${CONFIG_DIR}" 2>/dev/null
fi

echo ""
echo "-----------------------------------------------------------"
echo " ${PLUGIN_NAME} has been removed."
echo "-----------------------------------------------------------"
echo ""

# The remove script must never exit non-zero either: the installer would
# restore the plugin symlink and report the plugin as still installed.
exit 0
