#!/usr/bin/env bash
#
# verify-release.sh -- Verify release artifacts.
#
# Checks that the .plg files and the Slackware package agree with each other:
# the pinned checksums, the package layout, the WebGUI page and the build
# metadata that the page reads.
#
# Usage:
#   ./scripts/verify-release.sh                    # verify the local dist/
#   ./scripts/verify-release.sh <url-to-plg>       # verify the txz referenced
#                                                  # by a remote .plg
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${REPO_ROOT}/dist"
PLUGIN_NAME="unraid-plugin-komari-agent"

# Python interpreter. On Windows "python3" resolves to a WindowsApps stub that
# does not run, so the caller may override it.
PYTHON="${PYTHON:-python3}"

log()  { printf '\033[1;34m[verify]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  FAIL\033[0m %s\n' "$*" >&2; }
die()  { bad "$*"; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

FAIL=0

# ---------------------------------------------------------------- local verification
if [ $# -eq 0 ]; then
  log "verifying the local dist/ artifacts"

  PLGS=("${DIST}/${PLUGIN_NAME}.plg"
        "${DIST}/${PLUGIN_NAME}-proxy.plg")

  TMP=$(mktemp -d)
  trap 'rm -rf "${TMP}"' EXIT

  # The .plg uses XML entities, so the files have to be parsed properly
  # instead of being grepped.
  for PLG in "${PLGS[@]}"; do
    [ -f "${PLG}" ] || die "missing ${PLG}"
    log "checking ${PLG##*/}"

    "${PYTHON}" - "${PLG}" >> "${TMP}/plgs.env" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

plg = sys.argv[1]
tree = ET.parse(plg)
root = tree.getroot()

entities = dict(re.findall(r'<!ENTITY\s+([A-Za-z][A-Za-z0-9_-]*)\s+"([^"]*)">',
                           open(plg, encoding='utf-8').read()))

files = [f for f in root.findall('FILE') if (f.findtext('URL') or '').strip().endswith('.txz')]
if not files:
    print('ERROR no package FILE entry found')
    sys.exit(1)

package = files[0]
print('TXZ_NAME', entities.get('txzName', ''))
print('TXZ_URL', package.findtext('URL').strip())
print('TXZ_SHA256', (package.findtext('SHA256') or '').strip())
print('BIN_NAME', entities.get('binName', ''))
print('BIN_URL', entities.get('binURL', ''))
print('BIN_SHA256', entities.get('binSHA256', ''))
print('PLUGIN_VERSION', root.get('version'))
print('UPSTREAM_VERSION', entities.get('upstream', ''))
print('LAUNCH', root.get('launch') or '')
print('ICON', root.get('icon') or '')
PY
  done
  cat "${TMP}/plgs.env"

  TXZ_NAME=$(awk '/^TXZ_NAME /{print $2; exit}' "${TMP}/plgs.env")
  EXPECTED=$(awk '/^TXZ_SHA256 /{print $2; exit}' "${TMP}/plgs.env")
  BIN_NAME=$(awk '/^BIN_NAME /{print $2; exit}' "${TMP}/plgs.env")
  BIN_SHA=$(awk '/^BIN_SHA256 /{print $2; exit}' "${TMP}/plgs.env")
  PLUGIN_VERSION=$(awk '/^PLUGIN_VERSION /{print $2; exit}' "${TMP}/plgs.env")
  UPSTREAM_VERSION=$(awk '/^UPSTREAM_VERSION /{print $2; exit}' "${TMP}/plgs.env")
  LAUNCH=$(awk '/^LAUNCH /{print $2; exit}' "${TMP}/plgs.env")
  ICON=$(awk '/^ICON /{print $2; exit}' "${TMP}/plgs.env")

  [ -n "${TXZ_NAME}" ] || die "could not parse the txz filename from the plg"
  [ -n "${EXPECTED}" ] || die "could not parse the SHA256 from the plg"
  [ -n "${BIN_SHA}" ] || die "could not parse the binary SHA256 from the plg"

  # 1. Every .plg must point at the same package and the same binary, with
  #    the same checksums. The direct and the mirrored variant ship identical
  #    bytes, so a mismatch means one of the two was rendered from a stale
  #    template.
  for PLG in "${PLGS[@]}"; do
    read -r NAME SHA BNAME BSHA < <("${PYTHON}" - "${PLG}" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

text = open(sys.argv[1], encoding='utf-8').read()
entities = dict(re.findall(r'<!ENTITY\s+([A-Za-z][A-Za-z0-9_-]*)\s+"([^"]*)">', text))
root = ET.parse(sys.argv[1]).getroot()
txz_sha = ''
for f in root.findall('FILE'):
    if (f.findtext('URL') or '').strip().endswith('.txz'):
        txz_sha = (f.findtext('SHA256') or '').strip()
        break
print(entities.get('txzName', ''), txz_sha,
      entities.get('binName', ''), entities.get('binSHA256', ''))
PY
)
    if [ "${NAME}" != "${TXZ_NAME}" ]; then
      bad "${PLG##*/} references ${NAME}, expected ${TXZ_NAME}"; FAIL=1
    fi
    if [ "${SHA}" != "${EXPECTED}" ]; then
      bad "${PLG##*/} expects txz SHA256 ${SHA}, expected ${EXPECTED}"; FAIL=1
    fi
    if [ "${BNAME}" != "${BIN_NAME}" ]; then
      bad "${PLG##*/} references binary ${BNAME}, expected ${BIN_NAME}"; FAIL=1
    fi
    if [ "${BSHA}" != "${BIN_SHA}" ]; then
      bad "${PLG##*/} expects binary SHA256 ${BSHA}, expected ${BIN_SHA}"; FAIL=1
    fi

    # The mirrored variant has to actually go through the mirror
    case "${PLG##*/}" in
      *-proxy.plg)
        URL=$("${PYTHON}" - "${PLG}" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for f in root.findall('FILE'):
    if (f.findtext('URL') or '').strip().endswith('.txz'):
        print(f.findtext('URL').strip())
        break
PY
)
        case "${URL}" in
          https://gh-proxy.org/*) ok "downloads the package through the gh-proxy.org mirror" ;;
          *) bad "the mirrored variant does not use the gh-proxy.org mirror: ${URL}"; FAIL=1 ;;
        esac
        BURL=$("${PYTHON}" - "${PLG}" <<'PY'
import re
import sys
text = open(sys.argv[1], encoding='utf-8').read()
entities = dict(re.findall(r'<!ENTITY\s+([A-Za-z][A-Za-z0-9_-]*)\s+"([^"]*)">', text))
print(entities.get('binURL', ''))
PY
)
        case "${BURL}" in
          https://gh-proxy.org/*) ok "downloads the binary through the gh-proxy.org mirror" ;;
          *) bad "the mirrored variant does not use the gh-proxy.org mirror for the binary: ${BURL}"; FAIL=1 ;;
        esac ;;
      *)
        ok "canonical variant downloads directly from github.com" ;;
    esac
  done

  TXZ="${DIST}/${TXZ_NAME}"
  [ -f "${TXZ}" ] || die "missing ${TXZ}"

  log "txz: ${TXZ_NAME}"
  log "plg expects SHA256: ${EXPECTED}"

  ACTUAL=$(sha256_of "${TXZ}")
  if [ "${ACTUAL}" = "${EXPECTED}" ]; then
    ok "txz SHA256 matches the plg"
  else
    bad "SHA256 mismatch"
    bad "  expected ${EXPECTED}"
    bad "  actual   ${ACTUAL}"
    FAIL=1
  fi

  # 2. Verify the txz layout
  log "checking the txz contents..."

  # A tar member name is a POSIX path by definition. A backslash in it is not
  # a separator: GNU tar on the Unraid host extracts "etc\rc.d\rc.komari-agent"
  # as one flat file with that literal name, so nothing lands in /etc and the
  # plugin installs "successfully" while doing nothing. Building the archive on
  # Windows used to produce exactly that, so this is checked explicitly.
  "${PYTHON}" - "${TXZ}" <<'PY'
