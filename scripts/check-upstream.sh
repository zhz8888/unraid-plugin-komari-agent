#!/usr/bin/env bash
#
# check-upstream.sh -- Compare the pinned komari-agent release with the latest
#                      upstream release.
#
# This is the logic behind .github/workflows/upstream-check.yml. It lives in a
# script rather than inline in the workflow so that it can be run locally with
# exactly the same semantics: a maintainer can ask "is there an upgrade?" and
# "is the pin self consistent?" without pushing a commit, waiting for the
# nightly schedule, or reading a GitHub Actions log.
#
# Usage:
#   ./scripts/check-upstream.sh                     # human readable report
#   ./scripts/check-upstream.sh --json              # one JSON object on stdout
#   ./scripts/check-upstream.sh --github-output     # append to $GITHUB_OUTPUT
#   ./scripts/check-upstream.sh --issue-body FILE   # write the issue body
#
# The flags combine: the workflow uses --github-output and --issue-body, a
# maintainer usually runs it with no flags at all.
#
# Exit status:
#   0  the check completed. Whether an upgrade exists is reported in the
#      "newer" field, not in the exit status: "there is no upgrade" is a
#      successful check, and a workflow that failed every night because nothing
#      had changed would train people to ignore it.
#   1  the check could not be completed: the pin sources disagree, the lock
#      file is malformed, the API is unreachable, or the upstream release
#      cannot be packaged.
#
# Environment:
#   GITHUB_TOKEN   optional; raises the API rate limit from 60 to 5000 per hour
#   HTTPS_PROXY    honoured, for networks that need a proxy
#   PYTHON         interpreter used for JSON parsing; defaults to python3
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="${REPO_ROOT}/plugin/upstream.lock"
BUILD_SCRIPT="${REPO_ROOT}/scripts/build-plugin.sh"
MAKEFILE="${REPO_ROOT}/Makefile"
PYTHON="${PYTHON:-python3}"

UPSTREAM_SLUG="komari-monitor/komari-agent"

WANT_JSON=0
WANT_GITHUB_OUTPUT=0
ISSUE_BODY_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json)          WANT_JSON=1; shift ;;
    --github-output) WANT_GITHUB_OUTPUT=1; shift ;;
    --issue-body)
      [ $# -ge 2 ] || { printf 'check-upstream: --issue-body needs a file argument\n' >&2; exit 1; }
      ISSUE_BODY_FILE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      printf 'check-upstream: unknown argument %s\n' "$1" >&2; exit 1 ;;
  esac
done

log()  { printf '\033[1;34m[upstream]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn ]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- api access

# api_get URL OUTFILE
#
# Fetch a GitHub API resource. curl is the fast path; Python's urllib is the
# fallback, because the Windows build of curl uses Schannel and fails the TLS
# handshake outright in some environments while urllib (OpenSSL) works. A
# maintainer on such a machine should not have to discover that by hand.
#
# A failure is recorded as a specific reason, not just "it did not work": a
# rate limit and a missing release mean very different things, and telling a
# maintainer their pin is wrong when the real problem is a 403 would send them
# looking in the wrong place.
API_ERROR=""
API_ERROR_KIND=""

api_get() {
  local url="$1" out="$2"
  local -a headers=(
    -H 'Accept: application/vnd.github+json'
    -H 'User-Agent: unraid-plugin-komari-agent-upstream-check'
  )
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  API_ERROR=""
  API_ERROR_KIND=""

  if curl -fsSL --retry 3 --max-time 120 "${headers[@]}" "$url" -o "$out" 2>/dev/null; then
    return 0
  fi

  local py_error py_status
  if py_error=$("${PYTHON}" - "$url" "$out" <<'PY'
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
    "Accept": "application/vnd.github+json",
    "User-Agent": "unraid-plugin-komari-agent-upstream-check",
})
token = os.environ.get("GITHUB_TOKEN")
if token:
    request.add_header("Authorization", "Bearer " + token)

try:
    with opener.open(request, timeout=120) as response:
        data = response.read()
except urllib.error.HTTPError as error:
    body = ""
    try:
        body = error.read().decode("utf-8", "replace")
    except Exception:  # noqa: BLE001 - the body is best effort
        pass
    # 403 with a rate limit message and 429 are not "the thing is missing".
    if error.code == 429 or (error.code == 403 and "rate limit" in body.lower()):
        print("RATE_LIMIT HTTP %s" % error.code)
        sys.exit(3)
    print("HTTP %s" % error.code)
    sys.exit(2)
except Exception as error:  # noqa: BLE001 - the message is what matters
    print("%s" % error)
    sys.exit(4)

with open(out_path, "wb") as handle:
    handle.write(data)
PY
  ); then
    return 0
  else
    # $? has to be read here. Once the `if` compound statement completes,
    # $? is the status of the `if` itself, which is always 0, so reading it
    # below would make every failure fall through to the network case.
    py_status=$?
  fi

  case "${py_status}" in
    2) API_ERROR_KIND="http";       API_ERROR="HTTP error: ${py_error}" ;;
    3) API_ERROR_KIND="rate_limit"; API_ERROR="API rate limit reached: ${py_error}" ;;
    *) API_ERROR_KIND="network";    API_ERROR="network error: ${py_error}" ;;
  esac
  return 1
}

