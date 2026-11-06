# Contributing

Thanks for your interest in improving `unraid-plugin-komari-agent`.

## What this project is

A thin distribution wrapper. It does **not** patch `komari-agent`. The binary is
redistributed unmodified from the official GitHub Release, so bugs in the agent
itself — the WebSocket protocol, metric collection, the panel API, remote control
— belong upstream at
[komari-monitor/komari-agent](https://github.com/komari-monitor/komari-agent/issues).

In scope for this repo:

- the Unraid `.plg` definition and its install/uninstall scripts
- the Slackware package source tree under `src/` — package description, install
  hook, rc script, logrotate config, WebGUI pages
- the daemon supervision layer: `scripts/start.sh`, `supervise.sh`, `stop.sh`,
  `restart.sh`, `status.sh`, `clear-traffic.sh`
- the build, lint and verification scripts
- the Community Applications submission files
- documentation

## Development setup

Requirements:

- Bash 4+
- `curl`, `tar`
- Python 3 (renders the `.plg`, reads the upstream lock file, writes the txz)
- Optional: `php` (to run `php -l` on the WebGUI sources — the bundled checker is
  a heuristic, not a PHP parser)

No Go toolchain is needed; this repo never compiles upstream code.

On Windows, `python3` may resolve to a WindowsApps stub that does not run. Pass
the interpreter explicitly:

```bash
export PYTHON=D:/Python312/python.exe
```

```bash
git clone https://github.com/zhz8888/unraid-plugin-komari-agent.git
cd unraid-plugin-komari-agent

./scripts/build-plugin.sh     # build dist/
./scripts/lint-repo.sh        # source tree checks, no network, no build
./scripts/lint-plg.sh         # static checks on the generated .plg
"$PYTHON" scripts/check-php-syntax.py src/   # WebGUI source check
./scripts/verify-release.sh   # hash + layout verification
./scripts/smoke-test.sh       # run the packaged scripts under a fake root
```

`make build`, `make lint` and `make verify` are the same steps, and `make ci`
runs the whole sequence the `build` workflow runs, in the same order. `make help`
lists every target.

### What each check covers

| Command | Needs network | Needs a build | Covers |
|---|---|---|---|
| `scripts/lint-repo.sh` | no | no | Shell syntax of every script; the two rules that would abort an install (non-zero exit, shell error mode); LF line endings; the upstream pin agreeing across `plugin/upstream.lock`, the `Makefile` and `scripts/build-plugin.sh`; the workflow and issue template YAML; the CA metadata |
| `scripts/check-php-syntax.py` | no | no | The WebGUI PHP and `.page` files, plus a cross-check that every `ka_*` helper called is actually declared |
| `scripts/lint-plg.sh` | no | yes | The rendered `.plg`: XML shape, entity expansion, version scheme, `<FILE>` checksums, `<INLINE>` bash syntax, the no-non-zero-exit rule, leftover placeholders, token on the command line |
| `scripts/verify-release.sh` | no | yes | The built artifacts: txz checksum against the `.plg`, POSIX archive member names, file modes, launch target and icon resolution, `plugin.info` agreement, CA wrapper `pluginURL` against the `.plg` |
| `scripts/smoke-test.sh` | no | yes | Unpacks the package and runs `start.sh` / `stop.sh` / `status.sh` under a fake root with a stub agent |
| `scripts/check-upstream.sh` | **yes** | no | Whether the pin is coherent, and whether a newer upstream release exists |

### Checking for an upstream update

`scripts/check-upstream.sh` is the logic behind the nightly `upstream-check`
workflow, and it runs locally with the same semantics:

```bash
./scripts/check-upstream.sh              # human readable report
./scripts/check-upstream.sh --json       # one JSON object
GITHUB_TOKEN=$(gh auth token) ./scripts/check-upstream.sh   # raise the rate limit
```

It exits `0` when the check completed, whether or not an upgrade exists — "there
is no upgrade" is a successful check, and a check that failed every night would
train people to ignore it. It exits `1` when it could not complete: the pin
sources disagree, the lock file is malformed, the API is unreachable, or the
upstream release cannot be packaged. A rate limit is reported as a rate limit,
not as a wrong pin.

## Version scheme

Two versions are tracked independently:

| Variable | Format | Meaning |
|---|---|---|
| `PLUGIN_VERSION` | `YYYYMMDD` | This plugin's own release version: the release date. Defaults to the current local date; pin it for a reproducible build. |
| `KOMARI_VERSION` | `1.5.11` | The bundled `komari-agent` release. |
| `KOMARI_ARCH` | `amd64` | The upstream asset architecture. Only `amd64` is published. |

When more than one release happens on the same day, the later ones carry a
letter suffix:

```
20261106      the first release of that day
20261106.a    the second release of that day
20261106.b    the third release of that day
20261107      the next day
```

The Unraid installer compares plugin versions with `strcmp()`, a byte-wise
string compare, so the format has to sort in release order. This one does:

```
20261106 < 20261106.a < 20261106.b < 20261107
```

The first release of a day therefore carries no suffix. A semantic version does
not sort this way — `1.5.10` sorts *below* `1.5.9`, and Unraid would refuse the
upgrade. The plugin version must also be independent of the upstream version,
otherwise a repackaging of the same upstream release never reaches the users who
already installed it.

## Before opening a pull request

Run the checks and make sure they pass:

```bash
make ci
```

That is exactly what the `verify` job of the `build` workflow runs:
`lint-repo.sh`, `check-php-syntax.py`, the build, `lint-plg.sh`,
`verify-release.sh`, `smoke-test.sh` and the two reproducibility checks. Running
it locally first is the difference between a green PR and a round of review
comments about a missing `set -e`.

The build assembles the Slackware package from `src/` plus the upstream binary
and produces **two** plugin files from the single template
`plugin/unraid-plugin-komari-agent.plg.in`:

- `unraid-plugin-komari-agent.plg` — downloads from the GitHub release assets
- `unraid-plugin-komari-agent-proxy.plg` — downloads the same assets through the
  `https://gh-proxy.org/` mirror, for networks that cannot reach GitHub

Only the plugin URL, the download URLs and the source note differ between them;
the package, its SHA256 and the install scripts are identical. `lint-plg.sh`
checks both files, and `verify-release.sh` asserts that they reference the same
package with the same checksum.

> Install **one** of the two files, never both: the Unraid installer registers
> one symlink per `.plg` *file name*, so two files would show up as two entries in
> the Plugins tab. The canonical variant removes the mirrored one on the next
> boot.

The build is **reproducible**: building the same version twice must yield the
same txz SHA256, and it must not depend on *where* the working tree lives.

The archive is written by Python's `tarfile` module rather than by shelling out
to `tar`, because tar implementations disagree even when told to emit the same
format — GNU tar and bsdtar differ in the `mode` and `uname` header fields, in
member order (which follows `readdir`) and in how they write macOS extended
attributes. Using one implementation removes the whole class of problems: the
script sets every header field explicitly (uid/gid 0, empty uname/gname, fixed
mtime, 0755 for directories and executables, 0644 otherwise) and sorts the
member list, so Linux and macOS produce identical bytes by construction.

If your change alters the txz hash for an unchanged upstream version, check
staging determinism rather than bumping a checksum. Verify with:

```bash
git clone . /tmp/rebuild-check && (cd /tmp/rebuild-check && make build)
sha256sum dist/*.txz /tmp/rebuild-check/dist/*.txz   # must match
```

## Coding conventions

- Shell scripts: `#!/usr/bin/env bash`
- **The plugin scripts are the exception to the usual rule**: they must not
  enable `set -e` or `set -u`, and they must never exit non-zero. See the rules
  below — this is not an oversight.
- Build, lint and verify scripts may (and should) use `set -euo pipefail`
- All comments, log messages and user-facing output in **English**. The deep
  documentation under `docs/` is in Chinese, matching the README split.
- Keep scripts POSIX-friendly where practical, but bash is the target
- Prefer `command -v x` over `which x`
- Quote all variable expansions
- Do not hardcode hostnames, IP addresses or personal paths
- The WebGUI page text is English, like every other Unraid plugin page

## Updating the bundled version

The upstream pin lives in `plugin/upstream.lock`: version, asset name, byte size,
URL and SHA256 for each supported architecture. The build reads that file and
never queries the GitHub API, so an upstream bump is a reviewed diff rather than
an invisible change during CI.

1. Refresh the lock file from the GitHub Releases API:
   ```bash
   ./scripts/update-upstream.sh            # latest stable release
   ./scripts/update-upstream.sh 1.5.12     # a specific tag
   ```
   Review the diff: the version, size and SHA256 of every recorded architecture
   must change together.
2. Update the pin in `Makefile` (`KOMARI_VERSION ?=`) and in
   `scripts/build-plugin.sh` (`KOMARI_VERSION="${KOMARI_VERSION:-...}"`). The two
   must agree with the lock file; the build fails with an explicit message when
   they do not, `scripts/lint-repo.sh` fails in CI, and `scripts/check-upstream.sh`
   fails the scheduled run as well.
3. Confirm the pin is coherent before building:
   ```bash
   ./scripts/check-upstream.sh
   ```
   This is the same check the nightly workflow runs. Locally it needs
   `GITHUB_TOKEN` once the unauthenticated rate limit (60 requests per hour) is
   exhausted.
4. Build it: `make build`
5. Run the checks: `make lint && make verify`, then `make smoke`
6. **Review the upstream changelog** for added or renamed `AGENT_*` variables.
   Each variable the plugin maps is a row in the Settings page and a row in the
   configuration table of both READMEs. A new variable the plugin does not map is
   a missing feature; a renamed one silently breaks a setting.
7. Update `CHANGELOG.md`
8. Open a PR titled `chore: bump komari-agent to <version>`

The maintainer then tags a release and attaches the txz. The **tag is the plugin
version**, because the `.plg` points at the release asset under that tag.

## Rules the plugin scripts have to follow

These come from the Unraid plugin installer itself and are enforced by
`scripts/lint-plg.sh` and `scripts/verify-release.sh`:

- The install script must be **idempotent** — it runs again on every boot.
- The install script must **never exit non-zero**. A non-zero exit aborts the
  install, moves the `.plg` to `/boot/config/plugins-error/` and leaves the plugin
  unregistered, so the user cannot uninstall it from the WebGUI.
- The install script must not enable a shell error mode. `set -e` and `set -u`
  turn a failing command or an unset variable into a non-zero exit, which aborts
  the install just like an explicit `exit 1`.
- The install script must not prompt for input; the installer runs it
  non-interactively.
- The remove script must clean up the package, the binary, the rc script, the
  logrotate configuration and the WebGUI directory — but must not delete user
  data: the configuration file and the traffic counters stay.
- Every `<FILE>` with a `<URL>` needs a `<SHA256>`, and the cached file name has
  to contain the version, because the installer never overwrites a file that
  already exists.
- XML entities (`&name;`) are only expanded in attribute values and element
  text. Inside a CDATA section — which is where the `<CHANGES>` block and the
  `<INLINE>` scripts live — they stay literal, so use the build time placeholders
  (`@@NAME@@`) there instead. `scripts/lint-plg.sh` fails the build if an entity
  reference ends up inside a CDATA section.
- The agent token must never be passed on a command line. It goes through the
  environment only, so it does not show up in `ps`. `lint-plg.sh` checks this.

See [`docs/05-unraid-plugin-conventions.md`](docs/05-unraid-plugin-conventions.md)
for the full mapping.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/) are preferred.
Commit messages are written in **English**, matching the language of the code and
of the user-facing output.

```
feat: add arm64 build support
fix: keep the config file on uninstall
docs: clarify gh-proxy usage
chore: bump komari-agent to 1.5.12
```

## Reporting issues

Please include:

- Unraid version (`cat /etc/unraid-version`)
- Plugin version (`/etc/rc.d/rc.komari-agent status`, or the Settings page)
- Agent version (`/usr/local/sbin/komari-agent --help | head -1`)
- The relevant part of `/var/log/komari-agent.log`
- The exact command and its full output

## License

By contributing you agree that your contributions are licensed under the MIT
License (see `LICENSE`).
