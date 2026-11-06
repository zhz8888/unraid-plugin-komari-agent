#!/usr/bin/env bash
#
# build-plugin.sh -- Build the komari-agent plugin for Unraid
#                    (unraid-plugin-komari-agent)
#
# Pipeline:
#   1. Resolve the SHA256 and size of the requested komari-agent release
#      asset from the GitHub Releases API
#   2. Download the asset and verify the SHA256 byte for byte
#   3. Assemble the Slackware package from src/ plus the upstream binary and
#      pack it as a txz (install/slack-desc and install/doinst.sh are required
#      by upgradepkg)
#   4. Render two .plg files from one template, with the txz and binary
#      SHA256 values baked in: a direct one and one that downloads through the
#      gh-proxy.org mirror
#
# Usage:
#   ./scripts/build-plugin.sh
#   PLUGIN_VERSION=20261106 ./scripts/build-plugin.sh
#   KOMARI_VERSION=1.5.11 ./scripts/build-plugin.sh
#   KOMARI_ARCH=arm64 ./scripts/build-plugin.sh
#   PYTHON=D:/Python312/python.exe ./scripts/build-plugin.sh
#
# Version scheme:
#   PLUGIN_VERSION  the version of this plugin. It is the release date,
#                   YYYYMMDD, followed by a letter suffix when more than one
#                   release happens on the same day: YYYYMMDD.a, YYYYMMDD.b
#                   and so on. The Unraid installer compares plugin versions
#                   with strcmp(), a byte wise string compare, so this format
#                   is what sorts in release order:
#                     20261106 < 20261106.a < 20261106.b < 20261107
#                   The first release of a day therefore carries no suffix.
#                   The version must not be tied to the upstream version.
#   KOMARI_VERSION  the version of the upstream komari-agent release that is
#                   bundled. Recorded in the package description, the
#                   changelog and the WebGUI page.
#
set -euo pipefail

# ---------------------------------------------------------------- config
KOMARI_VERSION="${KOMARI_VERSION:-1.5.11}"
KOMARI_ARCH="${KOMARI_ARCH:-amd64}"     # amd64 | arm64 | arm | 386 | loong64

# The plugin version: the release date, YYYYMMDD. A second release on the
# same day adds a letter suffix, YYYYMMDD.a, YYYYMMDD.b and so on.
# The date is the local one, because "the day of the release" is what the
# version stands for.
PLUGIN_VERSION="${PLUGIN_VERSION:-$(date +%Y%m%d)}"

# Python interpreter. On Windows "python3" resolves to a WindowsApps stub
# that does not run, so the caller may override it.
PYTHON="${PYTHON:-python3}"

# Unraid plugin name (also used as the .plg filename, the flash cache
# directory name, and the Slackware package name)
PLUGIN_NAME="unraid-plugin-komari-agent"

# Repository the release assets are published under. The direct .plg and the
# mirrored .plg are both rendered from the same template against this repo.
REPO_SLUG="zhz8888/unraid-plugin-komari-agent"

# Mirror for networks that cannot reach github.com directly. The proxy takes
# the whole target URL as its path, so a GitHub release asset becomes
#   https://gh-proxy.org/https://github.com/<owner>/<repo>/releases/...
# The proxy returns the original bytes, so the SHA256 does not change.
GH_PROXY="https://gh-proxy.org/"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="${REPO_ROOT}/pkg"
DIST_DIR="${REPO_ROOT}/dist"
WORK_DIR="${PKG_DIR}/work"
SRC_DIR="${REPO_ROOT}/src"

# Slackware package naming: <name>-<version>-<arch>-<build>
SLACK_ARCH="$([ "${KOMARI_ARCH}" = "amd64" ] && echo "x86_64" || echo "${KOMARI_ARCH}")"
TXZ_NAME="${PLUGIN_NAME}-${PLUGIN_VERSION}-${SLACK_ARCH}-1.txz"

# The upstream asset name follows the Go release convention
# komari-agent-<os>-<arch>, with no extension on Linux. The authoritative
# value comes from plugin/upstream.lock, which the build verifies below; this
# default exists only so the rest of the script has something to compare to.
EXPECTED_BIN_NAME="komari-agent-linux-${KOMARI_ARCH}"

