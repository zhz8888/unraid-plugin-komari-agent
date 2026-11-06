#!/bin/bash
#
# status.sh -- report the state of the komari agent.
#
# Two consumers read this script:
#
#   include/data/Status.php   calls it and parses the JSON with json_decode()
#   /etc/rc.d/rc.komari-agent calls it with --text for a human readable summary
#
# Usage:
#   status.sh            JSON on stdout, one object
#   status.sh --json     same as above
#   status.sh --text     plain text lines for the command line
#
# ---------------------------------------------------------------------------
# JSON CONTRACT
#
# The status endpoint depends on these names and types. Adding keys is fine;
# renaming or retyping one breaks the WebGUI. Every value is a string, a
# boolean, an integer or an array of those -- no floats, no nulls -- so that
# json_decode($out, true) always yields the same shapes. On a hard internal
# error the script still prints a complete object with an extra "error"
# string field, and exits 0.
#
#   schema                string    always "komari-agent-status/1"
#   generated_at          integer   unix seconds when the snapshot was taken
#
#   plugin                object
#     name                string    "unraid-plugin-komari-agent"
#     version             string    plugin version, YYYYMMDD[.a]  ("" if unknown)
#     upstream_version    string    bundled komari-agent version ("" if unknown)
#
#   config                object    reflects komari-agent.cfg
#     file                string    absolute path of the configuration file
#     exists              boolean
#     enabled             boolean   ENABLED
#     configured          boolean   ENDPOINT and TOKEN are both non-empty
#     endpoint            string    ENDPOINT with any userinfo part stripped
#     token_set           boolean   a token is configured. The token itself is
#                                   NEVER part of this output.
#     interval            string    INTERVAL as configured
#     disable_auto_update boolean
#     disable_web_ssh     boolean
#
#   binary                object
#     path                string    "/usr/local/sbin/komari-agent"
#     installed           boolean   exists and is executable
#     size                integer   bytes, 0 when absent
#     version             string    upstream version from plugin.info
#     sha256_ok           boolean   the installed copy matches the pinned one
#     sha256_checked      boolean   false when no checksum tool is available
#     cache_path          string    the pinned copy on the flash device
#     cache_present       boolean
#     cache_size          integer   bytes, 0 when absent
#
#   service               object
#     running             boolean   supervisor or agent process alive
#     supervised          boolean   a supervisor owns the process
#     supervisor_pid      integer   0 when none
#     supervisor_uptime   integer   seconds, 0 when unknown
#     agent_pids          array     integers, possibly empty
#     agent_pid           integer   the first agent pid, 0 when none
#     agent_uptime        integer   seconds of the first agent, 0 when unknown
#     pidfile             string    absolute path of the pidfile
#     pidfile_present     boolean
#
#   log                   object
#     path                string    "/var/log/komari-agent.log"
#     present             boolean
#     size                integer   bytes
#     modified_at         integer   unix seconds, 0 when absent
#     lines               array     strings, the last 20 lines, oldest first
#
#   traffic               object    metadata of ./net_static.json only
#     file                string    absolute path
#     present             boolean
#     size                integer   bytes
#     modified_at         integer   unix seconds, 0 when absent
#
#     The per interface byte counters live in that JSON document. They are
#     decoded by the PHP status endpoint with json_decode() rather than by
#     this script: a hand written JSON parser in awk would be both slower and
#     easier to get wrong than the decoder PHP already ships with.

SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

MODE="json"
case "${1-}" in
  --text)   MODE="text" ;;
  --json|"") MODE="json" ;;
  *)        MODE="json" ;;
esac

if [ ! -r "${SELF_DIR}/lib.sh" ]; then
  printf '{\n  "schema": "komari-agent-status/1",\n  "error": "lib.sh is missing, the plugin is not installed correctly"\n}\n'
  exit 0
fi
. "${SELF_DIR}/lib.sh"

# ------------------------------------------------------------- collection

PLUGIN_VERSION="$(ini_get "${PLUGIN_INFO}" PLUGIN_VERSION '')"
UPSTREAM_VERSION="$(ini_get "${PLUGIN_INFO}" UPSTREAM_VERSION '')"
PINNED_SHA256="$(ini_get "${PLUGIN_INFO}" BINARY_SHA256 '')"

CFG_EXISTS=0
[ -f "${CFG_FILE}" ] && CFG_EXISTS=1

CFG_ENABLED="$(cfg_bool ENABLED 1)"
CFG_ENDPOINT="$(cfg_get ENDPOINT '')"
CFG_TOKEN="$(cfg_get TOKEN '')"
CFG_INTERVAL="$(cfg_get INTERVAL '3')"

CFG_CONFIGURED=0
if [ -n "${CFG_ENDPOINT}" ] && [ -n "${CFG_TOKEN}" ]; then
  CFG_CONFIGURED=1
fi

# http://user:secret@panel/ carries credentials in the URL. The status page is
# world readable inside the WebGUI, so the userinfo part is stripped here
# rather than trusted to be stripped by every consumer.
case "${CFG_ENDPOINT}" in
  *://*@*)
    _scheme="${CFG_ENDPOINT%%://*}"
    _rest="${CFG_ENDPOINT#*://}"
    ENDPOINT_SHOWN="${_scheme}://${_rest##*@}"
    ;;
  *)
    ENDPOINT_SHOWN="${CFG_ENDPOINT}"
    ;;
