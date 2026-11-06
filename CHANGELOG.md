# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

<!--
  The link definitions live here, above the first heading, on purpose.
  scripts/build-plugin.sh copies the body of one release section into the
  .plg's <CHANGES> block by matching "## [<version>]" up to the next "## "
  heading. A definition at the bottom of the file would therefore be swallowed
  into the last release's notes and rendered as literal text in the Unraid
  plugin manager. Markdown resolves definitions from anywhere in the document,
  so putting them first costs nothing and keeps the generated block clean.
-->

[Unreleased]: https://github.com/zhz8888/unraid-plugin-komari-agent/compare/20261106...HEAD
[20261106]: https://github.com/zhz8888/unraid-plugin-komari-agent/releases/tag/20261106

The **plugin version** is the release date, `YYYYMMDD`. When more than one release
happens on the same day, the later ones carry a letter suffix: `20261106.a`,
`20261106.b` and so on. The Unraid installer compares plugin versions with
`strcmp()`, a byte-wise string compare, so the format has to sort in release
order, and this one does:

```
20261106 < 20261106.a < 20261106.b < 20261107
```

A semantic version does not sort that way — `1.5.10` sorts *below* `1.5.9`,
because the byte `1` is less than `9`, and Unraid would refuse the upgrade.

The **upstream version** (the bundled `komari-agent` release) is tracked
separately and is recorded in `plugin.info`, in the `.plg`'s `upstream` entity and
on the WebGUI page.

## [Unreleased]

### Added

- WebGUI pages under `Settings → Komari Agent`: a settings form that writes the
  configuration through `/update.php`, and a status tab that reports the
  supervisor and agent state, the agent version, uptime, the tail of the log and
  a panel connectivity probe
- An action endpoint with a fixed allowlist (`restart`, `stop`, `start`,
  `clear-traffic`). Commands are defined server side; a request value never
  reaches a shell, and same-origin is verified
- `scripts/supervise.sh` — a crash-restart loop, because Unraid has no systemd
  `Restart=always`
- `/etc/logrotate.d/komari-agent` — the log lives on a 128 MB tmpfs and has to be
  rotated
- Plugin icon and a `README.md` in the plugin directory, so the Plugins tab shows
  a real icon and a real description
- `ca_profile.xml` and `ca/unraid-plugin-komari-agent.xml` — the files a
  Community Applications submission needs
- `scripts/make-icon.py` — regenerates the plugin icon
- `scripts/fetch-plugin.sh` — download, verify and inspect an upstream release
  without packaging it
- `scripts/check-upstream.sh` — compares the pinned upstream release with the
  latest one. This is the logic behind the nightly `upstream-check` workflow,
  extracted into a script so it can be run locally with the same semantics, and
  so the workflow and the local run cannot drift apart. It reports a rate limit
  or a network failure differently from a genuinely missing release, because
  telling a maintainer their pin is wrong when the real problem is a 403 sends
  them looking in the wrong place. Exit status `0` means the check completed,
  whether or not an upgrade exists.
- `docs/05-unraid-plugin-conventions.md` — rule by rule mapping of the official
  Unraid plugin rules onto this plugin

### Changed

- The plugin version is decoupled from the upstream version. Tying them together
  means Unraid compares `1.5.11` with `1.5.9` byte-wise, judges the new release to
  be older and refuses the upgrade. The plugin version is now the release date;
  the upstream version is recorded separately.
- `.github/workflows/upstream-check.yml` no longer contains the comparison
  logic. It schedules `scripts/check-upstream.sh`, turns its exit status into a
  red run, writes a job summary, and opens the issue from a body the script
  generated next to the comparison it describes.
- `DISABLE_AUTO_UPDATE` defaults to `1`. The agent's built-in updater overwrites
  its own executable in place, which the overlay filesystem throws away on the
  next reboot, and which bypasses the checksum the plugin pins.
- `DISABLE_WEB_SSH` defaults to `1`. Panel-issued remote control is a
  remote-administration backdoor and is a poor default for a NAS.
