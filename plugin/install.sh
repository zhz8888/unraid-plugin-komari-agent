# No shell error mode is enabled on purpose. The Unraid plugin installer runs
# this script through a pipe and treats a non-zero exit status as a failed
# install: it then moves the .plg to /boot/config/plugins-error/ and creates no
# /var/log/plugins symlink, so the plugin disappears from the Plugins page and
# the user cannot uninstall it any more. The trap below is the final safety net
# for that rule; every failure branch below also returns 0 explicitly.
#
# The script runs at every boot, because /var/log/plugins is on a tmpfs and
# the installer therefore reinstalls every .plg under /boot/config/plugins on
# each start. It has to be idempotent: no error when a file already exists, no
# error when a previous version left something behind, no error when it runs
# twice in a row.
trap 'exit 0' EXIT

PLUGIN_NAME="@@PLUGIN_NAME@@"
PLUGIN_VERSION="@@PLUGIN_VERSION@@"
UPSTREAM_VERSION="@@UPSTREAM_VERSION@@"
CONFIG_DIR="/boot/config/plugins/${PLUGIN_NAME}"
PACKAGE="${CONFIG_DIR}/@@TXZ_NAME@@"
BIN_CACHE="${CONFIG_DIR}/@@BIN_NAME@@"
BIN_DST="/usr/local/sbin/komari-agent"
PLUGIN_DIR="/usr/local/emhttp/plugins/${PLUGIN_NAME}"
CFG_FILE="${CONFIG_DIR}/komari-agent.cfg"
EXPECTED_BIN_SHA256="@@BIN_SHA256@@"

echo ""
echo "-----------------------------------------------------------"
echo " Installing ${PLUGIN_NAME} ${PLUGIN_VERSION}"
echo " komari-agent: ${UPSTREAM_VERSION}"
echo "-----------------------------------------------------------"

# ---- 0. Drop the mirrored variant ---------------------------------------
# The installer registers one symlink per .plg file name, so a leftover
# mirrored variant would show up as a second entry in the Plugins tab and
# would install the same package twice on every boot.
@@SIBLING_CLEANUP@@

# ---- 1. Preflight --------------------------------------------------------
mkdir -p "${CONFIG_DIR}" 2>/dev/null

if [ ! -f "${PACKAGE}" ]; then
  echo "[!] The plugin package is missing: ${PACKAGE}"
  echo "    The Unraid installer should have downloaded it before running"
  echo "    this script. Check the plugin install log for download errors."
  echo "    The plugin stays registered so that it can be removed or updated"
  echo "    from the WebGUI."
  exit 0
fi

if [ ! -f "${BIN_CACHE}" ]; then
  echo "[!] The agent binary is missing: ${BIN_CACHE}"
  echo "    The Unraid installer should have downloaded it before running"
  echo "    this script. Check the plugin install log for download errors."
  echo "    The plugin stays registered so that it can be removed or updated"
  echo "    from the WebGUI."
  exit 0
fi

# ---- 2. Verify the downloaded binary before it is installed --------------
# The installer already checked the SHA256 of the download, but the file has
# been sitting on a vfat partition since then. Re-checking it here means a
# corrupted flash device is caught now instead of as a mysterious crash loop.
echo "[1/6] Verifying the downloaded agent binary..."
ACTUAL_BIN_SHA256=""
if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_BIN_SHA256="$(sha256sum "${BIN_CACHE}" 2>/dev/null | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_BIN_SHA256="$(shasum -a 256 "${BIN_CACHE}" 2>/dev/null | awk '{print $1}')"
fi

if [ -z "${ACTUAL_BIN_SHA256}" ]; then
  echo "    Skipped: neither sha256sum nor shasum is available."
elif [ "${ACTUAL_BIN_SHA256}" = "${EXPECTED_BIN_SHA256}" ]; then
  echo "      OK: SHA256 matches the pinned upstream artifact"
else
  echo "[!] SHA256 mismatch for ${BIN_CACHE}"
  echo "    expected ${EXPECTED_BIN_SHA256}"
  echo "    actual   ${ACTUAL_BIN_SHA256}"
  echo "    The file on the flash device is damaged. Delete it and reinstall"
  echo "    the plugin, otherwise the agent will not start."
  echo "    The plugin stays registered so that it can be removed or updated"
  echo "    from the WebGUI."
  exit 0
fi

# ---- 3. Install the Slackware package -----------------------------------
# upgradepkg --install-new installs over an existing version and installs a
# missing one, which is what makes the boot time reinstall idempotent.
echo "[2/6] Installing the plugin package..."
if ! upgradepkg --install-new "${PACKAGE}" 2>&1; then
  echo "[!] upgradepkg failed."
  echo "    The plugin stays registered so that it can be removed or updated"
  echo "    from the WebGUI."
  exit 0
fi

