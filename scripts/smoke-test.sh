#!/usr/bin/env bash
#
# smoke-test.sh -- Exercise the plugin's runtime logic on this machine.
#
# The plugin targets Unraid, which is not available on the build machine, so
# this script cannot run the real installer. What it can do is take the
# package apart and run every shell script under a fake root, with the paths
# redirected through a small shim. That catches the mistakes that a static
# lint cannot: a script that dies on an unset variable, a config reader that
# does not parse the file the WebGUI writes, a start script that starts two
# instances, a stop script that leaves a process behind.
#
# Usage:
#   ./scripts/smoke-test.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${REPO_ROOT}/dist"
PLUGIN_NAME="unraid-plugin-komari-agent"
PYTHON="${PYTHON:-python3}"

log()  { printf '\033[1;34m[smoke ]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  FAIL\033[0m %s\n' "$*" >&2; FAIL=1; }
die()  { bad "$*"; exit 1; }

FAIL=0

# `set -e` aborts on a failed assignment, so the empty case has to be
# neutralised here; otherwise the friendly message below is never reached
# and the script dies with a bare exit status and no output.
TXZ=$(ls "${DIST}/${PLUGIN_NAME}-"*.txz 2>/dev/null | head -1 || true)
[ -n "${TXZ}" ] || die "no package in dist/; run ./scripts/build-plugin.sh first"

WORK=$(mktemp -d)

# The sandbox is removed at the end of the run, not from an EXIT trap. A trap
# cannot be made reliable here: stop.sh may fail to end the supervisor (MSYS
# cannot deliver a signal to a Windows process), the following rm then fails
# with "Device or resource busy", and the wrapper this shell runs under ends
# the script at that point, so a status re-raised from the trap would never be
# seen. The explicit sequence at the bottom of the file reports the result
# before it cleans up, and leaves the directory in place when something is
# still holding it, with a message saying so.

log "unpacking $(basename "${TXZ}") ..."
mkdir -p "${WORK}/pkg"
tar -xf "${TXZ}" -C "${WORK}/pkg"

PLUGIN_DIR="${WORK}/pkg/usr/local/emhttp/plugins/${PLUGIN_NAME}"
[ -d "${PLUGIN_DIR}/scripts" ] || die "the package has no scripts/ directory"

# ---------------------------------------------------------------- 1. cfg parsing
# The WebGUI writes the config through /update.php, which emits
# KEY="value" lines. Every script reads it through the same helper, so the
# helper is what gets tested here.
log "checking the config reader..."
CFG="${WORK}/komari-agent.cfg"
cat > "${CFG}" <<'EOF'
ENABLED="1"
ENDPOINT="https://komari.example.com"
TOKEN="0123456789abcdef0123456789abcdef"
INTERVAL="3"
DISABLE_AUTO_UPDATE="1"
DISABLE_WEB_SSH="1"
IGNORE_UNSAFE_CERT="0"
INCLUDE_NICS=""
EXCLUDE_NICS=""
INCLUDE_MOUNTPOINTS=""
MONTH_ROTATE="0"
MEMORY_INCLUDE_CACHE="1"
MEMORY_REPORT_RAW_USED="0"
ENABLE_GPU="0"
CUSTOM_DNS=""
PREFER_IP_VERSION=""
EXTRA_ARGS=""
EOF

# The scripts source a shared library, which is the piece that has to be
# correct. Locate it by name rather than assuming a file layout.
LIB=$(grep -rl 'read_cfg\|cfg_get\|ka_cfg' "${PLUGIN_DIR}/scripts" 2>/dev/null | head -1 || true)
if [ -z "${LIB}" ]; then
  log "no shared config helper found; the scripts parse the cfg inline"
else
  ok "shared helper: $(basename "${LIB}")"
fi