# ---------------------------------------------------------------- helpers
log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn ]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum   >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else die "neither sha256sum nor shasum is available"; fi
}

need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# Reject anything that would not sort correctly under strcmp(), the
# comparison the Unraid installer uses for plugin versions.
if ! printf '%s' "${PLUGIN_VERSION}" | grep -Eq '^[0-9]{8}(\.[a-z])?$'; then
  die "invalid plugin version '${PLUGIN_VERSION}'
  expected YYYYMMDD, or YYYYMMDD.a when a day carries more than one release"
fi

# Download a URL with an explicit retry loop.
#
# curl's own --retry only covers transient HTTP errors and timeouts, so a TLS
# handshake failure aborts the build on the first attempt. The loop makes the
# build survive the occasional flaky connection.
#
#   fetch <url> <output> <max-time> [attempts]
fetch() {
  local url="$1" out="$2" max_time="$3" attempts="${4:-4}" attempt=1

  while true; do
    if curl -fsSL --retry 2 --max-time "${max_time}" "$url" -o "${out}"; then
      return 0
    fi
    if [ "${attempt}" -ge "${attempts}" ]; then
      break
    fi
    attempt=$((attempt + 1))
    warn "download failed, retrying in 3s (attempt ${attempt}/${attempts})"
    sleep 3
  done

  # curl is the fast path, not the only path. On Windows the bundled curl uses
  # Schannel, which fails the TLS handshake outright in some environments
  # ("SEC_E_NO_CREDENTIALS") while Python's urllib, which uses OpenSSL and the
  # conventional proxy variables, works. The build must not depend on which
  # TLS backend happens to be installed.
  warn "curl could not fetch the file, falling back to the Python downloader"
  "${PYTHON}" - "${url}" "${out}" <<'PY'
import os
import sys
import urllib.error
import urllib.request

url, out_path = sys.argv[1], sys.argv[2]

proxies = {}
for key, value in (
    ("https", os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")),
    ("http", os.environ.get("HTTP_PROXY") or os.environ.get("http_proxy")),
):
    if value:
        proxies[key] = value

opener = urllib.request.build_opener(urllib.request.ProxyHandler(proxies))
request = urllib.request.Request(url, headers={
    "User-Agent": "unraid-plugin-komari-agent-build",
})
token = os.environ.get("GITHUB_TOKEN")
if token:
    request.add_header("Authorization", "Bearer " + token)

try:
    with opener.open(request, timeout=300) as response:
        data = response.read()
except urllib.error.HTTPError as error:
    sys.exit("HTTP %s for %s" % (error.code, url))
except Exception as error:  # noqa: BLE001 - the message is what matters
    sys.exit("download failed: %s" % error)

if not data:
    sys.exit("the server returned an empty body for %s" % url)

with open(out_path, "wb") as handle:
    handle.write(data)
print("downloaded %d bytes" % len(data))
PY
}

need tar
need curl
"${PYTHON}" -c 'import tarfile, lzma, hashlib' >/dev/null 2>&1 \
  || die "the Python interpreter '${PYTHON}' cannot import tarfile/lzma/hashlib"

mkdir -p "${PKG_DIR}" "${DIST_DIR}" "${WORK_DIR}"

log "plugin version: ${PLUGIN_VERSION}  upstream: ${KOMARI_VERSION}  arch: ${KOMARI_ARCH}"

# ---------------------------------------------------------------- 1. release metadata
# The exact upstream asset is pinned in plugin/upstream.lock, together with the
# SHA256 that GitHub published for it. Reading the pin from a file in the
# repository rather than from the GitHub API on every build keeps the build
# reproducible and offline capable, and turns an upstream bump into a reviewable
# diff instead of an invisible change during CI. scripts/update-upstream.sh
# refreshes the lock file.
log "reading the upstream pin for ${KOMARI_VERSION} ${KOMARI_ARCH} ..."

LOCK_FILE="${REPO_ROOT}/plugin/upstream.lock"
[ -f "${LOCK_FILE}" ] || die "upstream lock file not found: ${LOCK_FILE}"

"${PYTHON}" - "${LOCK_FILE}" "${KOMARI_VERSION}" "${KOMARI_ARCH}" "${WORK_DIR}/asset.env" <<'PY'
import configparser
import sys

lock_path, want_version, want_arch, out_path = sys.argv[1:5]

parser = configparser.ConfigParser()
# Keep the keys verbatim: the lock file is data, not something to interpolate.
parser.optionxform = str
with open(lock_path, encoding='utf-8') as handle:
    parser.read_file(handle)

if not parser.has_section('meta'):
    sys.exit("plugin/upstream.lock has no [meta] section")
locked_version = parser['meta'].get('version', '').strip()
if want_version != locked_version:
    sys.exit("plugin/upstream.lock pins version %r, but the build requested %r.\n"
             "Run scripts/update-upstream.sh %s first, or drop KOMARI_VERSION."
             % (locked_version, want_version, want_version))

if not parser.has_section(want_arch):
    available = ", ".join(parser.sections())
    sys.exit("plugin/upstream.lock has no section for arch %r (available: %s)"
             % (want_arch, available or "(none)"))

section = parser[want_arch]
try:
    name = section['name'].strip()
    size = int(section['size'].strip())
    sha256 = section['sha256'].strip().lower()
    url = section['url'].strip()
except KeyError as error:
    sys.exit("plugin/upstream.lock [%s] is missing %s" % (want_arch, error))

if len(sha256) != 64 or any(c not in '0123456789abcdef' for c in sha256):
    sys.exit("plugin/upstream.lock [%s] sha256 is malformed: %r" % (want_arch, sha256))
if size <= 0:
    sys.exit("plugin/upstream.lock [%s] size must be positive, got %d" % (want_arch, size))
if not url.startswith('https://'):
    sys.exit("plugin/upstream.lock [%s] url is not https: %r" % (want_arch, url))

lines = [
    "BIN_NAME=%s" % name,
    "BIN_SHA256=%s" % sha256,
    "BIN_SIZE=%d" % size,
    "BIN_URL=%s" % url,
]
with open(out_path, 'w', encoding='utf-8', newline='\n') as handle:
    handle.write("\n".join(lines) + "\n")
print("\n".join(lines))
PY

# shellcheck disable=SC1091
. "${WORK_DIR}/asset.env"

[ -n "${BIN_SHA256:-}" ] || die "could not resolve the SHA256 of the upstream binary"
[ "${BIN_NAME}" = "${EXPECTED_BIN_NAME}" ] \
  || die "plugin/upstream.lock names ${BIN_NAME}, expected ${EXPECTED_BIN_NAME}"
log "release asset: ${BIN_NAME}  SHA256=${BIN_SHA256:0:16}...  Size=${BIN_SIZE}"

BIN_PATH="${PKG_DIR}/${BIN_NAME}"

# ---------------------------------------------------------------- 2. download + verify
if [ -f "${BIN_PATH}" ] && [ "$(sha256_of "${BIN_PATH}")" = "${BIN_SHA256}" ]; then
  log "reusing cached binary (SHA256 already verified): ${BIN_NAME}"
else
  log "downloading ${BIN_NAME} ..."
  fetch "${BIN_URL}" "${BIN_PATH}.part" 300 \
    || die "download failed: ${BIN_URL}"
  mv "${BIN_PATH}.part" "${BIN_PATH}"
fi

ACTUAL_SHA256="$(sha256_of "${BIN_PATH}")"
if [ "${ACTUAL_SHA256}" != "${BIN_SHA256}" ]; then
  die "SHA256 verification failed!
  expected: ${BIN_SHA256}
  actual:   ${ACTUAL_SHA256}"
fi

# A Go binary that is not an ELF image means the download returned an error
# page or an archive member we did not ask for.
"${PYTHON}" - "${BIN_PATH}" <<'PY'
import sys
path = sys.argv[1]
with open(path, "rb") as handle:
    head = handle.read(20)
if head[:4] != b"\x7fELF":
    sys.exit("%s is not an ELF executable (first bytes: %r)" % (path, head[:4]))
# e_machine lives at offset 18 in a 64-bit little-endian ELF header
machine = int.from_bytes(head[18:20], "little")
expected = {62: "x86-64", 183: "AArch64", 40: "ARM", 3: "i386", 258: "LoongArch"}
print("ELF machine: %s" % expected.get(machine, machine))
PY

BIN_BYTES=$(wc -c < "${BIN_PATH}" | tr -d ' ')
log "binary verified: ${BIN_BYTES} bytes"

# ---------------------------------------------------------------- 3. assemble the Slackware package
STAGE="${WORK_DIR}/stage"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"

# The package source tree holds everything that is not the upstream binary:
# the WebGUI page, the rc script, the supervisor scripts and the package
# description.
[ -d "${SRC_DIR}" ] || die "package source tree not found: ${SRC_DIR}"
tar -cf - -C "${SRC_DIR}" . | tar -xf - -C "${STAGE}"
[ -f "${STAGE}/install/slack-desc" ] || die "install/slack-desc is missing from ${SRC_DIR}"
[ -f "${STAGE}/install/doinst.sh" ] || die "install/doinst.sh is missing from ${SRC_DIR}"
chmod 0755 "${STAGE}/install/doinst.sh"

# Every shipped script must be executable inside the package. A txz records
# the mode, so getting it wrong here means a broken plugin on the host.
#
# The mode cannot be inherited from the working tree: a checkout on Windows or
# through MSYS does not report a POSIX execute bit at all, so every file would
# be archived as 0644 and the rc script would not be executable on the Unraid
# host. The package manifest below is therefore authoritative, and the archive
# writer applies it by path.
PLUGIN_DIR_REL="usr/local/emhttp/plugins/${PLUGIN_NAME}"
# One entry per line. A trailing "/" marks a directory prefix, anything else
# is an exact file path. The archive writer forces 0755 for both.
EXECUTABLE_PATHS="${PLUGIN_DIR_REL}/scripts/
etc/rc.d/rc.komari-agent
install/doinst.sh"

for script in \
  "${STAGE}/${PLUGIN_DIR_REL}/scripts"/*.sh \
  "${STAGE}/etc/rc.d/rc.komari-agent" \
  "${STAGE}/install/doinst.sh"
do
  if [ -f "${script}" ]; then
    chmod 0755 "${script}"
  fi
done

# Build metadata for the WebGUI page. It is generated here so that it always
# matches the package it ships with.
mkdir -p "${STAGE}/${PLUGIN_DIR_REL}"
cat > "${STAGE}/${PLUGIN_DIR_REL}/plugin.info" <<EOF
; Generated by scripts/build-plugin.sh -- do not edit.
; Every value is double-quoted: the PHP INI scanner would otherwise evaluate
; operators in a value and reject the whole file.
PLUGIN_NAME="${PLUGIN_NAME}"
PLUGIN_VERSION="${PLUGIN_VERSION}"
UPSTREAM_VERSION="${KOMARI_VERSION}"
UPSTREAM_ARCH="${KOMARI_ARCH}"
UPSTREAM_SOURCE="${BIN_NAME}"
BINARY_SHA256="${BIN_SHA256}"
EOF

# The page description mentions the bundled upstream version.
if [ -f "${STAGE}/${PLUGIN_DIR_REL}/README.md" ]; then
  "${PYTHON}" - "${STAGE}/${PLUGIN_DIR_REL}/README.md" "${PLUGIN_VERSION}" "${KOMARI_VERSION}" <<'PY'
import sys
path, plugin_version, upstream_version = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding='utf-8').read()
text = text.replace('@@PLUGIN_VERSION@@', plugin_version)
text = text.replace('@@UPSTREAM_VERSION@@', upstream_version)
open(path, 'w', encoding='utf-8', newline='\n').write(text)
PY
fi

log "packing ${TXZ_NAME} ..."

# Drop packages of previous builds so that dist/ only ever holds the
# artifacts of the current version. This runs after the build succeeded, so
# a failed build never destroys the artifacts of the previous one.
rm -f "${DIST_DIR}/${PLUGIN_NAME}-"*.txz 2>/dev/null || true

# ---- Reproducible build -------------------------------------------------
# The archive must be byte-identical on every platform, not merely repeatable
# on one machine. Shelling out to `tar` cannot deliver that, because tar
# implementations disagree even when told to emit the same format:
#
#   field      GNU tar (Linux/CI)        bsdtar (macOS)
#   ---------  ------------------------  ------------------------
#   mode       "0000755\0"               "000755 \0"
#   uname      real user name            empty
#   order      readdir order             readdir order (differs)
#   xattrs     n/a                        LIBARCHIVE.xattr.* pax headers
#
# So the archive is written by Python's tarfile module instead. It is a single
# implementation that ships with the interpreter, so macOS and Linux emit
# identical bytes by construction, and every header field is set explicitly
# rather than inherited from the platform tool.
"${PYTHON}" - "${STAGE}" "${DIST_DIR}/${TXZ_NAME}" "${EXECUTABLE_PATHS}" <<'PY'
import hashlib
import io
import lzma
import os
import posixpath
import sys
import tarfile

stage, out_path = sys.argv[1], sys.argv[2]
# One entry per line: a directory prefix (trailing "/") or an exact file path.
# These are forced to 0755 regardless of what the working tree reports.
exec_manifest = [line.strip() for line in sys.argv[3].splitlines() if line.strip()]

# 2020-01-01T00:00:00Z -- fixed timestamp so mtime never varies
FIXED_MTIME = 1577836800


def collect(root):
    """Return the archive member names, sorted with a stable order.

    The names are built with posixpath, not os.path: a tar member name is a
    POSIX path by definition, and a backslash is a perfectly ordinary
    character in a file name on the Unraid host. os.path.join would emit
    "etc\\rc.d\\rc.komari-agent" on Windows, which GNU tar then extracts as a
    single flat file literally named that, so nothing would land in /etc at
    all and the plugin would install "successfully" while doing nothing.
    """
    entries = []
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir == '.':
            rel_dir = ''
        for name in dirnames + filenames:
            rel = posixpath.join(rel_dir.replace(os.sep, '/'), name) if rel_dir else name
            entries.append(rel)
    # sort by path components so the order matches a directory-first walk
    entries.sort(key=lambda p: p.split('/'))
    return entries


def is_executable(rel):
    """True when the manifest marks this member executable."""
    for entry in exec_manifest:
        if entry.endswith('/'):
            if rel.startswith(entry):
                return True
        elif rel == entry:
            return True
    return False


def make_tarinfo(rel, realpath):
    st = os.lstat(realpath)
    ti = tarfile.TarInfo('./' + rel)
    ti.mtime = FIXED_MTIME
    ti.uid = 0
    ti.gid = 0
    ti.uname = ''
    ti.gname = ''
    if os.path.isdir(realpath):
        ti.type = tarfile.DIRTYPE
        ti.mode = 0o755
        ti.size = 0
    elif os.path.islink(realpath):
        ti.type = tarfile.SYMTYPE
        ti.mode = 0o755
        # A symlink target is also a POSIX path inside the archive.
        ti.linkname = os.readlink(realpath).replace(os.sep, '/')
        ti.size = 0
    else:
        ti.type = tarfile.REGTYPE
        # The manifest decides, not the working tree: see the comment at
        # EXECUTABLE_PATHS. A plain data file stays 0644.
        ti.mode = 0o755 if is_executable(rel) else 0o644
        ti.size = st.st_size
    return ti


raw = io.BytesIO()
with tarfile.open(fileobj=raw, mode='w', format=tarfile.USTAR_FORMAT) as tf:
    # root entry first, matching the layout upgradepkg expects
    root_ti = tarfile.TarInfo('.')
    root_ti.type = tarfile.DIRTYPE
    root_ti.mode = 0o755
    root_ti.mtime = FIXED_MTIME
    root_ti.uid = root_ti.gid = 0
    root_ti.uname = root_ti.gname = ''
    tf.addfile(root_ti)

    for rel in collect(stage):
        realpath = os.path.join(stage, rel)
        ti = make_tarinfo(rel, realpath)
        if ti.type == tarfile.REGTYPE:
            with open(realpath, 'rb') as fh:
                tf.addfile(ti, fh)
        else:
            tf.addfile(ti)

data = raw.getvalue()
# preset 6 with a fixed filter keeps the xz stream deterministic
compressed = lzma.compress(data, format=lzma.FORMAT_XZ, preset=6)
with open(out_path, 'wb') as fh:
    fh.write(compressed)

print('sha256', hashlib.sha256(compressed).hexdigest())
print('bytes', len(compressed))
PY

TXZ_SHA256="$(sha256_of "${DIST_DIR}/${TXZ_NAME}")"
TXZ_SIZE=$(wc -c < "${DIST_DIR}/${TXZ_NAME}" | tr -d ' ')
log "txz: ${TXZ_SIZE} bytes  SHA256=${TXZ_SHA256:0:16}..."

# ---------------------------------------------------------------- 4. render the .plg files
log "rendering ${PLUGIN_NAME}.plg and ${PLUGIN_NAME}-proxy.plg ..."
PLG_TEMPLATE="${REPO_ROOT}/plugin/${PLUGIN_NAME}.plg.in"
[ -f "${PLG_TEMPLATE}" ] || die "template not found: ${PLG_TEMPLATE}"

INSTALL_BODY_FILE="${REPO_ROOT}/plugin/install.sh"
REMOVE_BODY_FILE="${REPO_ROOT}/plugin/remove.sh"
[ -f "${INSTALL_BODY_FILE}" ] || die "install script fragment not found: ${INSTALL_BODY_FILE}"
[ -f "${REMOVE_BODY_FILE}" ] || die "remove script fragment not found: ${REMOVE_BODY_FILE}"

# The <CHANGES> body is taken from CHANGELOG.md so that every release shows
# its own notes instead of the notes that happened to be current when the
# template was written.
CHANGES_BODY="$("${PYTHON}" - "${REPO_ROOT}/CHANGELOG.md" "${PLUGIN_VERSION}" <<'PY'
import re
import sys

changelog, version = sys.argv[1], sys.argv[2]
fallback = '- Release %s. See CHANGELOG.md for the full notes.' % version

try:
    text = open(changelog, encoding='utf-8').read()
except OSError:
    print(fallback)
    sys.exit(0)

match = re.search(r'^## \[' + re.escape(version) + r'\][^\n]*\n(.*?)(?=^## |\Z)',
                  text, re.S | re.M)
body = match.group(1).strip() if match else ''
body = re.sub(r'\n{3,}', '\n\n', body)
# The body is written into a CDATA section: a literal "]]>" would end it.
body = body.replace(']]>', ']]]]><![CDATA[>')
print(body or fallback)
PY
)"

RELEASE_BASE="https://github.com/${REPO_SLUG}/releases"
DIRECT_BIN_URL="${BIN_URL}"
DIRECT_TXZ_URL="${RELEASE_BASE}/download/${PLUGIN_VERSION}/${TXZ_NAME}"
DIRECT_PLG_URL="${RELEASE_BASE}/latest/download/${PLUGIN_NAME}.plg"
PROXY_BIN_URL="${GH_PROXY}${DIRECT_BIN_URL}"
PROXY_TXZ_URL="${GH_PROXY}${DIRECT_TXZ_URL}"
PROXY_PLG_URL="${GH_PROXY}${RELEASE_BASE}/latest/download/${PLUGIN_NAME}-proxy.plg"

# Substitute placeholders with Python to avoid sed -i differences between BSD
# and GNU userlands.
render_plg() {
  local out="$1" plg_url="$2" bin_url="$3" txz_url="$4" note="$5" sibling_cleanup="$6"
  "${PYTHON}" - "${PLG_TEMPLATE}" "${out}" \
    "${PLUGIN_VERSION}" "${KOMARI_VERSION}" "${BIN_NAME}" "${BIN_SHA256}" \
    "${TXZ_NAME}" "${TXZ_SHA256}" \
    "${plg_url}" "${bin_url}" "${txz_url}" "${note}" "${sibling_cleanup}" "${CHANGES_BODY}" \
    "${INSTALL_BODY_FILE}" "${REMOVE_BODY_FILE}" <<'PY'
import sys
import re

(tmpl, out, plugin_version, upstream_version, bin_name, bin_sha,
 txz_name, txz_sha, plg_url, bin_url, txz_url, note, sibling_cleanup,
 changes_body, install_file, remove_file) = sys.argv[1:17]

text = open(tmpl, encoding='utf-8').read()
install_body = open(install_file, encoding='utf-8').read().rstrip('\n')
remove_body = open(remove_file, encoding='utf-8').read().rstrip('\n')

repl = {
    '@@PLUGIN_NAME@@': 'unraid-plugin-komari-agent',
    '@@PLUGIN_VERSION@@': plugin_version,
    '@@UPSTREAM_VERSION@@': upstream_version,
    '@@BIN_NAME@@': bin_name,
    '@@BIN_SHA256@@': bin_sha,
    '@@TXZ_NAME@@': txz_name,
    '@@TXZ_SHA256@@': txz_sha,
    '@@PLG_URL@@': plg_url,
    '@@BIN_URL@@': bin_url,
    '@@TXZ_URL@@': txz_url,
    '@@SOURCE_NOTE@@': note,
    '@@SIBLING_CLEANUP@@': sibling_cleanup,
    '@@CHANGES_BODY@@': changes_body,
}


def substitute(fragment, table):
    for key, value in table.items():
        fragment = fragment.replace(key, value)
    return fragment


# The script fragments carry their own placeholders (@@PLUGIN_NAME@@,
# @@SIBLING_CLEANUP@@, ...). They have to be expanded before the fragments are
# inserted into the template, otherwise the second pass would never see them.
install_body = substitute(install_body, repl)
remove_body = substitute(remove_body, repl)

text = substitute(text, repl)
text = text.replace('@@INSTALL_BODY@@', install_body)
text = text.replace('@@REMOVE_BODY@@', remove_body)

leftover = sorted(set(re.findall(r'@@[A-Z_]+@@', text)))
if leftover:
    sys.exit('unsubstituted placeholders remain in %s: %s' % (out, ', '.join(leftover)))

# newline='\n' is required, not cosmetic: the <INLINE> scripts are bash and a
# CRLF checkout would turn every "for ... \" continuation into a syntax error
# on the Unraid host.
open(out, 'w', encoding='utf-8', newline='\n').write(text)
print('written', out)
PY
}

# The canonical variant removes the mirrored one. The installer registers one
# symlink per .plg file name, so both files being present would show up as
# two entries in the Plugins tab and would install the same package twice on
# every boot. The mirrored variant does not remove the canonical one: the
# canonical variant sorts later, so it is always the one that wins.
SIBLING_CLEANUP="rm -f /boot/config/plugins/${PLUGIN_NAME}-proxy.plg
rm -f /var/log/plugins/${PLUGIN_NAME}-proxy.plg"

render_plg "${DIST_DIR}/${PLUGIN_NAME}.plg" \
  "${DIRECT_PLG_URL}" "${DIRECT_BIN_URL}" "${DIRECT_TXZ_URL}" \
  "The plugin package and the upstream binary are downloaded from the GitHub Release assets directly." \
  "${SIBLING_CLEANUP}"

render_plg "${DIST_DIR}/${PLUGIN_NAME}-proxy.plg" \
  "${PROXY_PLG_URL}" "${PROXY_BIN_URL}" "${PROXY_TXZ_URL}" \
  "The plugin package and the upstream binary are downloaded from the GitHub Release assets through the gh-proxy.org mirror, for networks that cannot reach github.com directly." \
  "# The mirrored variant keeps the canonical one in place: only one of the
# two .plg files may be installed, and the canonical one removes this file
# on the next boot if both are present."

log "done"
echo
echo "  output directory: ${DIST_DIR}"
ls -la "${DIST_DIR}"
echo
echo "  install on Unraid with:"
echo "    cp dist/${PLUGIN_NAME}.plg /boot/config/plugins/"
echo "    plugin install /boot/config/plugins/${PLUGIN_NAME}.plg"
echo
echo "  or, on a network that cannot reach github.com:"
echo "    cp dist/${PLUGIN_NAME}-proxy.plg /boot/config/plugins/"
echo "    plugin install /boot/config/plugins/${PLUGIN_NAME}-proxy.plg"