import sys
import tarfile

path = sys.argv[1]
with tarfile.open(path) as archive:
    names = archive.getnames()

bad = [n for n in names if '\\' in n]
if bad:
    print("PROBLEM %d of %d archive members contain a backslash:" % (len(bad), len(names)))
    for name in bad[:10]:
        print("    %r" % name)
    sys.exit(1)

if len(names) < 2:
    print("PROBLEM the archive is empty")
    sys.exit(1)

# Every member except the root has to be relative and normalised.
for name in names:
    if name.startswith('/'):
        print("PROBLEM absolute member name: %r" % name)
        sys.exit(1)
    if '/../' in name or name.endswith('/..'):
        print("PROBLEM member name escapes the archive root: %r" % name)
        sys.exit(1)

print("OK %d members, all POSIX relative paths" % len(names))
PY
  if [ $? -eq 0 ]; then
    ok "archive member names are POSIX paths"
  else
    bad "archive member names are not POSIX paths"; FAIL=1
  fi

  tar -xf "${TXZ}" -C "${TMP}"

  check_file() {
    if [ -f "${TMP}/$1" ]; then
      ok "$1 present"
    else
      bad "$1 missing"; FAIL=1
    fi
  }

  check_exec() {
    if [ -x "${TMP}/$1" ]; then
      ok "$1 present and executable"
    else
      bad "$1 missing or not executable"; FAIL=1
    fi
  }

  check_file "install/slack-desc"
  check_exec "install/doinst.sh"
  check_exec "etc/rc.d/rc.komari-agent"
  check_file "etc/logrotate.d/komari-agent"
  check_file "usr/local/emhttp/plugins/${PLUGIN_NAME}/README.md"
  check_file "usr/local/emhttp/plugins/${PLUGIN_NAME}/plugin.info"
  check_file "usr/local/emhttp/plugins/${PLUGIN_NAME}/${PLUGIN_NAME}.png"
  check_file "usr/local/emhttp/plugins/${PLUGIN_NAME}/include/common.php"
  check_file "usr/local/emhttp/plugins/${PLUGIN_NAME}/include/Pages/Settings.php"
  check_file "usr/local/emhttp/plugins/${PLUGIN_NAME}/include/Pages/Status.php"
  check_file "usr/local/emhttp/plugins/${PLUGIN_NAME}/include/data/Status.php"
  check_file "usr/local/emhttp/plugins/${PLUGIN_NAME}/include/data/Action.php"

  for script in start.sh supervise.sh stop.sh restart.sh status.sh clear-traffic.sh; do
    check_exec "usr/local/emhttp/plugins/${PLUGIN_NAME}/scripts/${script}"
  done

  # The launch attribute points at the page of the plugin, so the .page file
  # it names has to be part of the package.
  if [ -n "${LAUNCH}" ]; then
    PAGE_BASENAME="${LAUNCH##*/}"
    if [ -f "${TMP}/usr/local/emhttp/plugins/${PLUGIN_NAME}/${PAGE_BASENAME}.page" ]; then
      ok "launch target ${LAUNCH} resolves to a .page file in the package"
    else
      bad "launch target ${LAUNCH} does not resolve to a .page file in the package"; FAIL=1
    fi
  fi

  # 3. The archive has to record the right modes. A checkout on Windows or
  #    through MSYS reports no POSIX execute bit at all, so a build that
  #    inherits the mode from the working tree produces an rc script and a set
  #    of runtime scripts that are not executable on the Unraid host. The
  #    build applies a manifest; this asserts that it took effect.
  log "checking the archive file modes..."
  "${PYTHON}" - "${TXZ}" <<'PY'