esac

CFG_TOKEN_SET=0
[ -n "${CFG_TOKEN}" ] && CFG_TOKEN_SET=1

BIN_INSTALLED=0
[ -x "${BIN_DST}" ] && BIN_INSTALLED=1
BIN_SIZE="$(file_size "${BIN_DST}")"

CACHE_PRESENT=0
[ -f "${BIN_CACHE}" ] && CACHE_PRESENT=1
CACHE_SIZE="$(file_size "${BIN_CACHE}")"

# Comparing the installed copy against the pinned checksum catches a partial
# copy, or a binary replaced behind the plugin's back. It is skipped
# (sha256_checked=false) when no checksum tool exists.
SHA256_CHECKED=0
SHA256_OK=0
if [ "${BIN_INSTALLED}" -eq 1 ] && [ -n "${PINNED_SHA256}" ]; then
  _actual=""
  if command -v sha256sum >/dev/null 2>&1; then
    _actual="$(sha256sum "${BIN_DST}" 2>/dev/null | awk '{print $1}')"
    SHA256_CHECKED=1
  elif command -v shasum >/dev/null 2>&1; then
    _actual="$(shasum -a 256 "${BIN_DST}" 2>/dev/null | awk '{print $1}')"
    SHA256_CHECKED=1
  fi
  if [ "${SHA256_CHECKED}" -eq 1 ] && [ "${_actual}" = "${PINNED_SHA256}" ]; then
    SHA256_OK=1
  fi
fi

SUPERVISOR="$(supervisor_pid)"
SUPERVISOR_PID=0
SUPERVISOR_UPTIME=0
if [ -n "${SUPERVISOR}" ]; then
  SUPERVISOR_PID="${SUPERVISOR}"
  SUPERVISOR_UPTIME="$(proc_uptime "${SUPERVISOR}")"
fi

AGENT_LIST="$(agent_pids)"
AGENT_PID=0
AGENT_UPTIME=0
if [ -n "${AGENT_LIST}" ]; then
  AGENT_PID="$(printf '%s\n' "${AGENT_LIST}" | head -n 1)"
  AGENT_UPTIME="$(proc_uptime "${AGENT_PID}")"
fi

SERVICE_RUNNING=0
if [ "${SUPERVISOR_PID}" -ne 0 ] || [ -n "${AGENT_LIST}" ]; then
  SERVICE_RUNNING=1
fi
SERVICE_SUPERVISED=0
[ "${SUPERVISOR_PID}" -ne 0 ] && SERVICE_SUPERVISED=1

PIDFILE_PRESENT=0
[ -f "${PID_FILE}" ] && PIDFILE_PRESENT=1

LOG_PRESENT=0
[ -f "${LOG_FILE}" ] && LOG_PRESENT=1
LOG_SIZE="$(file_size "${LOG_FILE}")"
LOG_MTIME="$(file_mtime "${LOG_FILE}")"

TRAFFIC_PRESENT=0
[ -f "${NET_STATIC}" ] && TRAFFIC_PRESENT=1
TRAFFIC_SIZE="$(file_size "${NET_STATIC}")"
TRAFFIC_MTIME="$(file_mtime "${NET_STATIC}")"

# ------------------------------------------------------------ text output

if [ "${MODE}" = "text" ]; then
  if [ "${SERVICE_RUNNING}" -eq 1 ]; then
    echo "komari-agent: running"
  else
    echo "komari-agent: stopped"
  fi
  echo "  plugin version   : ${PLUGIN_VERSION:-unknown}"
  echo "  upstream version : ${UPSTREAM_VERSION:-unknown}"
  echo "  configured       : $([ "${CFG_CONFIGURED}" -eq 1 ] && echo yes || echo no)"
  echo "  enabled          : $([ "${CFG_ENABLED}" -eq 1 ] && echo yes || echo no)"
  echo "  endpoint         : ${ENDPOINT_SHOWN:-<not set>}"
  echo "  supervisor pid   : ${SUPERVISOR_PID}"
  echo "  agent pid(s)     : ${AGENT_LIST:-none}"
  if [ "${SUPERVISOR_UPTIME}" -gt 0 ]; then
    echo "  uptime           : ${SUPERVISOR_UPTIME}s"
  fi
  echo "  binary           : ${BIN_DST} ($([ "${BIN_INSTALLED}" -eq 1 ] && echo installed || echo missing))"
  echo "  log              : ${LOG_FILE} (${LOG_SIZE} bytes)"
  echo "  traffic counters : ${NET_STATIC} ($([ "${TRAFFIC_PRESENT}" -eq 1 ] && echo present || echo absent))"
  exit 0
fi

# ------------------------------------------------------------ json output

NOW="$(date +%s)"
case "${NOW}" in
  ''|*[!0-9]*) NOW=0 ;;
esac

