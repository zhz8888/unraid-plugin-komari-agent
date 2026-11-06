#!/usr/bin/env bash
#
# fetch-plugin.sh -- Download, verify and unpack only; no packing.
# Intended for debugging, auditing and inspecting what a given komari-agent
# release actually contains.
#
# Usage:
#   ./scripts/fetch-plugin.sh                 # default 1.5.11 amd64
#   KOMARI_VERSION=1.5.10 ./scripts/fetch-plugin.sh
#   KOMARI_ARCH=arm64 ./scripts/fetch-plugin.sh
#
set -euo pipefail

KOMARI_VERSION="${KOMARI_VERSION:-1.5.11}"
KOMARI_ARCH="${KOMARI_ARCH:-amd64}"
PYTHON="${PYTHON:-python3}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO_ROOT}/pkg/fetch"
UPSTREAM_SLUG="komari-monitor/komari-agent"
BIN_NAME="komari-agent-linux-${KOMARI_ARCH}"

log() { printf '\033[1;34m[fetch]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

mkdir -p "${OUT}"

log "querying the GitHub Releases API for ${UPSTREAM_SLUG} ${KOMARI_VERSION} ..."
"${PYTHON}" - "${UPSTREAM_SLUG}" "${KOMARI_VERSION}" "${BIN_NAME}" "${OUT}/asset.env" <<'PY'
import json
import os
import sys
import urllib.request

slug, version, asset_name, out_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

proxies = {}
for key, value in (
    ("https", os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")),
    ("http", os.environ.get("HTTP_PROXY") or os.environ.get("http_proxy")),
):
    if value:
        proxies[key] = value
opener = urllib.request.build_opener(urllib.request.ProxyHandler(proxies))

api = "https://api.github.com/repos/%s/releases/tags/%s" % (slug, version)
request = urllib.request.Request(api, headers={
    "Accept": "application/vnd.github+json",
    "User-Agent": "unraid-plugin-komari-agent-fetch",
})
token = os.environ.get("GITHUB_TOKEN")
if token:
    request.add_header("Authorization", "Bearer " + token)

with opener.open(request, timeout=120) as response:
    release = json.load(response)

for asset in release.get("assets", []):
    if asset.get("name") == asset_name:
        digest = asset.get("digest") or ""
        if not digest.startswith("sha256:"):
            sys.exit("asset %r has no sha256 digest" % asset_name)
        lines = [
            "BIN_SHA256=%s" % digest.split(":", 1)[1],
            "BIN_SIZE=%s" % asset.get("size", 0),
            "BIN_URL=%s" % asset["browser_download_url"],
        ]
        with open(out_path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write("\n".join(lines) + "\n")
        print("\n".join(lines))
        break
else:
    names = ", ".join(sorted(a.get("name", "?") for a in release.get("assets", [])))
    sys.exit("asset %r is not part of release %s; available: %s"
             % (asset_name, version, names or "(none)"))
PY

# shellcheck disable=SC1091
. "${OUT}/asset.env"

log "downloading ${BIN_NAME} ..."
"${PYTHON}" - "${BIN_URL}" "${OUT}/${BIN_NAME}" <<'PY'
import os
import sys
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
request = urllib.request.Request(url, headers={"User-Agent": "unraid-plugin-komari-agent-fetch"})
with opener.open(request, timeout=300) as response:
    data = response.read()
with open(out_path, "wb") as handle:
    handle.write(data)
print("downloaded %d bytes" % len(data))
PY

ACTUAL=$(sha256_of "${OUT}/${BIN_NAME}")
if [ "${ACTUAL}" != "${BIN_SHA256}" ]; then
  die "SHA256 verification failed!
  expected: ${BIN_SHA256}
  actual:   ${ACTUAL}"
fi

log "SHA256 verified"
log "binary: ${OUT}/${BIN_NAME}"
log "size:   $(wc -c < "${OUT}/${BIN_NAME}" | tr -d ' ') bytes"

echo
echo "  inspect it with:"
echo "    file ${OUT}/${BIN_NAME}"
echo "    ${OUT}/${BIN_NAME} --help"
echo
