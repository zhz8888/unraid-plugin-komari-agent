#!/usr/bin/env bash
#
# update-upstream.sh -- Refresh plugin/upstream.lock from the GitHub Releases
#                       API.
#
# This is a maintainer tool, not part of the build. The build itself reads the
# lock file and never talks to the GitHub API, so a build stays reproducible
# and works offline. Run this when you want to move the plugin to a newer
# upstream release, review the resulting diff, then commit it.
#
# Usage:
#   ./scripts/update-upstream.sh              # latest stable release
#   ./scripts/update-upstream.sh 1.5.11       # a specific tag
#
# Environment:
#   GITHUB_TOKEN   optional; raises the API rate limit from 60 to 5000 per hour
#   HTTPS_PROXY    honoured, for networks that need a proxy
#
set -euo pipefail

PYTHON="${PYTHON:-python3}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="${REPO_ROOT}/plugin/upstream.lock"
UPSTREAM_SLUG="komari-monitor/komari-agent"
WANTED_VERSION="${1:-latest}"

# Architectures recorded in the lock file. Unraid itself is x86_64 only; the
# others are kept so that a fork can publish them without touching the build.
ARCHES="amd64 arm64 386"

log() { printf '\033[1;34m[upstream]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "${LOCK_FILE}" ] || die "lock file not found: ${LOCK_FILE}"

log "querying the GitHub Releases API for ${UPSTREAM_SLUG} (${WANTED_VERSION}) ..."

"${PYTHON}" - "${UPSTREAM_SLUG}" "${WANTED_VERSION}" "${ARCHES}" "${LOCK_FILE}" <<'PY'
import json
import os
import sys
import time
import urllib.error
import urllib.request

slug, wanted, arches, lock_path = sys.argv[1], sys.argv[2], sys.argv[3].split(), sys.argv[4]

proxies = {}
for key, value in (
    ("https", os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")),
    ("http", os.environ.get("HTTP_PROXY") or os.environ.get("http_proxy")),
):
    if value:
        proxies[key] = value
opener = urllib.request.build_opener(urllib.request.ProxyHandler(proxies))

if wanted in ("latest", "", "stable"):
    api = "https://api.github.com/repos/%s/releases/latest" % slug
else:
    api = "https://api.github.com/repos/%s/releases/tags/%s" % (slug, wanted)

headers = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "unraid-plugin-komari-agent-update-upstream",
}
token = os.environ.get("GITHUB_TOKEN")
if token:
    headers["Authorization"] = "Bearer " + token


def fetch(url):
    """Fetch JSON with a small retry loop; the API is intermittently flaky."""
    last = None
    for attempt in range(4):
        request = urllib.request.Request(url, headers=headers)
        try:
            with opener.open(request, timeout=120) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            last = "HTTP %s for %s" % (error.code, url)
            # 4xx other than 429 will not get better by retrying.
            if error.code != 429 and error.code < 500:
                break
        except Exception as error:  # noqa: BLE001 - the message is what matters
            last = str(error)
        time.sleep(3 * (attempt + 1))
    sys.exit("failed to query the GitHub API: %s\n"
             "Hint: set GITHUB_TOKEN to raise the rate limit, or check the proxy." % last)


release = fetch(api)
tag = release.get("tag_name", "").strip()
if not tag:
    sys.exit("the release has no tag_name")
if release.get("draft"):
    sys.exit("release %s is a draft; refusing to pin it" % tag)

assets = {a.get("name"): a for a in release.get("assets", [])}

sections = []
for arch in arches:
    name = "komari-agent-linux-%s" % arch
    asset = assets.get(name)
    if asset is None:
        sys.exit("release %s has no asset named %r" % (tag, name))

    digest = (asset.get("digest") or "").strip()
    if not digest.startswith("sha256:"):
        sys.exit("asset %r has no sha256 digest (got %r); refusing to pin an "
                 "unverifiable artifact" % (name, digest))
    sha256 = digest.split(":", 1)[1].lower()
    if len(sha256) != 64:
        sys.exit("asset %r has a malformed digest: %r" % (name, digest))

    url = asset.get("browser_download_url", "")
    if not url.startswith("https://"):
        sys.exit("asset %r has a non-https download url: %r" % (name, url))

    sections.append("\n".join([
        "[%s]" % arch,
        "name = %s" % name,
        "size = %d" % int(asset.get("size", 0)),
        "sha256 = %s" % sha256,
        "url = %s" % url,
    ]))

header = """\
# Upstream release lock for unraid-plugin-komari-agent.
#
# This file pins the exact komari-agent release asset that the plugin bundles.
# scripts/build-plugin.sh reads it and verifies the downloaded bytes against
# the SHA256 recorded here; scripts/update-upstream.sh refreshes it from the
# GitHub Releases API.
#
# Why a lock file instead of querying the API on every build:
#
#   * Reproducibility. The build must not depend on what the API returns
#     today. The lock file is part of the repository, so a checkout at a given
#     commit always produces the same package.
#   * Supply chain review. A new upstream version arrives as a diff to this
#     file that a human reviews, not as an invisible change during CI.
#   * Availability. The GitHub API is rate limited (60 requests per hour for
#     an unauthenticated client) and is intermittently unreachable from some
#     networks. A build that needs it fails for reasons that have nothing to
#     do with the code.
#
# The digest value comes from the "digest" field of the release asset in the
# GitHub Releases API response, which GitHub computes from the uploaded bytes.
#
# Generated by scripts/update-upstream.sh -- do not edit by hand.

[meta]
version = %s
""" % tag

text = header + "\n" + "\n\n".join(sections) + "\n"
with open(lock_path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(text)

print("pinned %s: %s" % (tag, ", ".join(arches)))
PY

log "updated ${LOCK_FILE}"
echo
sed -n '1,200p' "${LOCK_FILE}"
echo
log "review the diff, update CHANGELOG.md, then commit."