# ---------------------------------------------------------------- 2. shell syntax
log "checking the packaged scripts..."
for script in "${PLUGIN_DIR}"/scripts/*.sh "${WORK}/pkg/etc/rc.d/rc.komari-agent"; do
  [ -f "${script}" ] || continue
  if bash -n "${script}" 2>"${WORK}/err"; then
    ok "$(basename "${script}") syntax OK"
  else
    bad "$(basename "${script}") syntax error:"
    sed 's/^/      /' "${WORK}/err"
    continue
  fi

  # A script that is not executable inside the package is a broken plugin.
  case "${script}" in
    *.sh|*/rc.*)
      if [ -x "${script}" ]; then
        ok "$(basename "${script}") is executable"
      else
        bad "$(basename "${script}") is not executable"
      fi ;;
  esac

  # The installer aborts the whole install on a non-zero exit.
  if grep -Eq '^[[:space:]]*exit[[:space:]]+[^0]' "${script}"; then
    bad "$(basename "${script}") contains a non-zero exit"
  fi
  if grep -Eq '(^|[[:space:];])set[[:space:]]+-[A-Za-z]*[eu]([[:space:]]|$)' "${script}"; then
    bad "$(basename "${script}") enables a shell error mode"
  fi

  # The agent token must never appear on a command line: every local user can
  # read /proc/<pid>/cmdline. lib.sh deliberately mentions "--token" in the
  # guard that rejects a token inside EXTRA_ARGS, so only an actual invocation
  # counts as a leak: the flag has to be followed by a variable expansion, not
  # by a literal pattern match.
  if grep -En -- '(^|[^a-zA-Z_])--token[[:space:]]+["'"'"']?\$' "${script}"; then
    bad "$(basename "${script}") passes --token on the command line"
  fi
done

# ---------------------------------------------------------------- 3. dry run of start/stop
# Run start.sh with every absolute path redirected into the sandbox. The agent
# binary is replaced by a stub that just sleeps, so nothing touches the
# network and nothing can be left running.
log "dry running start/stop under a fake root..."
FAKE="${WORK}/root"
mkdir -p "${FAKE}/usr/local/sbin" "${FAKE}/var/log" "${FAKE}/var/run" "${FAKE}/etc/rc.d" \
         "${FAKE}/boot/config/plugins/${PLUGIN_NAME}" "${FAKE}/usr/local/emhttp/plugins"

cp -a "${PLUGIN_DIR}" "${FAKE}/usr/local/emhttp/plugins/${PLUGIN_NAME}"
cp "${CFG}" "${FAKE}/boot/config/plugins/${PLUGIN_NAME}/komari-agent.cfg"

# A stand-in for the real agent: it accepts the same environment, prints a
# line so the log path can be checked, and sleeps until it is signalled.
cat > "${FAKE}/usr/local/sbin/komari-agent" <<'STUB'
#!/bin/bash
echo "stub agent started pid=$$ endpoint=${AGENT_ENDPOINT:-unset}"
trap 'echo "stub agent stopping pid=$$"; exit 0' TERM INT
while :; do sleep 1; done
STUB
chmod 0755 "${FAKE}/usr/local/sbin/komari-agent"

# Redirect the hard coded host paths into the sandbox. The scripts are written
# for the real host, so this is a textual rewrite of a copy, not of the
# shipped file.
#
# The pgrep pattern is rewritten too. It is a literal path prefix, and leaving
# it pointing at /usr/local/sbin would make agent_pids() report nothing under
# the sandbox -- the test would then pass while never exercising the process
# detection it is supposed to check.
rewrite() {
  local target="$1"
  sed -i \
    -e "s|/usr/local/sbin|${FAKE}/usr/local/sbin|g" \
    -e "s|/var/log|${FAKE}/var/log|g" \
    -e "s|/var/run|${FAKE}/var/run|g" \
    -e "s|/boot/config/plugins|${FAKE}/boot/config/plugins|g" \
    -e "s|/usr/local/emhttp/plugins|${FAKE}/usr/local/emhttp/plugins|g" \
    -e "s|/etc/rc.d|${FAKE}/etc/rc.d|g" \
    "${target}"
}

