# Komari Agent

Runs the [komari-agent](https://github.com/komari-monitor/komari-agent) daemon
on Unraid, so this server shows up in a Komari monitoring dashboard.

The agent reports CPU, memory, disk, network throughput, load and uptime over a
WebSocket connection. Remote command execution and Web SSH are available but
disabled by default.

- Plugin version: `@@PLUGIN_VERSION@@`
- Bundled komari-agent: `@@UPSTREAM_VERSION@@`

## Setup

1. Add this server in your Komari panel and copy the agent token it shows.
2. Open **Settings &rarr; Komari Agent &rarr; Settings**.
3. Fill in **Panel endpoint** (for example `https://komari.example.com`) and
   **Agent token**.
4. Press **Apply**. The agent starts immediately and again on every boot.

## How it runs

Unraid has no systemd, so the plugin brings its own supervision:

| Component | Path |
| --- | --- |
| Agent binary | `/usr/local/sbin/komari-agent` |
| Supervisor | `/usr/local/emhttp/plugins/unraid-plugin-komari-agent/scripts/supervise.sh` |
| Service script | `/etc/rc.d/rc.komari-agent` |
| Configuration | `/boot/config/plugins/unraid-plugin-komari-agent/komari-agent.cfg` |
| Traffic counters | `/boot/config/plugins/unraid-plugin-komari-agent/net_static.json` |
| Log | `/var/log/komari-agent.log` |
| PID file | `/var/run/komari-agent.pid` |

`/usr` is an overlay filesystem on Unraid and is reset on every boot, so the
binary lives on the flash device as a cache and is copied into place by the
install script at every boot. The traffic counters are written to the flash
device because the agent keeps them relative to its working directory and they
have to survive a reboot.

The log is on the RAM disk, which means it starts empty after a reboot and never
wears the flash device.

## Defaults that differ from upstream

| Setting | Plugin default | Why |
| --- | --- | --- |
| `DISABLE_AUTO_UPDATE` | `1` | The agent would otherwise overwrite its own binary every few hours, which undoes the version this plugin pins and verifies. |
| `DISABLE_WEB_SSH` | `1` | A panel that can open a root shell on this server is a large attack surface. |
| `MEMORY_INCLUDE_CACHE` | `1` | Unraid uses free RAM as a disk cache; reporting it as available matches the Unraid dashboard. |

Both security defaults can be changed in the Advanced section of the settings
page. See the warning there before doing so.

## Uninstalling

Remove the plugin from the **Plugins** tab. The configuration file, the traffic
counters and the cached binary under `/boot/config/plugins/unraid-plugin-komari-agent/`
are kept, so reinstalling picks up where you left off. Delete that directory
manually if you want a clean slate.

## Notes

- The agent talks to the panel over the network. If your panel is behind a
  reverse proxy, use the public address the browser uses, not the container
  address.
- A self-signed certificate on the panel needs **Ignore unsafe certificates**,
  which disables TLS validation for that connection.
- Traffic counters are collected only while the agent runs. Stopping the agent
  pauses the accounting; it does not reset it.