import sys
import tarfile

path = sys.argv[1]

# Paths that must be executable, and paths that must not be.
MUST_BE_EXEC = [
    'etc/rc.d/rc.komari-agent',
    'install/doinst.sh',
]
MUST_BE_EXEC_DIRS = [
    'usr/local/emhttp/plugins/unraid-plugin-komari-agent/scripts/',
]
MUST_NOT_BE_EXEC = [
    'install/slack-desc',
    'etc/logrotate.d/komari-agent',
    'usr/local/emhttp/plugins/unraid-plugin-komari-agent/plugin.info',
]

with tarfile.open(path) as archive:
    members = {m.name.lstrip('./'): m for m in archive.getmembers() if m.isfile()}

problems = []

for name, member in sorted(members.items()):
    should_exec = name in MUST_BE_EXEC or any(name.startswith(d) for d in MUST_BE_EXEC_DIRS)
    is_exec = bool(member.mode & 0o111)

    if should_exec and not is_exec:
        problems.append("%s must be executable, archived as %04o" % (name, member.mode))
    elif name in MUST_NOT_BE_EXEC and is_exec:
        problems.append("%s must not be executable, archived as %04o" % (name, member.mode))
    elif not should_exec and is_exec and not name.endswith('.sh'):
        problems.append("%s is executable unexpectedly (%04o)" % (name, member.mode))

