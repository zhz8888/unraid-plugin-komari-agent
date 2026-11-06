# Security Policy

## Supported versions

Only the latest release receives fixes. Because this project tracks the upstream
`komari-agent` release, security fixes in the bundled binary come from
komari-monitor and arrive with a version bump.

| Version | Supported |
|---------|-----------|
| latest  | yes       |
| older   | no        |

## What this project controls

The redistributed binary is taken **unmodified** from the official GitHub
Release. The exact asset is pinned in `plugin/upstream.lock` — version, name,
byte size, URL and SHA256 — and the build verifies the downloaded bytes against
that digest before packaging. The recorded digest is the value GitHub publishes
in the `digest` field of the release asset. See `docs/01-design-decisions.md`
for the full verification chain.

Security issues that belong upstream — the agent's WebSocket protocol, metric
collection, the panel API, the remote-control implementation — should be reported
to <https://github.com/komari-monitor/komari-agent/security>.

## Reporting a vulnerability in this repo

Report issues in the packaging layer only:

- the `.plg` install/uninstall scripts
- the rc script and the supervisor loop
- the WebGUI page, its settings form and its action endpoint
- the build pipeline and its checksum handling
- anything that could cause a wrong or unverified binary to be distributed
- anything that could leak the agent token

Open a private security advisory at
<https://github.com/zhz8888/unraid-plugin-komari-agent/security/advisories/new>
rather than a public issue.

Please include:

- affected version
- a description of the impact
- reproduction steps or a proof of concept

## Security defaults

Two upstream features are **disabled by default** in this plugin, deliberately.
Both are documented in `README.md`; the reasoning is repeated here because it is a
security posture, not a convenience.

### Remote control is off (`DISABLE_WEB_SSH=1`)

`komari-agent` can accept panel-issued commands: an interactive shell (Web SSH)
and arbitrary command execution (RCE). Enabling it turns the Komari panel into a
remote-administration path into your server. It is off by default because a NAS
typically holds data far more sensitive than the host's own configuration, and
because the panel is a separate system whose compromise should not automatically
mean root on the Unraid host.

Enable it only when the panel is fully trusted, reachable over TLS, and its own
access control is sound.

### Self-update is off (`DISABLE_AUTO_UPDATE=1`)

The agent's built-in updater overwrites its own executable in place. In this
plugin that both wastes the download (`/usr` is an overlay and is reset on every
boot, so the updated binary is discarded at the next reboot) and breaks supply
chain verification: what runs on the host stops matching the checksum the plugin
pinned and verified. Keeping it off means the binary on the host is always the
one this project built and verified.

## The agent token

The token authenticates the host to the panel. Handling:

- It is passed to the agent **only** through the environment (`AGENT_TOKEN`),
  never on a command line, so it does not appear in `ps` or
  `/proc/<pid>/cmdline`.
- It is stored in
  `/boot/config/plugins/unraid-plugin-komari-agent/komari-agent.cfg` on the
  flash device. Flash is not encrypted. Anyone who can physically take the USB
  stick, or who has root on the host, can read it.
- The Settings page writes it through Unraid's `/update.php`; the action endpoint
  never accepts a value that reaches a shell.
- If it leaks: revoke it in the panel, paste the replacement into the Settings
  page, restart the agent. No reinstall is required.
- Never paste a real token into an issue, a pull request, a log excerpt or a
  screenshot.

## Known operational caveats

These are documented limitations rather than vulnerabilities, but they matter
when deploying:

- **The agent listens to the panel.** It makes outbound connections to the panel
  endpoint; it does not open a listening port of its own. Firewall accordingly.
- **`IGNORE_UNSAFE_CERT=1` disables TLS certificate validation.** It is a
  last resort for a self-signed panel certificate, and it makes the connection
  trivially interceptable. Prefer installing a valid certificate.
- **The traffic counters are written to the flash device** (a vfat USB stick)
  every ten minutes. That is a wear and corruption consideration, not a
  confidentiality one; the file contains byte counters only.
- **`/var/log/komari-agent.log` is on a tmpfs** and is world-readable by default
  on Unraid. The agent logs the panel endpoint but not the token.
- **The plugin runs as root.** Every Unraid plugin does; the WebGUI and the rc
  scripts both run as root. Do not expose the Unraid WebGUI to untrusted
  networks.
