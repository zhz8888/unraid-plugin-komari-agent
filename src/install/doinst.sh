#!/bin/sh
#
# doinst.sh -- Slackware post-install hook for unraid-plugin-komari-agent.
#
# Slackware runs this from the package's install/ directory with the package
# root as the working directory, after the files have been unpacked. It runs
# on every `upgradepkg --install-new`, and the Unraid plugin runs exactly that
# at every boot, so it has to be idempotent.
#
# It must exit 0 as well: upgradepkg treats a failing post-install hook as a
# failed upgrade, and the plugin installer treats that as a failed install.
#
# Nothing here starts the service. The install script in the .plg does that
# after it has restored the binary from the flash cache, because at doinst.sh
# time /usr/local/sbin/komari-agent does not exist yet.

PLUGIN_NAME="unraid-plugin-komari-agent"
PLUGIN_DIR="/usr/local/emhttp/plugins/${PLUGIN_NAME}"
SCRIPTS="${PLUGIN_DIR}/scripts"

# The plugin ships scripts that have to be executable. The tar archive keeps
# the mode, but a package repacked by a third party may not, and a script that
# cannot be executed is an installer failure that is hard to diagnose later.
if [ -d "${SCRIPTS}" ]; then
    chmod 0755 "${SCRIPTS}" 2>/dev/null
    for script in "${SCRIPTS}"/*.sh; do
        [ -f "${script}" ] || continue
        chmod 0755 "${script}" 2>/dev/null
    done
fi

# The rc script is called by the shutdown sequence and by the user, so it has
# to be executable as well.
if [ -f /etc/rc.d/rc.komari-agent ]; then
    chmod 0755 /etc/rc.d/rc.komari-agent 2>/dev/null
fi

# The WebGUI reads the plugin directory as the web server user. The directory
# only has to be traversable and readable, the pages are not executed as
# files but included by emhttp.
if [ -d "${PLUGIN_DIR}" ]; then
    chmod 0755 "${PLUGIN_DIR}" 2>/dev/null
fi

# /var/log and /var/run are tmpfs mount points that already exist, but a
# minimal or unusual system may not have them; the log redirect in start.sh
# fails silently when the directory is missing.
mkdir -p /var/log 2>/dev/null
mkdir -p /var/run 2>/dev/null

# The runtime directory for the executable. It exists on every Unraid system,
# this is only a guard for a hand built package.
mkdir -p /usr/local/sbin 2>/dev/null

exit 0