# explain_api_failure SUBJECT -- turn the recorded failure into an actionable
# message. The point is that a rate limit is never reported as a wrong pin.
explain_api_failure() {
  local subject="$1"
  case "${API_ERROR_KIND}" in
    rate_limit)
      die "the GitHub API rate limit was reached while ${subject}.

  An unauthenticated client gets 60 requests per hour. Set GITHUB_TOKEN to
  raise it to 5000:

      GITHUB_TOKEN=\$(gh auth token) ./scripts/check-upstream.sh

  Nothing was compared, so this says nothing about whether the pin is correct." ;;
    network)
      die "could not reach the GitHub API while ${subject}.

  ${API_ERROR}

  If this machine needs a proxy, set HTTPS_PROXY. Nothing was compared." ;;
    *)
      die "the GitHub API refused the request while ${subject}.

  ${API_ERROR}

  Nothing was compared." ;;
  esac
}

# ------------------------------------------------- 1. the pin must be coherent

# The lock file is the single source of truth for which upstream bytes are
# bundled. The Makefile and the build script repeat the version for local
# builds, so all three are read and compared here. A second copy that drifts is
# exactly how a bogus "upgrade" issue gets filed, and it is also how the build
# ends up refusing its own lock file.
log "reading the pin from plugin/upstream.lock ..."

[ -f "${LOCK_FILE}" ] || die "${LOCK_FILE} is missing"
[ -f "${BUILD_SCRIPT}" ] || die "${BUILD_SCRIPT} is missing"
[ -f "${MAKEFILE}" ] || die "${MAKEFILE} is missing"

