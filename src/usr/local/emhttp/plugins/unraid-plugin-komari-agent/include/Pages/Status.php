<?php
/**
 * Status view of the unraid-plugin-komari-agent WebGUI.
 *
 * Copyright (C) 2026 zhz8888
 * SPDX-License-Identifier: MIT
 *
 * The page renders immediately and everything that describes the service is
 * fetched afterwards from include/data/Status.php.
 *
 * That split is deliberate and follows the contract: nothing that can block is
 * run while the page is being rendered. The endpoint runs scripts/status.sh,
 * which is a subprocess, and it probes the panel over the network; doing either
 * during the render would hold up the whole tab for as long as their timeouts.
 *
 * It also keeps a single source of truth. The service, binary and log facts
 * come from scripts/status.sh in the endpoint and nowhere else, so the page
 * cannot disagree with what the boot process and the command line see. The
 * only things this file reads itself are plugin.info and the configuration
 * file, which are two small local file reads with no failure mode worth
 * deferring.
 *
 * The same file backs two tabs:
 *
 *   summary  the landing tab: is the agent up, is the panel reachable, and the
 *            three buttons a user needs when something is wrong
 *   detail   the Status tab: binary integrity, traffic accounting, log tail
 *
 * The mode is chosen by the .page file that includes this one, so the polling
 * JavaScript and the endpoint contract stay in a single place.
 */

require_once dirname(__DIR__) . '/common.php';

$komariMode = isset($komariStatusMode) && $komariStatusMode === 'detail' ? 'detail' : 'summary';

$info = komari_plugin_info();
$cfg = komari_cfg();

