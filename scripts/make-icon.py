#!/usr/bin/env python3
"""Fetch the official Komari icon and write the plugin icon.

The plugin icon is the upstream Komari mascot, not a drawing of our own: the
Plugins tab should show the same mark the panel does, so that a user who knows
Komari recognises the plugin at a glance. The image is therefore fetched from
the upstream repository rather than generated, and this script exists so that
the step is reproducible and reviewable instead of "someone saved a PNG once".

Source
    komari-monitor/komari-web, public/assets/pwa-icon.webp -- the 512x512
    icon the panel ships as its PWA icon. It is the highest resolution copy of
    the mark that upstream publishes, which is what makes a clean 256x256
    downsample possible.

    The file is pinned to a commit, not to a branch. A branch would let the
    icon change under a build that did not, and the package is meant to be
    reproducible.

Licence
    The upstream Komari project is MIT licensed, and the icon is redistributed
    unmodified apart from the downscale. See NOTICE for the attribution.

Usage
    python3 scripts/make-icon.py [output.png]

    Needs Pillow and network access. The committed PNG is the artifact; this
    script only regenerates it.
"""

import io
import os
import sys
import urllib.request

from PIL import Image

# Pinned to a commit so the icon cannot change under a build that did not.
# Bump this deliberately, in its own commit, and re-run the script.
SOURCE_COMMIT = "aa4e78bb40c2fc5569af065b7999a33e1bab1374"
SOURCE_PATH = "public/assets/pwa-icon.webp"
SOURCE_URL = (
    "https://raw.githubusercontent.com/komari-monitor/komari-web/"
    + SOURCE_COMMIT + "/" + SOURCE_PATH
)

# The size the Unraid WebGUI renders in the Plugins tab. The source is 512x512,
# so this is a clean 2:1 downsample with Lanczos.
SIZE = 256


def fetch(url):
    """Return the bytes at url, honouring the usual proxy variables."""
    proxies = {}
    for key, value in (
        ("https", os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")),
        ("http", os.environ.get("HTTP_PROXY") or os.environ.get("http_proxy")),
    ):
        if value:
            proxies[key] = value

    opener = urllib.request.build_opener(urllib.request.ProxyHandler(proxies))
    request = urllib.request.Request(url, headers={
        "User-Agent": "unraid-plugin-komari-agent-make-icon",
    })
    with opener.open(request, timeout=120) as response:
        return response.read()


def default_output():
    """The icon location inside the package source tree."""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(
        root,
        "src",
        "usr",
        "local",
        "emhttp",
        "plugins",
        "unraid-plugin-komari-agent",
        "unraid-plugin-komari-agent.png",
    )


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else default_output()

    print("fetching %s" % SOURCE_URL)
    data = fetch(SOURCE_URL)
    if not data:
        sys.exit("the server returned an empty body")

    image = Image.open(io.BytesIO(data))
    print("source: %s %s %s" % (image.format, image.size[0], image.size[1]))
    image = image.convert("RGBA")

    if image.size != (SIZE, SIZE):
        image = image.resize((SIZE, SIZE), Image.LANCZOS)

    directory = os.path.dirname(os.path.abspath(out_path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    image.save(out_path, format="PNG", optimize=True)

    print("written %s (%d bytes)" % (out_path, os.path.getsize(out_path)))


if __name__ == "__main__":
    main()