PIN_VERSION=$(awk -F'=' '
  /^\[/ { section = $0; gsub(/[][[:space:]]/, "", section); next }
  section == "meta" && $1 ~ /^[[:space:]]*version[[:space:]]*$/ { gsub(/[[:space:]]/, "", $2); print $2; exit }
' "${LOCK_FILE}")

# The architecture the plugin publishes. It is read from the build script
# rather than hard coded, so that changing the published architecture in one
# place cannot leave this check watching a stale one.
PIN_ARCH=$(awk -F'KOMARI_ARCH:-' '/KOMARI_ARCH:-/{split($2,a,"}");print a[1];exit}' "${BUILD_SCRIPT}")

[ -n "${PIN_VERSION}" ] || die "could not read version from the [meta] section of ${LOCK_FILE}"
[ -n "${PIN_ARCH}" ]    || die "could not read the KOMARI_ARCH default from ${BUILD_SCRIPT}"

MAKE_VERSION=$(awk -F'=' '/^KOMARI_VERSION[[:space:]]*\?=/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "${MAKEFILE}")
SCRIPT_VERSION=$(awk -F'KOMARI_VERSION:-' '/KOMARI_VERSION:-/{split($2,a,"}");print a[1];exit}' "${BUILD_SCRIPT}")

if [ -n "${MAKE_VERSION}" ] && [ "${MAKE_VERSION}" != "${PIN_VERSION}" ]; then
  die "Makefile pins ${MAKE_VERSION}, ${LOCK_FILE} pins ${PIN_VERSION}"
fi
if [ -n "${SCRIPT_VERSION}" ] && [ "${SCRIPT_VERSION}" != "${PIN_VERSION}" ]; then
  die "scripts/build-plugin.sh defaults to ${SCRIPT_VERSION}, ${LOCK_FILE} pins ${PIN_VERSION}"
fi

# The lock entry for the published architecture has to name the asset the
# build expects. Both the build and this check refuse a mismatch, and the
# message names both sides so the fix is obvious.
LOCK_ASSET=$(awk -F'=' -v sec="[${PIN_ARCH}]" '
  $0 == sec { inse = 1; next }
  /^\[/     { inse = 0 }
  inse && $1 ~ /^[[:space:]]*name[[:space:]]*$/ { gsub(/[[:space:]]/, "", $2); print $2; exit }
' "${LOCK_FILE}")

EXPECTED_ASSET="komari-agent-linux-${PIN_ARCH}"
if [ "${LOCK_ASSET}" != "${EXPECTED_ASSET}" ]; then
  die "${LOCK_FILE} [${PIN_ARCH}] names '${LOCK_ASSET}', expected '${EXPECTED_ASSET}'"
fi

log "pinned ${PIN_VERSION} (${PIN_ARCH}), asset ${LOCK_ASSET}"

# ------------------------------------------------------ 2. query the releases

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

log "querying the GitHub Releases API for ${UPSTREAM_SLUG} ..."

if ! api_get "https://api.github.com/repos/${UPSTREAM_SLUG}/releases/latest" "${TMP_DIR}/latest.json"; then
  explain_api_failure "looking up the latest release of ${UPSTREAM_SLUG}"
fi

# The plugin bundles one asset of one release. A tag that exists but does not
# carry that asset is not something this plugin can ship, so the asset list and
# its digest are checked, not just the tag name.
LATEST_INFO=$("${PYTHON}" - "${TMP_DIR}/latest.json" "${EXPECTED_ASSET}" <<'PY'
import json
import sys

path, asset_name = sys.argv[1], sys.argv[2]

try:
    with open(path, encoding='utf-8') as handle:
        release = json.load(handle)
except Exception as error:  # noqa: BLE001 - the message is what matters
    sys.exit("could not parse the API response: %s" % error)

tag = (release.get("tag_name") or "").strip()
if not tag:
    sys.exit("the latest release has no tag_name")
if release.get("draft"):
    sys.exit("the latest release %s is a draft" % tag)

assets = {a.get("name"): a for a in release.get("assets", [])}
asset = assets.get(asset_name)
if asset is None:
    names = ", ".join(sorted(n for n in assets if n)) or "(none)"
    sys.exit("release %s does not carry %s (it has: %s)" % (tag, asset_name, names))

digest = (asset.get("digest") or "").strip()
if not digest.startswith("sha256:"):
    sys.exit("asset %s in release %s has no sha256 digest; the build would refuse it"
             % (asset_name, tag))

print(tag)
print(asset_name)
print(digest.split(":", 1)[1])
print(asset.get("size", 0))
print(asset.get("browser_download_url", ""))
PY
) || die "the latest upstream release cannot be packaged"

LATEST=$(printf '%s\n' "${LATEST_INFO}" | sed -n '1p')
LATEST_SHA=$(printf '%s\n' "${LATEST_INFO}" | sed -n '3p')
LATEST_SIZE=$(printf '%s\n' "${LATEST_INFO}" | sed -n '4p')
LATEST_URL=$(printf '%s\n' "${LATEST_INFO}" | sed -n '5p')

[ -n "${LATEST}" ] || die "could not determine the latest upstream release"

# If the pinned version is not a real release at all, either the pin is wrong
# or the release was deleted. Comparing versions is meaningless then, and
# guessing is how a bogus issue gets filed.
log "confirming that the pinned tag ${PIN_VERSION} exists upstream ..."
if ! api_get "https://api.github.com/repos/${UPSTREAM_SLUG}/releases/tags/${PIN_VERSION}" "${TMP_DIR}/pinned.json"; then
  # A rate limit or a network failure says nothing about the pin, so those are
  # reported as such instead of as "the pinned version does not exist".
  case "${API_ERROR_KIND}" in
    rate_limit|network) explain_api_failure "confirming that ${PIN_VERSION} exists upstream" ;;
    *) die "pinned version ${PIN_VERSION} is not a release in ${UPSTREAM_SLUG}

  Either the pin is wrong or the release was withdrawn. Nothing was compared." ;;
  esac
fi

# ------------------------------------------------ 3. is the latest an upgrade

# Only a real upgrade is worth an issue: a tag that sorts lower must never
# become a "bump" request that downgrades the binary.
NEWER=false
if [ "${LATEST}" != "${PIN_VERSION}" ]; then
  if [ "$(printf '%s\n%s\n' "${PIN_VERSION}" "${LATEST}" | sort -V | tail -1)" = "${LATEST}" ]; then
    NEWER=true
  fi
fi

log "pinned ${PIN_VERSION}, latest ${LATEST}, newer ${NEWER}"

# ------------------------------------------------------------- 4. report out

if [ "${WANT_GITHUB_OUTPUT}" = "1" ]; then
  [ -n "${GITHUB_OUTPUT:-}" ] || die "--github-output was requested but GITHUB_OUTPUT is not set"
  {
    printf 'current=%s\n'  "${PIN_VERSION}"
    printf 'latest=%s\n'   "${LATEST}"
    printf 'arch=%s\n'     "${PIN_ARCH}"
    printf 'asset=%s\n'    "${EXPECTED_ASSET}"
    printf 'newer=%s\n'    "${NEWER}"
    printf 'sha256=%s\n'   "${LATEST_SHA}"
    printf 'size=%s\n'     "${LATEST_SIZE}"
    printf 'url=%s\n'      "${LATEST_URL}"
  } >> "${GITHUB_OUTPUT}"
  log "wrote the result to GITHUB_OUTPUT"
fi

if [ -n "${ISSUE_BODY_FILE}" ]; then
  "${PYTHON}" - "${ISSUE_BODY_FILE}" \
    "${LATEST}" "${PIN_VERSION}" "${EXPECTED_ASSET}" "${LATEST_SHA}" "${LATEST_SIZE}" "${LATEST_URL}" <<'PY'
import sys

(path, latest, current, asset, sha256, size, url) = sys.argv[1:8]

body = """\
Upstream `komari-agent` **{latest}** is available; this repository pins **{current}**.

The asset this plugin bundles is `{asset}`:

| | |
|---|---|
| Size | {size} bytes |
| SHA256 | `{sha256}` |
| URL | {url} |

The SHA256 is recorded in `plugin/upstream.lock` and verified against the
downloaded bytes at build time.

## To update

```bash
./scripts/update-upstream.sh {latest}
./scripts/build-plugin.sh
./scripts/lint-plg.sh
./scripts/check-php-syntax.py src/
./scripts/verify-release.sh
./scripts/smoke-test.sh
```

Review the `plugin/upstream.lock` diff: the version, size and SHA256 of every
recorded architecture must change together. A partial update is what the build
refuses.

Then:

1. Update the pin in `Makefile` (`KOMARI_VERSION ?= {latest}`) and in
   `scripts/build-plugin.sh`. All three sources have to agree, or the build and
   `scripts/check-upstream.sh` both fail.
2. Add a `CHANGELOG.md` entry for the new plugin version.
3. Open a PR, then tag the release.

## Before you bump

Read the upstream changelog. A new agent release can add or rename `AGENT_*`
environment variables, and the Settings page maps them one by one: a rename
would silently stop a setting from taking effect, which looks like a bug in
this plugin rather than an upstream change.
""".format(latest=latest, current=current, asset=asset,
           size=size, sha256=sha256, url=url)

with open(path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(body)
PY
  log "wrote the issue body to ${ISSUE_BODY_FILE}"
fi

if [ "${WANT_JSON}" = "1" ]; then
  "${PYTHON}" - "${PIN_VERSION}" "${LATEST}" "${PIN_ARCH}" "${EXPECTED_ASSET}" \
    "${NEWER}" "${LATEST_SHA}" "${LATEST_SIZE}" "${LATEST_URL}" <<'PY'
import json
import sys

(current, latest, arch, asset, newer, sha256, size, url) = sys.argv[1:9]

print(json.dumps({
    "current": current,
    "latest": latest,
    "arch": arch,
    "asset": asset,
    "newer": newer == "true",
    "sha256": sha256,
    "size": int(size) if size.isdigit() else 0,
    "url": url,
}, indent=2, sort_keys=True))
PY
else
  echo
  echo "  pinned:  ${PIN_VERSION}  (${EXPECTED_ASSET})"
  echo "  latest:  ${LATEST}"
  if [ "${NEWER}" = "true" ]; then
    echo "  status:  an upgrade is available"
    echo
    echo "  next:"
    echo "    ./scripts/update-upstream.sh ${LATEST}"
  else
    echo "  status:  up to date"
  fi
  echo
fi

exit 0
