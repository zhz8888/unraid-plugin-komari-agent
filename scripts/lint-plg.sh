#!/usr/bin/env bash
#
# lint-plg.sh -- Static checks that a .plg satisfies the requirements of the
#                Unraid plugin installer and the conventions the official
#                Limetech plugins follow.
#
# Checks:
#   1. XML is well formed and the PLUGIN root carries the attributes the
#      Unraid plugin installer and the WebGUI read
#   2. The XML entities were expanded: no attribute value may still contain
#      an entity reference, and no CDATA section may contain one, because a
#      CDATA section is literal text
#   3. The version uses the official date based scheme and is not tied to the
#      bundled upstream version
#   4. The changelog follows the "##<name>" / "###<version>" layout
#   5. Every <FILE> pairs a URL with a SHA256, and the URL is https
#   6. Cached files live under /boot/config/plugins/<name>/
#   7. The INLINE bash scripts under <FILE Run> are syntactically valid
#   8. An install script (Method="install") and an uninstall script
#      (Method="remove") exist, the install script is idempotent and never
#      exits non-zero
#   9. No template placeholder survived the render
#  10. The launch target resolves to a .page file that the package ships
#
# Usage:
#   ./scripts/lint-plg.sh              # checks every .plg in dist/
#   ./scripts/lint-plg.sh path/to/plg  # checks the given file(s)
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Python interpreter. On Windows "python3" resolves to a WindowsApps stub that
# does not run, so the caller may override it: make lint PYTHON=D:/Python312/python.exe
PYTHON="${PYTHON:-python3}"
PLUGIN_NAME="unraid-plugin-komari-agent"