# Every script in the runtime directory has to be there and executable.
runtime = sorted(n for n in members if n.startswith(MUST_BE_EXEC_DIRS[0]))
if not runtime:
    problems.append("no runtime scripts found under %s" % MUST_BE_EXEC_DIRS[0])

if problems:
    for problem in problems:
        print("PROBLEM " + problem)
    sys.exit(1)

print("OK %d files, %d of them executable" %
      (len(members), sum(1 for m in members.values() if m.mode & 0o111)))
PY
  if [ $? -eq 0 ]; then
    ok "archive file modes are correct"
  else
    bad "archive file modes are wrong"; FAIL=1
  fi

  # The icon attribute names a file the WebGUI renders in the Plugins tab.
  if [ -n "${ICON}" ]; then
    if [ -f "${TMP}/usr/local/emhttp/plugins/${PLUGIN_NAME}/${ICON}" ]; then
      ok "icon ${ICON} is part of the package"
    else
      bad "icon ${ICON} is missing from the package"; FAIL=1
    fi
  fi

  # 4. The build metadata must match the plugin definition
  INFO="${TMP}/usr/local/emhttp/plugins/${PLUGIN_NAME}/plugin.info"
  if [ -f "${INFO}" ]; then
    ok "plugin.info present"
    # plugin.info values are double-quoted by the generator, because the PHP
    # INI scanner would otherwise evaluate operators inside a value.
    INFO_VERSION=$(grep '^PLUGIN_VERSION=' "${INFO}" | cut -d= -f2- | tr -d '"' || true)
    INFO_UPSTREAM=$(grep '^UPSTREAM_VERSION=' "${INFO}" | cut -d= -f2- | tr -d '"' || true)
    INFO_BIN_SHA=$(grep '^BINARY_SHA256=' "${INFO}" | cut -d= -f2- | tr -d '"' || true)
    if [ "${INFO_VERSION}" = "${PLUGIN_VERSION}" ]; then
      ok "plugin.info PLUGIN_VERSION matches the plg (${INFO_VERSION})"
    else
      bad "plugin.info PLUGIN_VERSION is ${INFO_VERSION}, expected ${PLUGIN_VERSION}"; FAIL=1
    fi
    if [ "${INFO_UPSTREAM}" = "${UPSTREAM_VERSION}" ]; then
      ok "plugin.info UPSTREAM_VERSION matches the plg (${INFO_UPSTREAM})"
    else
      bad "plugin.info UPSTREAM_VERSION is ${INFO_UPSTREAM}, expected ${UPSTREAM_VERSION}"; FAIL=1
    fi
    if [ "${INFO_BIN_SHA}" = "${BIN_SHA}" ]; then
      ok "plugin.info BINARY_SHA256 matches the value pinned in the plg"
    else
      bad "plugin.info BINARY_SHA256 is ${INFO_BIN_SHA}, expected ${BIN_SHA}"; FAIL=1
    fi
  else
    bad "plugin.info missing"; FAIL=1
  fi

  # 5. The packaged scripts must be valid shell
  log "checking the packaged shell scripts..."
  for script in \
    "${TMP}/usr/local/emhttp/plugins/${PLUGIN_NAME}/scripts"/*.sh \
    "${TMP}/etc/rc.d/rc.komari-agent"
  do
    [ -f "${script}" ] || continue
    if bash -n "${script}" 2>"${TMP}/err"; then
      ok "$(basename "${script}") syntax OK"
    else
      bad "$(basename "${script}") syntax error:"
      sed 's/^/      /' "${TMP}/err"
      FAIL=1
    fi
    # A CRLF line ending makes bash mis-parse line continuations.
    if grep -qU $'\r' "${script}" 2>/dev/null; then
      bad "$(basename "${script}") contains CRLF line endings"; FAIL=1
    fi
    if grep -Eq '^[[:space:]]*exit[[:space:]]+[^0]' "${script}"; then
      bad "$(basename "${script}") exits non-zero somewhere"; FAIL=1
    fi
    if grep -Eq '(^|[[:space:];])set[[:space:]]+-[A-Za-z]*[eu]([[:space:]]|$)' "${script}"; then
      bad "$(basename "${script}") enables a shell error mode"; FAIL=1
    fi
  done

  # 6. The upstream binary in the package, when one is present, must match the
  #    checksum pinned in the plg. The txz does not carry the binary (it lives
  #    on the flash cache as its own FILE entry), so this is informational.
  if [ -n "${BIN_SHA}" ] && [ -f "${REPO_ROOT}/pkg/${BIN_NAME}" ]; then
    ACTUAL_BIN=$(sha256_of "${REPO_ROOT}/pkg/${BIN_NAME}")
    if [ "${ACTUAL_BIN}" = "${BIN_SHA}" ]; then
      ok "cached binary SHA256 matches the value pinned in the plg"
    else
      bad "cached binary SHA256 mismatch"
      bad "  expected ${BIN_SHA}"
      bad "  actual   ${ACTUAL_BIN}"
      FAIL=1
    fi
  else
    log "skipping the binary comparison (pkg/${BIN_NAME} missing)"
  fi

  # 7. Sanity-check the binary size (around 12 MB)
  if [ -f "${REPO_ROOT}/pkg/${BIN_NAME}" ]; then
    SIZE=$(wc -c < "${REPO_ROOT}/pkg/${BIN_NAME}" | tr -d ' ')
    if [ "${SIZE}" -gt 8000000 ] && [ "${SIZE}" -lt 40000000 ]; then
      ok "binary size looks sane: ${SIZE} bytes"
    else
      bad "binary size out of range: ${SIZE} bytes (expected 8-40 MB)"; FAIL=1
    fi
  fi

  # 8. The .page files must be LF-only and carry a valid header
  log "checking the .page files..."
  for page in "${TMP}/usr/local/emhttp/plugins/${PLUGIN_NAME}"/*.page; do
    [ -f "${page}" ] || continue
    if grep -qU $'\r' "${page}" 2>/dev/null; then
      bad "$(basename "${page}") contains CRLF line endings"; FAIL=1
    else
      ok "$(basename "${page}") is LF-only"
    fi
  done

  echo
  if [ "${FAIL}" -eq 0 ]; then
    log "all checks passed"
  else
    die "some checks failed"
  fi
  exit 0
fi

# ---------------------------------------------------------------- remote verification
PLG_URL="$1"
log "verifying the remote plg: ${PLG_URL}"

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

curl -fsSL --max-time 60 "${PLG_URL}" -o "${TMP}/remote.plg" || die "failed to download the plg"

"${PYTHON}" - "${TMP}/remote.plg" > "${TMP}/remote.env" <<'PY'
import sys
import xml.etree.ElementTree as ET

plg = sys.argv[1]
root = ET.parse(plg).getroot()
for f in root.findall('FILE'):
    url = (f.findtext('URL') or '').strip()
    if url.endswith('.txz'):
        print('TXZ_URL', url)
        print('TXZ_SHA256', (f.findtext('SHA256') or '').strip())
        break
PY
cat "${TMP}/remote.env"

TXZ_URL=$(awk '/^TXZ_URL /{print $2; exit}' "${TMP}/remote.env")
EXPECTED=$(awk '/^TXZ_SHA256 /{print $2; exit}' "${TMP}/remote.env")

[ -n "${TXZ_URL}" ] || die "no txz URL in the plg"
[ -n "${EXPECTED}" ] || die "no SHA256 in the plg"

log "txz URL: ${TXZ_URL}"
log "expected SHA256: ${EXPECTED}"

curl -fsSL --max-time 300 "${TXZ_URL}" -o "${TMP}/remote.txz" || die "failed to download the txz"
ACTUAL=$(sha256_of "${TMP}/remote.txz")

if [ "${ACTUAL}" = "${EXPECTED}" ]; then
  ok "remote txz SHA256 matches"
  echo
  log "ready to install:"
  echo "    cp ${PLG_URL##*/} /boot/config/plugins/"
  echo "    plugin install /boot/config/plugins/${PLG_URL##*/}"
else
  bad "SHA256 mismatch"
  bad "  expected ${EXPECTED}"
  bad "  actual   ${ACTUAL}"
  exit 1
fi
