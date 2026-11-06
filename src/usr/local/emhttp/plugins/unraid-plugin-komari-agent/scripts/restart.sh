#!/bin/bash
#
# restart.sh -- stop and start the komari agent.
#
# This is the script the settings page calls through the "#command" field of
# /update.php after the configuration file has been written. Its output is
# rendered into the progress box of the WebGUI, so it prints human readable
# progress lines rather than machine output.
#
# It is also the entry point the plugin installer uses at boot.
#
# Always exits 0, see the note in lib.sh.

SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

if [ -r "${SELF_DIR}/lib.sh" ]; then
  . "${SELF_DIR}/lib.sh"
else
  echo "[!] ${SELF_DIR}/lib.sh is missing; the plugin is not installed correctly."
  exit 0
fi

echo "Restarting the komari agent..."
echo ""

echo "--- stopping ---"
/bin/bash "${SELF_DIR}/stop.sh"
echo ""

echo "--- starting ---"
/bin/bash "${SELF_DIR}/start.sh"
echo ""

# A final state line, so the progress box shows the outcome instead of ending
# on whatever the start script happened to print last.
if [ -n "$(supervisor_pid)" ]; then
  echo "Result: running (supervisor pid $(supervisor_pid))."
  echo "Open Settings > Komari Agent to see the current status."
elif [ "$(cfg_bool ENABLED 1)" != "1" ]; then
  echo "Result: stopped, the plugin is disabled in the settings."
else
  echo "Result: not running. Check ${LOG_FILE} for the reason."
fi

exit 0
