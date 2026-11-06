#!/bin/bash
#
# apply.sh -- apply the settings that were just saved.
#
# The settings page posts the configuration file to /update.php and names this
# script in the "#command" field, so it runs right after the file has been
# written. Applying a configuration means restarting the agent: the process
# reads its settings once at startup.
#
# This is a deliberately thin alias for restart.sh, so that the WebGUI and the
# documentation have one obvious entry point for "save and apply" and the
# behaviour cannot drift between the two.
#
# Always exits 0, see the note in lib.sh.

SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

if [ -r "${SELF_DIR}/restart.sh" ]; then
  /bin/bash "${SELF_DIR}/restart.sh"
else
  echo "[!] ${SELF_DIR}/restart.sh is missing; the plugin is not installed correctly."
fi

exit 0