$endpoint = '/plugins/' . KOMARI_PLUGIN_NAME . '/include/data/Status.php';
$actionEndpoint = '/plugins/' . KOMARI_PLUGIN_NAME . '/include/data/Action.php';
?>
<style>
    .komari-state {
        display: inline-block;
        padding: 2px 10px;
        border-radius: 10px;
        font-weight: bold;
    }
    .komari-state.state-running { background: #e6f4ea; color: #1e7e34; }
    .komari-state.state-degraded { background: #fff4e5; color: #a05a00; }
    .komari-state.state-stopped { background: #fdecea; color: #b02a37; }
    .komari-state.state-unknown { background: #eceff1; color: #455a64; }
    .komari-log {
        margin: 0;
        max-height: 340px;
        overflow: auto;
        white-space: pre-wrap;
        word-break: break-all;
        font-size: 12px;
        line-height: 1.45;
        background: rgba(0, 0, 0, 0.05);
        padding: 8px;
        border-radius: 4px;
    }
    .komari-muted { opacity: 0.7; }
</style>

<?php if (!$cfg['ENABLED']) { ?>
<div class="notice">
    <strong>The agent is disabled.</strong>
    It will not be started at boot. Turn it on in the Settings tab when you want
    it to report to the panel again.
</div>
<?php } elseif (!komari_cfg_is_configured()) { ?>
<div class="notice">
    <strong>The agent is not configured yet.</strong>
    Add the panel address and the agent token in the Settings tab. Until both
    are set the start script exits without starting anything.
</div>
<?php } ?>

<div id="komari-binary-warning"></div>

<table class="unraid">
    <tr>
        <td colspan="2" style="padding-bottom:8px">
            <strong>Komari Agent</strong> &mdash; reports CPU, memory, disk, network
            and uptime to a Komari dashboard.
        </td>
    </tr>
    <?php
    echo komari_row_html(
        'Service state',
        '<span id="komari-state" class="komari-state state-unknown">checking ...</span>'
    );
    echo komari_row_html('Uptime', '<span id="komari-uptime">checking ...</span>');
    echo komari_row_html('Processes', '<span id="komari-pids">checking ...</span>');
    echo komari_row_html('Panel', '<span id="komari-panel">'
        . komari_esc($cfg['ENDPOINT'] !== '' ? $cfg['ENDPOINT'] : 'not configured') . '</span>');
    echo komari_row('Agent binary', KOMARI_BINARY);
    echo komari_row('Agent log', KOMARI_LOG);
    ?>
</table>

<?php if ($komariMode === 'summary') { ?>
<br>
<div class="fieldset">
    <div class="legend">Actions</div>
    <table class="unraid">
        <tr>
            <td>
                <span>
                    <input type="button" class="button" value="Start"
                           data-komari-action="start">
                    <input type="button" class="button" value="Restart"
                           data-komari-action="restart">
                    <input type="button" class="button" value="Stop"
                           data-komari-action="stop">
                </span>
                <div class="hint">
                    These run the plugin service scripts. A restart gives the running
                    agent up to ten seconds to flush its traffic counters before it is
                    stopped, so the numbers on the panel stay correct.
                </div>
            </td>
        </tr>
        <tr>
            <td>
                <div id="komari-action-result" class="hint"></div>
            </td>
        </tr>
    </table>
</div>

<br>
<div class="fieldset">
    <div class="legend">Panel connection</div>
    <table class="unraid">
        <?php
        echo komari_row_html('Endpoint', '<span id="komari-panel-endpoint">'
            . komari_esc($cfg['ENDPOINT'] !== '' ? $cfg['ENDPOINT'] : 'not configured') . '</span>');
        echo komari_row_html('Token', '<span id="komari-panel-token">'
            . komari_esc($cfg['TOKEN'] !== '' ? 'set' : 'not set') . '</span>');
        echo komari_row_html('Reachability', '<span id="komari-panel-probe">checking ...</span>');
        echo komari_row_html('Report interval', '<span id="komari-last-report">'
            . komari_esc($cfg['INTERVAL']) . ' seconds</span>');
        ?>
    </table>
    <div class="hint" style="margin-top:6px">
        Reachability is a TCP connection to the panel host and port. A failure here
        means the agent cannot reach the panel either; check the log below and the
        DNS and firewall settings of this server.
    </div>
</div>

<br>
<div class="fieldset">
    <div class="legend">Recent activity</div>
    <pre class="komari-log" id="komari-log">loading ...</pre>
</div>
<?php } else { ?>
<br>
<div class="fieldset">
    <div class="legend">Binary</div>
    <table class="unraid">
        <?php
        echo komari_row_html('Path', '<code>' . komari_esc(KOMARI_BINARY) . '</code>');
        echo komari_row_html('Installed', '<span id="komari-bin-present">checking ...</span>');
        echo komari_row_html('Size', '<span id="komari-bin-size">checking ...</span>');
        echo komari_row_html('Matches the pinned hash', '<span id="komari-bin-pin">checking ...</span>');
        echo komari_row_html('Flash cache', '<code>' . komari_esc(KOMARI_BIN_CACHE) . '</code>'
            . ' <span id="komari-bin-cache"></span>');
        ?>
    </table>
    <div class="hint" style="margin-top:6px">
        The install script copies the pinned binary from the flash cache to
        <code>/usr/local/sbin</code> on every boot, because <code>/usr</code> is
        reset at boot. A hash that does not match the pinned value means the file
        was replaced by something other than this plugin.
    </div>
</div>

<br>
<div class="fieldset">
    <div class="legend">Traffic accounting</div>
    <table class="unraid">
        <?php
        echo komari_row_html('Statistics file', '<code>' . komari_esc(KOMARI_NET_STATIC) . '</code>');
        echo komari_row_html('Total sent', '<span id="komari-traffic-tx">-</span>');
        echo komari_row_html('Total received', '<span id="komari-traffic-rx">-</span>');
        echo komari_row_html('Samples', '<span id="komari-traffic-points">-</span>');
        echo komari_row_html('Last sample', '<span id="komari-traffic-last">-</span>');
        ?>
    </table>
    <div id="komari-traffic-table" style="margin-top:10px"></div>
    <div class="hint" style="margin-top:6px">
        The agent keeps its counters in its working directory on the flash device,
        so the totals survive a reboot. Clearing them stops the agent, replaces the
        file and starts it again, because the agent has no control socket and would
        otherwise write its in-memory state back over the reset.
    </div>
</div>

<br>
<div class="fieldset">
    <div class="legend">Agent log</div>
    <div class="hint" style="margin-bottom:6px">
        <code><?php echo komari_esc(KOMARI_LOG); ?></code> &mdash; the log lives on
        the RAM disk, so it starts empty after every reboot. Rotation keeps it from
        growing without bound while the server is up.
    </div>
    <pre class="komari-log" id="komari-log">loading ...</pre>
</div>
<?php } ?>

<div id="komari-status-error"></div>

<script type="text/javascript">
(function () {
    'use strict';

    var statusEndpoint = <?php echo json_encode($endpoint); ?>;
    var actionEndpoint = <?php echo json_encode($actionEndpoint); ?>;
    var mode = <?php echo json_encode($komariMode); ?>;

    function byId(id) {
        return document.getElementById(id);
    }

    function setText(id, text) {
        var element = byId(id);
        if (element) {
            element.textContent = text;
        }
    }

    function makeNotice(className, title, detail) {
        var box = document.createElement('div');
        box.className = className;

        var strong = document.createElement('strong');
        strong.textContent = title;
        box.appendChild(strong);
        box.appendChild(document.createTextNode(' ' + detail));

        return box;
    }

    function renderTraffic(traffic) {
        var box = byId('komari-traffic-table');
        if (!box) {
            return;
        }
        box.textContent = '';

        if (!traffic || !traffic.available) {
            var note = document.createElement('em');
            note.className = 'komari-muted';
            note.textContent = (traffic && traffic.error)
                ? traffic.error
                : 'No traffic statistics are available yet.';
            box.appendChild(note);
            return;
        }

        var interfaces = traffic.interfaces || [];
        if (interfaces.length === 0) {
            var empty = document.createElement('em');
            empty.className = 'komari-muted';
            empty.textContent = 'No interface has recorded traffic yet.';
            box.appendChild(empty);
            return;
        }

        var table = document.createElement('table');
        table.className = 'unraid';

        var head = document.createElement('thead');
        var headRow = document.createElement('tr');
        ['Interface', 'Sent', 'Received', 'Samples'].forEach(function (label) {
            var cell = document.createElement('td');
            cell.textContent = label;
            headRow.appendChild(cell);
        });
        head.appendChild(headRow);
        table.appendChild(head);

        var body = document.createElement('tbody');
        interfaces.forEach(function (entry) {
            var row = document.createElement('tr');
            [entry.name, entry.tx_human, entry.rx_human, String(entry.points)].forEach(
                function (value) {
                    var cell = document.createElement('td');
                    cell.textContent = value;
                    row.appendChild(cell);
                }
            );
            body.appendChild(row);
        });
        table.appendChild(body);
        box.appendChild(table);
    }

    function renderLog(log) {
        var target = byId('komari-log');
        if (!target) {
            return;
        }

        if (!log || !log.lines || log.lines.length === 0) {
            target.textContent = (log && log.error) ? log.error : 'The log is empty.';
            return;
        }

        // textContent, never innerHTML: the log is agent output and may contain
        // anything the panel sent it.
        target.textContent = log.lines.join('\n');
        target.scrollTop = target.scrollHeight;
    }

    function renderPanel(panel) {
        var target = byId('komari-panel-probe');
        if (!target) {
            return;
        }
        if (!panel) {
            target.textContent = 'unknown';
            return;
        }
        if (panel.reachable) {
            target.textContent = 'reachable' + (panel.latency_ms !== null
                ? ' (' + panel.latency_ms + ' ms)'
                : '');
            return;
        }
        target.textContent = panel.error ? ('not reachable: ' + panel.error) : 'not reachable';
    }

    function renderState(service) {
        var element = byId('komari-state');
        if (!element || !service) {
            return;
        }
        var state = service.state || 'unknown';
        element.textContent = state.charAt(0).toUpperCase() + state.slice(1);
        element.className = 'komari-state state-' + state;

        var pids = [];
        if (service.supervisor_pid) {
            pids.push('supervisor ' + service.supervisor_pid);
        }
        if (service.agent_pids && service.agent_pids.length) {
            pids.push('agent ' + service.agent_pids.join(', '));
        } else if (service.agent_pid) {
            pids.push('agent ' + service.agent_pid);
        }
        setText('komari-pids', pids.length ? pids.join('; ') : 'none');
        setText('komari-uptime', service.uptime_human || 'unknown');
    }

    function renderBinary(binary) {
        var warning = byId('komari-binary-warning');
        if (warning) {
            warning.textContent = '';
            if (binary && !binary.installed) {
                warning.appendChild(makeNotice(
                    'error',
                    'The agent binary is not installed.',
                    'Reinstall the plugin; the install script restores it from the '
                        + 'copy on the flash device.'
                ));
            }
        }

        if (!binary) {
            return;
        }
        setText('komari-bin-present', binary.installed ? 'yes' : 'no');
        setText('komari-bin-size', binary.size_human || 'unknown');
        setText('komari-bin-pin', binary.pin_state || 'unknown');
        setText('komari-bin-cache', binary.cache_present ? '(present)' : '(missing)');
    }

    function showError(text) {
        var box = byId('komari-status-error');
        if (!box) {
            return;
        }
        box.textContent = '';
        var message = document.createElement('div');
        message.className = 'error';
        message.textContent = text;
        box.appendChild(message);
    }

    function refresh() {
        $.post(statusEndpoint, {}, function (data) {
            if (!data || data.ok !== true) {
                showError((data && data.error)
                    ? ('The status could not be loaded: ' + data.error)
                    : 'The status could not be loaded. See the WebGUI log for details.');
                return;
            }

            renderState(data.service);
            renderPanel(data.panel);
            renderLog(data.log);
            renderBinary(data.binary);

            if (mode === 'detail') {
                renderTraffic(data.traffic);

                var traffic = data.traffic || {};
                setText('komari-traffic-tx', traffic.available ? traffic.total_tx_human : '-');
                setText('komari-traffic-rx', traffic.available ? traffic.total_rx_human : '-');
                setText('komari-traffic-points', traffic.available
                    ? String(traffic.points)
                    : '-');
                setText('komari-traffic-last', traffic.available
                    ? (traffic.last_human || 'never')
                    : '-');
            }

            if (data.config) {
                setText('komari-panel-endpoint', data.config.endpoint || 'not configured');
                setText('komari-panel-token', data.config.token_set ? 'set' : 'not set');
                setText('komari-last-report', (data.config.interval || '3') + ' seconds');
            }
        }, 'json').fail(function () {
            showError('The status endpoint did not answer. See the WebGUI log for details.');
        });
    }

    document.addEventListener('click', function (event) {
        var target = event.target;
        if (!target || !target.getAttribute) {
            return;
        }
        var action = target.getAttribute('data-komari-action');
        if (!action) {
            return;
        }

        event.preventDefault();
        target.disabled = true;

        var result = byId('komari-action-result');
        if (result) {
            result.textContent = 'Working ...';
        }

        $.post(actionEndpoint, {action: action}, function (data) {
            var message = (data && data.message) ? data.message : 'Done.';
            if (result) {
                result.textContent = message;
            }
            window.setTimeout(refresh, 3000);
        }, 'json').fail(function () {
            if (result) {
                result.textContent = 'The action failed. See the WebGUI log for details.';
            }
        });
    });

    $(refresh);
})();
</script>