for script in "${FAKE}/usr/local/emhttp/plugins/${PLUGIN_NAME}/scripts"/*.sh; do
  [ -f "${script}" ] || continue
  rewrite "${script}"
done

START="${FAKE}/usr/local/emhttp/plugins/${PLUGIN_NAME}/scripts/start.sh"
STOP="${FAKE}/usr/local/emhttp/plugins/${PLUGIN_NAME}/scripts/stop.sh"
STATUS="${FAKE}/usr/local/emhttp/plugins/${PLUGIN_NAME}/scripts/status.sh"

# The supervisor is started with its output redirected to the log, but it
# still holds the pipe this script's stdout may point at. Reading a command's
# output through $( ) or a redirect would therefore block until the supervisor
# exits, which is never. Every invocation below is written to a file and the
# file is read afterwards, and the script itself is run with its stdout on a
# file rather than a pipe.
run_to_file() {
  local out="$1"
  shift
  "$@" >"${out}" 2>&1 </dev/null
}

if [ -f "${START}" ]; then
  if bash "${START}" >"${WORK}/start.log" 2>&1 </dev/null; then
    ok "start.sh exited 0"
  else
    bad "start.sh exited non-zero:"
    sed 's/^/      /' "${WORK}/start.log"
  fi

  sleep 2
  if [ -f "${FAKE}/var/run/komari-agent.pid" ]; then
    ok "start.sh wrote a pidfile"
    PID=$(cat "${FAKE}/var/run/komari-agent.pid" 2>/dev/null | tr -d '[:space:]')
    if [ -n "${PID}" ] && kill -0 "${PID}" 2>/dev/null; then
      ok "the supervisor is running (pid ${PID})"
    else
      bad "the pidfile points at a process that is not running (${PID:-empty})"
    fi
  else
    bad "start.sh did not write ${FAKE}/var/run/komari-agent.pid"
  fi

  # A second start must not spawn a second instance.
  if bash "${START}" >"${WORK}/start2.log" 2>&1 </dev/null; then
    ok "a second start.sh exited 0"
  else
    bad "a second start.sh exited non-zero"
  fi

  # Count the supervisors, not every process whose command line mentions the
  # agent: a supervisor plus its child is two processes by design.
  #
  # Process inspection and signal delivery do not work in this environment.
  # MSYS on Windows provides a pgrep shim whose behaviour cannot be trusted
  # (it answers for names it does not provide, and exits 127 for real
  # invocations), and a signal cannot be delivered to a Windows process from
  # MSYS at all. So the process detection code cannot be exercised here.
  # Saying so is better than a check that silently passes: the real
  # verification has to happen on a Unraid host, and that is recorded as an
  # open item in the verification log.
  log "process inspection is not available in this environment, skipping the process detection checks"
  log "(pgrep and cross-process signals are Unraid-only; see docs/03-verification-log.md)"

  if [ -f "${STATUS}" ]; then
    if bash "${STATUS}" >"${WORK}/status.out" 2>&1 </dev/null; then
      ok "status.sh exited 0"
      # The JSON still has to be well formed and carry the documented shape.
      # This is the part that can be checked here, and it is the part the
      # WebGUI actually consumes.
      if "${PYTHON}" - "${WORK}/status.out" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding='utf-8') as handle:
        data = json.load(handle)
except Exception as error:  # noqa: BLE001 - the message is what matters
    print("not valid JSON: %s" % error)
    sys.exit(1)

problems = []
if data.get('schema') != 'komari-agent-status/1':
    problems.append('schema is %r' % data.get('schema'))

for section in ('plugin', 'config', 'binary', 'service', 'log', 'traffic'):
    if section not in data:
        problems.append('missing section %r' % section)

# The token must never be part of the status output.
def walk(node, path=''):
    if isinstance(node, dict):
        for key, value in node.items():
            yield from walk(value, path + '/' + key)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from walk(value, path + '/%d' % index)
    else:
        yield path, node

for path, value in walk(data):
    if isinstance(value, str) and len(value) >= 16 and path.endswith('token'):
        problems.append('the token appears to be echoed at %s' % path)

if problems:
    for problem in problems:
        print("PROBLEM " + problem)
    sys.exit(1)

print("OK schema, %d sections" % len([k for k in data if k != 'schema']))
PY
      then
        ok "status.sh emits valid JSON with the documented schema"
      else
        bad "status.sh did not emit valid JSON with the documented schema"
      fi
    else
      bad "status.sh exited non-zero"
    fi
  fi

  log "status.sh output:"
  [ -f "${WORK}/status.out" ] && sed 's/^/      /' "${WORK}/status.out"

  if [ -f "${STOP}" ]; then
    if bash "${STOP}" >"${WORK}/stop.log" 2>&1 </dev/null; then
      ok "stop.sh exited 0"
    else
      bad "stop.sh exited non-zero"
    fi
    sleep 2
    if [ -f "${FAKE}/var/run/komari-agent.pid" ]; then
      bad "stop.sh left the pidfile behind"
    else
      ok "stop.sh removed the pidfile"
    fi
    # A second stop must be a no-op, not an error.
    if bash "${STOP}" >>"${WORK}/stop.log" 2>&1 </dev/null; then
      ok "a second stop.sh exited 0 (idempotent)"
    else
      bad "a second stop.sh exited non-zero"
    fi
  else
    log "stop.sh not found, skipping the stop checks"
  fi
else
  log "start.sh not found, skipping the lifecycle checks"
fi

# ---------------------------------------------------------------- 4. disabled config
# With ENABLED=0 the start script must do nothing and still exit 0.
if [ -f "${START}" ]; then
  log "checking that ENABLED=0 prevents a start..."
  sed -i 's/^ENABLED=.*/ENABLED="0"/' "${FAKE}/boot/config/plugins/${PLUGIN_NAME}/komari-agent.cfg"
  if bash "${START}" >"${WORK}/start-disabled.log" 2>&1 </dev/null; then
    ok "start.sh with ENABLED=0 exited 0"
    if grep -q 'stub agent started' "${WORK}/start-disabled.log"; then
      bad "start.sh started the agent even though ENABLED=0"
    else
      ok "start.sh did not start the agent"
    fi
  else
    bad "start.sh with ENABLED=0 exited non-zero"
  fi
  bash "${STOP}" >>"${WORK}/stop.log" 2>&1 || true