# ---- 4. Restore the executable into the overlay -------------------------
# /usr/local/sbin lives on an overlay that is discarded on reboot, and the
# flash device is vfat, which cannot carry an executable bit. The binary is
# therefore copied from flash into the overlay on every install and on every
# boot, and never run from flash directly.
echo "[3/6] Installing the agent binary into ${BIN_DST}..."
mkdir -p "$(dirname "${BIN_DST}")" 2>/dev/null
# A running binary cannot be overwritten ("Text file busy"), so the old inode
# is unlinked first. A process that is still running keeps its own copy.
rm -f "${BIN_DST}" 2>/dev/null
if ! cp -f "${BIN_CACHE}" "${BIN_DST}" 2>/dev/null; then
  echo "[!] Could not copy ${BIN_CACHE} to ${BIN_DST}."
  echo "    Check the free space on the root filesystem (df -h /usr)."
  exit 0
fi
chmod 0755 "${BIN_DST}" 2>/dev/null
if [ ! -x "${BIN_DST}" ]; then
  echo "[!] ${BIN_DST} is not executable after the copy."
  echo "    The root filesystem may be mounted read-only."
  exit 0
fi
echo "      OK: $(ls -l "${BIN_DST}" 2>/dev/null | awk '{print $1, $5, "bytes"}')"

# ---- 5. logrotate configuration -----------------------------------------
# The package ships this file, so it is only written when it is missing or
# when the shipped copy was not unpacked. logrotate reads the whole directory,
# so a missing file would silently mean "no rotation" rather than an error.
echo "[4/6] Checking the logrotate configuration..."
if [ ! -f /etc/logrotate.d/komari-agent ]; then
  mkdir -p /etc/logrotate.d 2>/dev/null
  cat >/etc/logrotate.d/komari-agent <<'LOGROTATE_EOF'
# Written by the unraid-plugin-komari-agent installer.
#
# /var/log is a tmpfs on Unraid, so this log does not survive a reboot and
# cannot fill the flash device. It can still fill the RAM.
#
# copytruncate is required: the agent holds the file open through a redirect
# and does not reopen it on a signal, so the file has to be truncated in place
# instead of being renamed.
/var/log/komari-agent.log {
    size 2M
    rotate 2
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
LOGROTATE_EOF
  chmod 0644 /etc/logrotate.d/komari-agent 2>/dev/null
  echo "      Created /etc/logrotate.d/komari-agent"
else
  echo "      OK: /etc/logrotate.d/komari-agent is present"
fi

# ---- 6. Clean up superseded files on the flash device -------------------
# The installer never overwrites a cached file whose name already exists, so
# the file name carries the version. Without this cleanup every release would
# leave its predecessor behind on the flash device forever.
echo "[5/6] Removing superseded files from the flash cache..."
# The loop is not a stylistic choice: an unquoted $(ls ...) splits its result on
# IFS, so a file name containing a space would be handed to rm as several
# arguments. The flash device is vfat and the cache directory is reachable by
# the user, so the names are not ours to assume.
for stale in "${CONFIG_DIR}"/*.txz; do
  [ -f "${stale}" ] || continue
  [ "${stale##*/}" = "@@TXZ_NAME@@" ] && continue
  rm -f "${stale}" 2>/dev/null
done
for stale in "${CONFIG_DIR}"/komari-agent-linux-*; do
  [ -f "${stale}" ] || continue
  [ "${stale##*/}" = "@@BIN_NAME@@" ] && continue
  rm -f "${stale}" 2>/dev/null
done
# Leftovers of an interrupted download. The installer writes straight to the
# final name, so a stale partial file would be trusted on the next boot.
rm -f "${CONFIG_DIR}"/*.part 2>/dev/null
rm -f "${CONFIG_DIR}"/*.tmp 2>/dev/null

# ---- 7. Start or restart the agent --------------------------------------
echo "[6/6] Starting the komari agent..."
if [ -x "${PLUGIN_DIR}/scripts/restart.sh" ]; then
  # restart.sh reads the configuration itself and prints why it did not start
  # the agent when the plugin is disabled or not configured yet. Its output is
  # part of this install log on purpose: "not configured" is the normal state
  # right after a fresh install and has to be explained, not hidden.
  /bin/bash "${PLUGIN_DIR}/scripts/restart.sh"
else
  echo "[!] ${PLUGIN_DIR}/scripts/restart.sh is missing."
  echo "    The package did not unpack correctly. Reinstall the plugin."
fi

echo ""
echo "-----------------------------------------------------------"
echo " ${PLUGIN_NAME} ${PLUGIN_VERSION} has been installed."
echo " komari-agent ${UPSTREAM_VERSION}"
echo ""
echo " Next steps:"
echo "   Settings > Komari Agent: enter the panel URL and the agent token."
echo "   The agent is not started until both are set."
echo ""
echo " The plugin does not enable the upstream auto-update and the remote"
echo " control channel by default. Both can be enabled in the advanced"
echo " section of the settings page; see the README for the trade-offs."
echo "-----------------------------------------------------------"
echo ""

# The install script must never exit non-zero, see the comment at the top.
exit 0