AGENT_PIDS_JSON=""
while IFS= read -r _pid; do
  case "${_pid}" in
    ''|*[!0-9]*) continue ;;
  esac
  if [ -n "${AGENT_PIDS_JSON}" ]; then
    AGENT_PIDS_JSON="${AGENT_PIDS_JSON},${_pid}"
  else
    AGENT_PIDS_JSON="${_pid}"
  fi
done <<EOF
${AGENT_LIST}
EOF

# The log tail is escaped by json_str() from lib.sh, so a line that contains a
# quote or a backslash cannot break the document the status page parses.
LOG_LINES_JSON=""
while IFS= read -r _line; do
  _escaped="$(json_str "${_line}")"
  if [ -n "${LOG_LINES_JSON}" ]; then
    LOG_LINES_JSON="${LOG_LINES_JSON},${_escaped}"
  else
    LOG_LINES_JSON="${_escaped}"
  fi
done <<EOF
$(tail -n 20 "${LOG_FILE}" 2>/dev/null)
EOF

printf '{\n'
printf '  "schema": %s,\n'      "$(json_str 'komari-agent-status/1')"
printf '  "generated_at": %s,\n' "${NOW}"

printf '  "plugin": {\n'
printf '    "name": %s,\n'            "$(json_str "${PLUGIN_NAME}")"
printf '    "version": %s,\n'         "$(json_str "${PLUGIN_VERSION}")"
printf '    "upstream_version": %s\n' "$(json_str "${UPSTREAM_VERSION}")"
printf '  },\n'

printf '  "config": {\n'
printf '    "file": %s,\n'                "$(json_str "${CFG_FILE}")"
printf '    "exists": %s,\n'              "$(json_bool "${CFG_EXISTS}")"
printf '    "enabled": %s,\n'             "$(json_bool "${CFG_ENABLED}")"
printf '    "configured": %s,\n'          "$(json_bool "${CFG_CONFIGURED}")"
printf '    "endpoint": %s,\n'            "$(json_str "${ENDPOINT_SHOWN}")"
printf '    "token_set": %s,\n'           "$(json_bool "${CFG_TOKEN_SET}")"
printf '    "interval": %s,\n'            "$(json_str "${CFG_INTERVAL}")"
printf '    "disable_auto_update": %s,\n' "$(json_bool "$(cfg_bool DISABLE_AUTO_UPDATE 1)")"
printf '    "disable_web_ssh": %s\n'      "$(json_bool "$(cfg_bool DISABLE_WEB_SSH 1)")"
printf '  },\n'

printf '  "binary": {\n'
printf '    "path": %s,\n'           "$(json_str "${BIN_DST}")"
printf '    "installed": %s,\n'      "$(json_bool "${BIN_INSTALLED}")"
printf '    "size": %s,\n'           "${BIN_SIZE}"
printf '    "version": %s,\n'        "$(json_str "${UPSTREAM_VERSION}")"
printf '    "sha256_ok": %s,\n'      "$(json_bool "${SHA256_OK}")"
printf '    "sha256_checked": %s,\n' "$(json_bool "${SHA256_CHECKED}")"
printf '    "cache_path": %s,\n'     "$(json_str "${BIN_CACHE}")"
printf '    "cache_present": %s,\n'  "$(json_bool "${CACHE_PRESENT}")"
printf '    "cache_size": %s\n'      "${CACHE_SIZE}"
printf '  },\n'

printf '  "service": {\n'
printf '    "running": %s,\n'           "$(json_bool "${SERVICE_RUNNING}")"
printf '    "supervised": %s,\n'        "$(json_bool "${SERVICE_SUPERVISED}")"
printf '    "supervisor_pid": %s,\n'    "${SUPERVISOR_PID}"
printf '    "supervisor_uptime": %s,\n' "${SUPERVISOR_UPTIME}"
printf '    "agent_pids": [%s],\n'      "${AGENT_PIDS_JSON}"
printf '    "agent_pid": %s,\n'         "${AGENT_PID}"
printf '    "agent_uptime": %s,\n'      "${AGENT_UPTIME}"
printf '    "pidfile": %s,\n'           "$(json_str "${PID_FILE}")"
printf '    "pidfile_present": %s\n'    "$(json_bool "${PIDFILE_PRESENT}")"
printf '  },\n'

printf '  "log": {\n'
printf '    "path": %s,\n'        "$(json_str "${LOG_FILE}")"
printf '    "present": %s,\n'     "$(json_bool "${LOG_PRESENT}")"
printf '    "size": %s,\n'        "${LOG_SIZE}"
printf '    "modified_at": %s,\n' "${LOG_MTIME}"
printf '    "lines": [%s]\n'      "${LOG_LINES_JSON}"
printf '  },\n'

printf '  "traffic": {\n'
printf '    "file": %s,\n'        "$(json_str "${NET_STATIC}")"
printf '    "present": %s,\n'     "$(json_bool "${TRAFFIC_PRESENT}")"
printf '    "size": %s,\n'        "${TRAFFIC_SIZE}"
printf '    "modified_at": %s\n'  "${TRAFFIC_MTIME}"
printf '  }\n'

printf '}\n'

exit 0
