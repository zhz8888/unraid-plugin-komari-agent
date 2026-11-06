#!/usr/bin/env bash
#
# lint-repo.sh -- Repository level checks that do not need the upstream binary.
#
# This is the fast half of CI: it answers "is this tree self consistent?" in a
# couple of seconds, before anything is downloaded or built. .github/workflows/ci.yml
# calls it, and so does `make lint-repo`, so a contributor can get the same
# verdict locally without pushing.
#
# It deliberately does not duplicate the checks that already have an owner:
#
#   scripts/lint-plg.sh          the rendered .plg
#   scripts/verify-release.sh    the built package
#   scripts/check-upstream.sh    the upstream pin against the live API
#   scripts/check-php-syntax.py  the WebGUI sources
#
# What is left, and lives here, is the set of rules that apply to the source
# tree itself: shell syntax, the two rules that would brick an install, line
# endings, and the metadata files that are edited by hand.
#
# Usage:
#   ./scripts/lint-repo.sh
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON:-python3}"

cd "${REPO_ROOT}" || exit 1

FAIL=0
log() { printf '\033[1;34m[lint-repo]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
bad() { printf '\033[1;31m  FAIL\033[0m %s\n' "$*" >&2; FAIL=1; }

# The runtime scripts are the ones that end up inside the .plg's <INLINE>
# blocks and inside the package. The build tooling under scripts/ is checked
# for syntax only: it runs on the build machine, not on the Unraid host, so the
# installer's exit-status rule does not apply to it.
RUNTIME_SCRIPTS=(
  "plugin/install.sh"
  "plugin/remove.sh"
  "src/etc/rc.d/rc.komari-agent"
)
while IFS= read -r f; do
  RUNTIME_SCRIPTS+=("$f")
done < <(ls src/usr/local/emhttp/plugins/unraid-plugin-komari-agent/scripts/*.sh 2>/dev/null)

# ---------------------------------------------------------------- 1. shell syntax
log "checking shell syntax..."
while IFS= read -r script; do
  if bash -n "${script}" 2>/dev/null; then
    ok "${script}"
  else
    bad "${script}: bash -n failed"
    bash -n "${script}" 2>&1 | sed 's/^/      /' >&2
  fi
done < <(git ls-files '*.sh' 'src/etc/rc.d/rc.*' 'plugin/*.sh' 2>/dev/null)

# ------------------------------------------------- 2. the install would abort
# The Unraid installer treats a non-zero exit status of an install or remove
# command as a failed install: the .plg is moved to /boot/config/plugins-error/
# and the plugin is dropped from the Plugins page, so the user cannot remove it
# from the WebGUI any more. A shell error mode turns an unset variable into
# exactly that, so both rules are enforced over every script that ships.
log "checking that the shipped scripts cannot abort the install..."
for script in "${RUNTIME_SCRIPTS[@]}"; do
  [ -f "${script}" ] || continue
  if grep -En '^[[:space:]]*exit[[:space:]]+[^0]' "${script}" >/dev/null 2>&1; then
    bad "${script} exits non-zero; that aborts the plugin install"
    grep -En '^[[:space:]]*exit[[:space:]]+[^0]' "${script}" | sed 's/^/      /' >&2
  fi
  if grep -En '(^|[[:space:];])set[[:space:]]+-[A-Za-z]*[eu]([[:space:]]|$)' "${script}" >/dev/null 2>&1; then
    bad "${script} enables a shell error mode; an unset variable would abort the install"
  fi
done
if [ "${FAIL}" -eq 0 ]; then
  ok "no non-zero exit and no shell error mode in the shipped scripts"
fi

# ---------------------------------------------------------------- 3. line endings
# The .plg's <INLINE> scripts are bash, and a CRLF checkout makes bash mis-parse
# every line continuation.
log "checking line endings..."
CRLF_FOUND=0
while IFS= read -r f; do
  if grep -qU $'\r' "${f}" 2>/dev/null; then
    bad "${f} contains CRLF; shipped files must be LF-only"
    CRLF_FOUND=1
  fi
done < <(git ls-files '*.sh' '*.plg.in' 'plugin/*.sh' 'src/etc/rc.d/rc.*' '*.page' 2>/dev/null)
[ "${CRLF_FOUND}" -eq 0 ] && ok "all shipped scripts and pages are LF-only"

# ------------------------------------------------------- 4. the upstream pin
# The lock file, the Makefile and the build script all carry the pinned
# version and have to agree. A second copy that drifts is how the build ends up
# refusing its own lock file. This is the offline half of check-upstream.sh;
# that script reports the same inconsistency, but it also needs the network, so
# the check is repeated here where it can run in seconds.
log "checking that the upstream pin is self consistent..."
if "${PYTHON}" - <<'PY'
import configparser
import re
import sys

problems = []

try:
    parser = configparser.ConfigParser()
    parser.optionxform = str
    with open('plugin/upstream.lock', encoding='utf-8') as handle:
        parser.read_file(handle)
except OSError as error:
    print("PROBLEM cannot read plugin/upstream.lock: %s" % error)
    sys.exit(1)
except Exception as error:  # noqa: BLE001 - the message is what matters
    print("PROBLEM plugin/upstream.lock does not parse: %s" % error)
    sys.exit(1)

if not parser.has_section('meta'):
    problems.append('plugin/upstream.lock has no [meta] section')
    lock_version = ''
else:
    lock_version = parser['meta'].get('version', '').strip()
    if not lock_version:
        problems.append('plugin/upstream.lock [meta] has no version')

try:
    makefile = open('Makefile', encoding='utf-8').read()
except OSError:
    makefile = ''
match = re.search(r'^KOMARI_VERSION\s*\?=\s*(\S+)', makefile, re.M)
make_version = match.group(1).strip() if match else ''
if not make_version:
    problems.append('the Makefile has no KOMARI_VERSION default')
elif lock_version and make_version != lock_version:
    problems.append('the Makefile pins %s, the lock file pins %s'
                    % (make_version, lock_version))

try:
    build = open('scripts/build-plugin.sh', encoding='utf-8').read()
except OSError:
    build = ''
match = re.search(r'KOMARI_VERSION:-([^}]+)\}', build)
script_version = match.group(1).strip() if match else ''
if not script_version:
    problems.append('scripts/build-plugin.sh has no KOMARI_VERSION default')
elif lock_version and script_version != lock_version:
    problems.append('scripts/build-plugin.sh defaults to %s, the lock file pins %s'
                    % (script_version, lock_version))

# Every recorded architecture needs a complete entry: a partial update is
# exactly what the build refuses, and it is the likely mistake when someone
# edits the file by hand.
for section in parser.sections():
    if section == 'meta':
        continue
    entry = parser[section]
    for key in ('name', 'size', 'sha256', 'url'):
        if not entry.get(key, '').strip():
            problems.append('[%s] is missing %s' % (section, key))
    sha = entry.get('sha256', '').strip().lower()
    if sha and (len(sha) != 64 or any(c not in '0123456789abcdef' for c in sha)):
        problems.append('[%s] sha256 is not a 64 character hex digest' % section)
    size = entry.get('size', '').strip()
    if size and not size.isdigit():
        problems.append('[%s] size is not a number: %r' % (section, size))
    url = entry.get('url', '').strip()
    if url and not url.startswith('https://'):
        problems.append('[%s] url is not https' % section)
    name = entry.get('name', '').strip()
    if name and not name.startswith('komari-agent-linux-'):
        problems.append('[%s] asset name looks wrong: %s' % (section, name))

if problems:
    for problem in problems:
        print("PROBLEM " + problem)
    sys.exit(1)

print("OK pinned %s" % lock_version)
PY
then
  ok "the lock file, the Makefile and the build script agree"
else
  bad "the upstream pin is inconsistent"
fi

# ------------------------------------------------------- 5. hand edited metadata
# Workflow YAML and issue templates are edited by hand and have no other
# validator. A trailing tab or a duplicated key turns the whole workflow file
# into a syntax error that GitHub reports as "invalid workflow file" with no
# line number.
log "checking the workflow and issue template YAML..."
if "${PYTHON}" - <<'PY'
import glob
import sys

try:
    import yaml
except ImportError:
    print("SKIP PyYAML is not installed")
    sys.exit(0)

problems = []
for path in sorted(glob.glob('.github/**/*.yml', recursive=True)):
    try:
        with open(path, encoding='utf-8') as handle:
            yaml.safe_load(handle)
    except Exception as error:  # noqa: BLE001 - the message is what matters
        problems.append('%s: %s' % (path, error))

if problems:
    for problem in problems:
        print("PROBLEM " + problem)
    sys.exit(1)
print("OK all YAML parses")
PY
then
  ok "the workflow and issue template YAML parses"
else
  bad "some workflow or issue template YAML does not parse"
fi

# ---------------------------------------------------------- 6. CA metadata
log "checking the Community Applications metadata..."
if "${PYTHON}" - <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

problems = []

try:
    root = ET.parse('ca_profile.xml').getroot()
except Exception as error:  # noqa: BLE001 - the message is what matters
    problems.append('ca_profile.xml: %s' % error)
else:
    if not (root.findtext('Profile') or '').strip():
        problems.append('ca_profile.xml: <Profile> is empty; CA blocks the submission')

wrapper = 'ca/unraid-plugin-komari-agent.xml'
try:
    text = open(wrapper, encoding='utf-8').read()
    ET.fromstring(text)
except Exception as error:  # noqa: BLE001 - the message is what matters
    problems.append('%s: %s' % (wrapper, error))
else:
    match = re.search(r'<PluginURL>([^<]+)</PluginURL>', text)
    if not match:
        problems.append('%s: no <PluginURL>' % wrapper)
    elif not match.group(1).startswith('https://'):
        problems.append('%s: <PluginURL> is not https' % wrapper)
    if not re.search(r'<Name>[^<]+</Name>', text):
        problems.append('%s: no <Name>' % wrapper)

if problems:
    for problem in problems:
        print("PROBLEM " + problem)
    sys.exit(1)
print("OK ca_profile.xml and the CA wrapper are valid")
PY
then
  ok "the Community Applications metadata is valid"
else
  bad "the Community Applications metadata is invalid"
fi

# ---------------------------------------------------------------- result
echo
if [ "${FAIL}" -eq 0 ]; then
  log "all repository checks passed"
  exit 0
fi
printf '\033[1;31m[lint-repo] some checks failed\033[0m\n' >&2
exit 1