fi

# ---------------------------------------------------------------- 5. unconfigured
# With no endpoint the agent cannot do anything useful; the script must say so
# and exit 0 rather than crash-loop.
if [ -f "${START}" ]; then
  log "checking that an unconfigured agent does not start..."
  sed -i 's/^ENABLED=.*/ENABLED="1"/' "${FAKE}/boot/config/plugins/${PLUGIN_NAME}/komari-agent.cfg"
  sed -i 's|^ENDPOINT=.*|ENDPOINT=""|' "${FAKE}/boot/config/plugins/${PLUGIN_NAME}/komari-agent.cfg"
  if bash "${START}" >"${WORK}/start-unconfigured.log" 2>&1 </dev/null; then
    ok "start.sh without an endpoint exited 0"
    if grep -q 'stub agent started' "${WORK}/start-unconfigured.log"; then
      bad "start.sh started the agent without an endpoint"
    else
      ok "start.sh did not start the agent"
    fi
  else
    bad "start.sh without an endpoint exited non-zero"
  fi
  bash "${STOP}" >>"${WORK}/stop.log" 2>&1 || true
fi

# ---------------------------------------------------------------- result
echo

# Stop the service before reporting, so that the outcome and the cleanup are
# both observed. The sandbox is removed afterwards; when a leftover process
# still holds it the directory stays behind and that is reported, because a
# silent failure here would hide the very thing this script is looking for.
if [ -n "${FAKE:-}" ] && [ -x "${FAKE}/usr/local/emhttp/plugins/${PLUGIN_NAME}/scripts/stop.sh" ]; then
  bash "${FAKE}/usr/local/emhttp/plugins/${PLUGIN_NAME}/scripts/stop.sh" >/dev/null 2>&1 </dev/null
fi

if [ "${FAIL}" -eq 0 ]; then
  log "all smoke checks passed"
else
  printf '\033[1;31m[smoke ] some checks failed\033[0m\n' >&2
fi

if rm -rf "${WORK}" 2>/dev/null && [ ! -d "${WORK}" ]; then
  log "sandbox removed"
else
  log "the sandbox could not be removed (a process is still holding it): ${WORK}"
  log "this is expected on Windows, where a signal cannot end the supervisor;"
  log "on Unraid stop.sh ends it and the directory goes away"
fi

[ "${FAIL}" -eq 0 ] && exit 0
exit 1