- The agent is configured through `AGENT_*` environment variables rather than
  command line arguments, so the token never appears in `ps` or
  `/proc/<pid>/cmdline`.
- The working directory is the flash plugin directory, because the agent writes
  its traffic counters to `./net_static.json` and flash is the only persistent
  writable location on Unraid.
- The Slackware package version is the plugin version, so `upgradepkg` sees an
  upgrade when the plugin is repackaged.
- The mirrored `.plg` no longer coexists with the canonical one: the canonical
  variant removes it on the next boot, the way the official Tailscale plugin
  removes its preview build.
- `lint-plg.sh` checks the official conventions: required attributes, the
  version scheme, the changelog layout, SHA256 on every download, the install and
  remove scripts, the absence of a non-zero exit, and the absence of a shell
  error mode.
- `verify-release.sh` checks the package layout, the build metadata, the binary
  and package checksums pinned in the `.plg`, and that the `launch` target
  resolves to a page inside the package.
- `scripts/check-php-syntax.py` checks the WebGUI sources for unbalanced
  delimiters and unterminated strings, so a typo in a page does not break the
  Settings tab.
- The build retries the downloads in an explicit loop. `curl --retry` does not
  cover TLS handshake failures, so a single flaky connection used to abort the
  build.

### Fixed

- The install script no longer exits non-zero on a recoverable error. The Unraid
  installer moves a `.plg` to `/boot/config/plugins-error/` when the install
  script fails and does not register the plugin, so the user was left without an
  Uninstall button in the WebGUI and without a retry at the next boot.
- The install script no longer enables a shell error mode. `set -e` or `set -u`
  turns an unset variable into a non-zero exit, which aborts the install exactly
  like an explicit `exit 1`.
- The install script removes superseded packages from the flash cache, which
  otherwise grows with every release.
- The remove script keeps the configuration file and the traffic counters. They
  are user data, not packaging state.

## [20261106] - 2026-11-06

First release. Bundles `komari-agent` 1.5.11 for Linux x86_64
(`komari-agent-linux-amd64`, 12,585,218 bytes, SHA256
`78c28d89e523816baea010c0ed0714f245f508ffdaca0540f5c9f230f7053c8c`).

### Added

- Unraid `.plg` definition that installs the agent as a managed service:
  a Slackware package via `upgradepkg`, the binary into
  `/usr/local/sbin/komari-agent`, an rc script at
  `/etc/rc.d/rc.komari-agent`, log rotation and a Settings page
- Flash-resident binary cache. `/usr` is an overlay filesystem on Unraid and is
  reset on every boot, so the executable is re-installed from the cache on every
  boot
- Supervisor loop that restarts the agent when it crashes, since Unraid has no
  systemd to do it
- Build pipeline that reads the upstream pin from `plugin/upstream.lock`,
  downloads the release asset, verifies the bytes against the recorded SHA256,
  checks that the result is an ELF image for the requested architecture, and
  packs a reproducible Slackware txz. The build never queries the GitHub API,
  so it stays reproducible and offline capable
- `scripts/update-upstream.sh` refreshes `plugin/upstream.lock` from the GitHub
  Releases API, turning an upstream bump into a reviewable diff
- Mirrored plugin file `unraid-plugin-komari-agent-proxy.plg` for networks that
  cannot reach GitHub. It installs the identical package, with the same SHA256,
  but downloads it through `https://gh-proxy.org/`
- `scripts/build-plugin.sh`, `scripts/lint-plg.sh`, `scripts/verify-release.sh`
  and `scripts/check-php-syntax.py`
- `scripts/smoke-test.sh` — unpacks the built package and runs its shell scripts
  under a fake root, which catches what a static lint cannot: a script that dies
  on an unset variable, a config reader that cannot parse what the WebGUI writes,
  a start script that starts two instances, a stop script that leaves a process
  behind
- GitHub Actions workflows for build verification and upstream version checks
- Issue and pull request templates
- Documentation covering the design decision, the technical design and the
  mapping to the official plugin rules