if [ $# -gt 0 ]; then
  PLGS=("$@")
else
  PLGS=("${REPO_ROOT}/dist/${PLUGIN_NAME}.plg"
        "${REPO_ROOT}/dist/${PLUGIN_NAME}-proxy.plg")
fi

FAIL=0
log() { printf '\033[1;34m[lint]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
bad() { printf '\033[1;31m  FAIL\033[0m %s\n' "$*" >&2; FAIL=1; }

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

for PLG in "${PLGS[@]}"; do
  [ -f "${PLG}" ] || { echo "not found: ${PLG}" >&2; exit 1; }
  log "checking ${PLG}"

  # ---------------------------------------------------------------- 1-5. XML, attributes, files
  "${PYTHON}" - "${PLG}" "${TMP}" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

plg, tmp = sys.argv[1], sys.argv[2]
fail = 0


def problem(message):
    global fail
    print(f"PROBLEM {message}")
    fail = 1


try:
    tree = ET.parse(plg)
except ET.ParseError as e:
    print(f"BADXML {e}")
    sys.exit(1)

root = tree.getroot()
if root.tag != 'PLUGIN':
    problem(f"root element must be PLUGIN, found {root.tag}")

# --- attributes the Unraid plugin installer and the WebGUI read ---------
required = ['name', 'author', 'version', 'pluginURL', 'support', 'min']
recommended = ['launch', 'icon']

for attr in required:
    if not root.get(attr):
        problem(f"missing required PLUGIN attribute: {attr}")
for attr in recommended:
    if not root.get(attr):
        print(f"WARN_MISSING {attr}")

name = root.get('name') or ''
version = root.get('version') or ''

# --- entity expansion ---------------------------------------------------
# XML entities are expanded in attribute values and in element text. If the
# parser did not expand them, the plugin would register under the literal
# name "&name;" and every path would be wrong.
for attr in ('name', 'author', 'version', 'pluginURL', 'support', 'min', 'launch', 'icon'):
    value = root.get(attr) or ''
    if '&' in value:
        problem(f"attribute {attr} still contains an entity reference: {value}")
if name and '&' in name:
    problem(f"the plugin name still contains an entity reference: {name}")

# --- version scheme ----------------------------------------------------
# The plugin version is the release date, YYYYMMDD. A second release on the
# same day adds a letter suffix: YYYYMMDD.a, YYYYMMDD.b and so on. The
# Unraid installer compares plugin versions with strcmp(), a byte wise string
# compare, so this format is what sorts in release order:
#   20261106 < 20261106.a < 20261106.b < 20261107
if not re.fullmatch(r'\d{8}(\.[a-z])?', version):
    problem(f"version '{version}' does not follow the release date scheme "
            f"YYYYMMDD, or YYYYMMDD.a when a day carries more than one release")

# The plugin version must not be the bundled upstream version: a repackaging
# of the same upstream release would then never reach installed users.
entities = dict(re.findall(r'<!ENTITY\s+([A-Za-z][A-Za-z0-9_-]*)\s+"([^"]*)">',
                           open(plg, encoding='utf-8').read()))
upstream = entities.get('upstream', '')
if upstream and version == upstream:
    problem("plugin version equals the upstream version; repackagings would not be offered as updates")

# --- changelog layout --------------------------------------------------
changes = root.findtext('CHANGES') or ''
if not changes.strip():
    problem("the CHANGES block is empty")
elif not changes.lstrip().startswith('##'):
    problem("the CHANGES block must start with '##<plugin name>'")

# --- files -------------------------------------------------------------
files = root.findall('FILE')
if not files:
    problem("the plugin declares no FILE entries")

install_scripts = 0
remove_scripts = 0
for i, f in enumerate(files):
    fname = f.get('Name') or ''
    furl = (f.findtext('URL') or '').strip()
    sha = (f.findtext('SHA256') or '').strip()
    method = f.get('Method') or 'install'
    run = f.get('Run') or ''
    inline = (f.findtext('INLINE') or '')

    if furl:
        if not sha:
            problem(f"FILE {i} ({fname or furl}) has a URL but no SHA256")
        elif not re.fullmatch(r'[0-9a-f]{64}', sha):
            problem(f"FILE {i} has a malformed SHA256: {sha}")
        if not furl.startswith('https://'):
            problem(f"FILE {i} uses an insecure URL: {furl}")

    if fname and not fname.startswith('/boot/config/plugins/'):
        problem(f"FILE {i} is not cached under /boot/config/plugins/: {fname}")
    if fname and name and not fname.startswith(f'/boot/config/plugins/{name}/'):
        problem(f"FILE {i} is not cached under /boot/config/plugins/{name}/: {fname}")

    if run:
        if method == 'remove':
            remove_scripts += 1
        else:
            install_scripts += 1
        if inline.strip():
            tag = 'remove' if method == 'remove' else 'install'
            path = f"{tmp}/inline-{i}-{tag}.sh"
            # newline='\n' keeps the extracted script LF-only on every
            # platform: a CRLF file makes bash mis-parse line continuations.
            with open(path, 'w', newline='\n') as fh:
                fh.write(inline)
            print(f"INLINE_SCRIPT {path}")

# --- entity references inside CDATA ------------------------------------
# Text inside a CDATA section is literal. An entity reference there is not
# expanded by the XML parser, it would end up in the script verbatim and
# break it. The build time placeholders have to be used instead.
cdata_text = changes
for f in files:
    cdata_text += (f.findtext('INLINE') or '')
for match in set(re.findall(r'&[A-Za-z][A-Za-z0-9_-]*;', cdata_text)):
    problem(f"entity reference {match} inside a CDATA section is not expanded by the XML parser")

if install_scripts == 0:
    problem("no install script (a FILE with a Run attribute) found")
if remove_scripts == 0:
    problem('no uninstall script (a FILE with Method="remove") found')

# --- launch target -----------------------------------------------------
# The launch attribute points at the page of the plugin, so the .page file
# it names has to be part of the package. That is checked against the txz in
# verify-release.sh; here only the shape of the value is validated.
launch = root.get('launch') or ''
if launch and not re.fullmatch(r'Settings/[A-Za-z0-9._-]+', launch):
    problem(f"launch attribute '{launch}' does not look like Settings/<PageName>")

print("OK" if fail == 0 else "FAIL")
sys.exit(1 if fail else 0)
PY

  PY_RC=$?
  if [ "${PY_RC}" -ne 0 ]; then
    bad "XML parsing or attribute check failed"
  fi

  # ---------------------------------------------------------------- 6. bash syntax
  log "checking inline script syntax..."
  for s in "${TMP}"/inline-*.sh; do
    [ -f "$s" ] || continue
    if bash -n "$s" 2>"${TMP}/err"; then
      ok "$(basename "$s") syntax OK"
    else
      bad "$(basename "$s") syntax error:"
      sed 's/^/      /' "${TMP}/err"
    fi
    rm -f "$s"
  done

  # ---------------------------------------------------------------- 7. idempotency
  log "checking idempotency..."
  if grep -q "upgradepkg --install-new" "${PLG}"; then
    ok "uses upgradepkg --install-new (idempotent)"
  else
    bad "upgradepkg --install-new not used; repeated runs at boot may fail"
  fi

  if grep -q 'rm -f' "${PLG}"; then
    ok "cleanup uses rm -f (idempotent)"
  fi

  if grep -q 'removepkg' "${PLG}"; then
    ok "uninstall removes the Slackware package"
  else
    bad "the uninstall script does not call removepkg"
  fi

  # The Unraid installer aborts the install when the install script exits
  # non-zero: the .plg is moved to /boot/config/plugins-error/ and no
  # /var/log/plugins symlink is created, so the plugin cannot be uninstalled
  # from the WebGUI any more.
  log "checking that the install script always exits zero..."
  if grep -Eq '^[[:space:]]*exit[[:space:]]+[^0]' "${PLG}"; then
    bad "the plugin scripts exit with a non-zero status; that aborts the install"
  else
    ok "no non-zero exit in the plugin scripts"
  fi

  # A shell error mode turns an unset variable or a failing command into a
  # non-zero exit, which aborts the install just like an explicit exit 1. The
  # literal exit check above cannot see it.
  log "checking for a shell error mode..."
  if grep -Eq '(^|[[:space:];])set[[:space:]]+-[A-Za-z]*[eu]([[:space:]]|$)' "${PLG}"; then
    bad "a shell error mode is enabled in a plugin script; an unset variable or a failing command would abort the install"
  else
    ok "no shell error mode in the plugin scripts"
  fi

  # ---------------------------------------------------------------- 8. placeholders
  log "checking for leftover placeholders..."
  if grep -Eq '@@[A-Z_]+@@' "${PLG}"; then
    bad "unsubstituted placeholders found: $(grep -Eo '@@[A-Z_]+@@' "${PLG}" | sort -u | tr '\n' ' ')"
  else
    ok "no placeholders left"
  fi

  # ---------------------------------------------------------------- 9. secrets
  # The .plg is a public file. A real token must never be baked into it, and
  # the install script must not put the token on a command line where every
  # local user can read it from /proc.
  #
  # Only an actual invocation counts as a leak: the flag has to be followed by
  # a variable expansion. The runtime library mentions "--token" inside the
  # guard that rejects a token smuggled in through EXTRA_ARGS, which is the
  # opposite of a leak.
  log "checking that the token is not passed on a command line..."
  if grep -En -- '(^|[^a-zA-Z_])--token[[:space:]]+["'"'"']?\$' "${PLG}"; then
    bad "the install script passes the token as a command line argument"
  else
    ok "the token is not passed as a command line argument"
  fi

  echo
done

if [ "${FAIL}" -eq 0 ]; then
  log "all checks passed"
  exit 0
else
  printf '\033[1;31m[lint] some checks failed\033[0m\n' >&2
  exit 1
fi
