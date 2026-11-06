<?php
/**
 * Settings tab of the unraid-plugin-komari-agent WebGUI.
 *
 * Copyright (C) 2026 zhz8888
 * SPDX-License-Identifier: MIT
 *
 * The form posts to the official /update.php, which is what every Unraid
 * plugin uses to write a configuration file:
 *
 *   #file     the file to write, relative to /boot/config/plugins/
 *   #cleanup  omit keys whose value is empty instead of writing KEY=""
 *   #command  run this after saving; its output is streamed to the progress
 *             frame, so the restart is visible to the user
 *
 * /update.php writes every posted key as KEY="value" into a flat INI file, and
 * keys that are already in the file but not posted keep their old value. That
 * last part is why the booleans are <select> elements and not checkboxes: an
 * unchecked checkbox is not submitted at all, so it could never turn a "Yes"
 * back into a "No".
 */

require_once dirname(__DIR__) . '/common.php';

$info = komari_plugin_info();
$cfg = komari_cfg();

$configured = komari_cfg_is_configured();
$restartScript = komari_script_path('restart.sh');

$actionEndpoint = '/plugins/' . KOMARI_PLUGIN_NAME . '/include/data/Action.php';
$restartCommand = KOMARI_SCRIPTS . '/restart.sh';

$preferOptions = array(
    '' => 'Automatic',
    '4' => 'IPv4',
    '6' => 'IPv6',
);
?>
<link type="text/css" rel="stylesheet" href="/webGui/styles/jquery.switchbutton.css">
<span class="status vhshift"><input type="checkbox" class="advancedview"></span>

<?php if (!$configured) { ?>
<div class="notice">
    <strong>The agent is not configured yet.</strong>
    Set the panel address and the agent token below, then press Apply.
    Until both are set the start script exits without doing anything.
</div>
<?php } ?>

<?php if ($restartScript === null) { ?>
<div class="error">
    <strong>The service scripts are missing from this installation.</strong>
    Reinstall the plugin from the Plugins tab. The settings can still be saved,
    but the agent cannot be started until the package is in place.
</div>
<?php } ?>

<form method="POST" action="/update.php" target="progressFrame" id="komari-settings-form">
<input type="hidden" name="#file" value="<?php echo komari_esc(KOMARI_PLUGIN_NAME); ?>/komari-agent.cfg">
<input type="hidden" name="#cleanup" value="">
<input type="hidden" name="#command" value="<?php echo komari_esc($restartCommand); ?>">

<table class="unraid tablesorter">
    <thead><tr><td>Komari panel</td></tr></thead>
</table>

<?php
echo komari_field(
    'Enable the agent',
    komari_select_bool('ENABLED', $cfg['ENABLED']),
    'When this is No the agent is not started at boot or after an install, and '
    . 'saving the settings stops a running agent. The binary and the configuration '
    . 'are kept, so switching it back on is all it takes to resume reporting.'
);

echo komari_field(
    'Panel endpoint',
    komari_text_input('ENDPOINT', $cfg['ENDPOINT'], 'wide', 'https://komari.example.com'),
    'The base address of your Komari panel, including the scheme and the port when '
    . 'it is not the default one. The agent connects to it over a WebSocket, so the '
    . 'address has to be reachable from this server.'
);

echo komari_field(
    'Agent token',
    '<input type="password" name="TOKEN" class="wide" autocomplete="new-password"'
    . ' spellcheck="false" value="' . komari_esc($cfg['TOKEN']) . '">'
    . ' <input type="button" class="button" id="komari-token-toggle" value="Show">',
    'The token of this server in the Komari panel. It is passed to the agent through '
    . 'an environment variable and never appears on a command line, so it is not '
    . 'visible in the process list.'
);

echo komari_field(
    'Report interval',
    komari_number_input('INTERVAL', $cfg['INTERVAL'], 1, 300) . ' seconds',
    'How often the agent collects and reports CPU, memory, disk and network data. '
    . 'Three seconds is a good default; a shorter interval only adds load on both '
    . 'sides without making the graphs more useful.'
);
?>

<table class="unraid tablesorter">
    <thead><tr><td>Security</td></tr></thead>
</table>

<?php
echo komari_field(
    'Disable agent self-update',
    komari_select_bool('DISABLE_AUTO_UPDATE', $cfg['DISABLE_AUTO_UPDATE']),
    'Recommended: Yes. The agent would otherwise replace its own executable every '
    . 'few hours, which fights the version this plugin pins and verifies. Upgrades '
    . 'are delivered by installing a new plugin release instead.'
);

echo komari_field(
    'Disable remote control (Web SSH and command execution)',
    komari_select_bool('DISABLE_WEB_SSH', $cfg['DISABLE_WEB_SSH']),
    'Recommended: Yes. When this is No the panel can open a shell on this server '
    . 'and run commands as root, which means a compromised panel compromises the '
    . 'server. Only turn it off if you rely on that feature.'
);

echo komari_field(
    'Ignore unsafe certificates',
    komari_select_bool('IGNORE_UNSAFE_CERT', $cfg['IGNORE_UNSAFE_CERT']),
    'Turn this on only when the panel uses a self-signed certificate. It disables '
    . 'TLS certificate validation for the panel connection, which makes the traffic '
    . 'vulnerable to interception. A proper certificate is always preferable.'
);
?>

<table class="unraid tablesorter">
    <thead><tr><td>Statistics</td></tr></thead>
</table>

<?php
echo komari_field(
    'Monthly traffic reset day',
    komari_number_input('MONTH_ROTATE', $cfg['MONTH_ROTATE'], 0, 31) . ' (0 = disabled)',
    'The day of the month on which the agent starts a new traffic accounting '
    . 'period. Leave it at 0 to keep counting without a monthly reset. The traffic '
    . 'data is kept in net_static.json on the flash device, so it survives a reboot.'
);

echo komari_field(
    'Include cache and buffers in memory usage',
    komari_select_bool('MEMORY_INCLUDE_CACHE', $cfg['MEMORY_INCLUDE_CACHE']),
    'Recommended: Yes. Unraid uses free RAM as a disk cache, so the value without '
    . 'the cache looks alarming even when the server is healthy. Reporting the cache '
    . 'as used matches what the Unraid dashboard shows.'
);

echo komari_field(
    'Report raw used memory',
    komari_select_bool('MEMORY_REPORT_RAW_USED', $cfg['MEMORY_REPORT_RAW_USED']),
    'Uses total minus free minus buffers minus cached as the used value. Only turn '
    . 'this on when a panel graph has to match another monitoring tool exactly; it '
    . 'conflicts with the setting above.'
);
?>

<div class="advanced">
<table class="unraid tablesorter">
    <thead><tr><td>Advanced</td></tr></thead>
</table>

<?php
echo komari_field(
    'Enable detailed GPU monitoring',
    komari_select_bool('ENABLE_GPU', $cfg['ENABLE_GPU']),
    'Reports GPU utilisation and VRAM usage. This only produces data on a machine '
    . 'with a supported GPU and adds work to every collection cycle, so it is off by '
    . 'default.'
);

echo komari_field(
    'Include network interfaces',
    komari_text_input('INCLUDE_NICS', $cfg['INCLUDE_NICS'], 'wide', 'eth0,bond0'),
    'Comma separated list of interfaces to report. Wildcards are supported. Leave '
    . 'it empty to report every interface except the ones excluded below. On Unraid '
    . 'the interesting interfaces are usually br0 and bond0.'
);

echo komari_field(
    'Exclude network interfaces',
    komari_text_input('EXCLUDE_NICS', $cfg['EXCLUDE_NICS'], 'wide', 'veth*,docker*,virbr*'),
    'Comma separated list of interfaces to leave out. Container and VM bridges '
    . 'change constantly and make the panel graphs noisy, so excluding them is '
    . 'usually what you want. An include list takes precedence over this one.'
);

echo komari_field(
    'Include mount points',
    komari_text_input('INCLUDE_MOUNTPOINTS', $cfg['INCLUDE_MOUNTPOINTS'], 'wide', '/mnt/user;/mnt/cache'),
    'Semicolon separated list of mount points to report, because a mount point may '
    . 'contain a space. Leave it empty to report every mount point the agent finds. '
    . 'Note the separator: a semicolon here, a comma for the interface lists.'
);

echo komari_field(
    'Custom DNS server',
    komari_text_input('CUSTOM_DNS', $cfg['CUSTOM_DNS'], 'wide', '1.1.1.1'),
    'Resolve the panel address through this DNS server instead of the system '
    . 'resolver. Useful when the panel is behind a split-horizon DNS or when the '
    . 'Unraid resolver is unreliable. Leave it empty to use the system resolver.'
);

echo komari_field(
    'Preferred IP version',
    komari_select('PREFER_IP_VERSION', $cfg['PREFER_IP_VERSION'], $preferOptions),
    'Forces the agent to use IPv4 or IPv6 when it resolves the panel address. '
    . 'Automatic uses whatever the resolver returns first, which is right for most '
    . 'networks.'
);

echo komari_field(
    'Extra arguments',
    komari_text_input('EXTRA_ARGS', $cfg['EXTRA_ARGS'], 'wide', '--max-retries 5'),
    'Appended to the agent command line verbatim. This is for options the form does '
    . 'not expose; a mistake here stops the agent from starting, so check the log on '
    . 'the Status tab after changing it.'
);
?>
</div>

<table class="unraid tablesorter">
    <thead><tr><td>Save</td></tr></thead>
</table>

<dl>
    <dt><strong>Apply the settings</strong></dt>
    <dd>
        <span>
            <input type="submit" name="#apply" value="Apply">
            <input type="button" value="Done" onclick="done()">
        </span>
        <div class="hint">
            Apply writes the configuration file and restarts the agent, so the new
            values take effect immediately. The output of the restart is shown in the
            progress window.
        </div>
    </dd>
</dl>
</form>

<table class="unraid tablesorter">
    <thead><tr><td>Service control</td></tr></thead>
</table>

<dl>
    <dt><strong>Current state</strong></dt>
    <dd id="komari-settings-state">checking ...</dd>
</dl>

<dl>
    <dt><strong>Actions</strong></dt>
    <dd>
        <span>
            <input type="button" class="button" value="Start"
                   data-komari-action="start">
            <input type="button" class="button" value="Restart"
                   data-komari-action="restart">
            <input type="button" class="button" value="Stop"
                   data-komari-action="stop">
            <input type="button" class="button" value="Clear traffic counters"
                   data-komari-action="clear-traffic"
                   data-komari-confirm="1">
        </span>
        <div class="hint">
            These run the same scripts that the boot process uses. They work without
            saving the form first, so use Apply when you changed a setting and one of
            these when you only want to bounce the service.
        </div>
        <div class="hint">
            Clearing the traffic counters stops the agent, replaces the statistics
            file and starts the agent again, because the agent holds the counters in
            memory and would otherwise write them back. Reporting pauses for a few
            seconds.
        </div>
    </dd>
</dl>

<div id="komari-settings-result" style="margin-top:10px"></div>

<table class="unraid tablesorter">
    <thead><tr><td>Installation</td></tr></thead>
</table>

<table class="unraid">
    <?php
    echo komari_row('Plugin version', $info['plugin_version']);
    echo komari_row('Bundled komari-agent', $info['upstream_version'] . ' (' . $info['upstream_arch'] . ')');
    echo komari_row('Configuration file', KOMARI_CFG_FILE);
    echo komari_row('Agent binary', KOMARI_BINARY);
    echo komari_row('Agent log', KOMARI_LOG);
    ?>
</table>

<script type="text/javascript">
(function () {
    'use strict';

    var actionEndpoint = <?php echo json_encode($actionEndpoint); ?>;
    var form = document.getElementById('komari-settings-form');

    function showResult(text, hint, isError) {
        var box = document.getElementById('komari-settings-result');
        if (!box) {
            return;
        }
        box.textContent = '';
        var line = document.createElement('strong');
        line.textContent = text;
        if (isError) {
            line.className = 'error';
        }
        box.appendChild(line);
        if (hint) {
            var note = document.createElement('div');
            note.className = 'hint';
            note.textContent = hint;
            box.appendChild(note);
        }
    }

    function refreshState() {
        var box = document.getElementById('komari-settings-state');
        if (!box) {
            return;
        }
        $.post(actionEndpoint.replace(/Action\.php$/, 'Status.php'), {}, function (data) {
            if (!data || data.ok !== true || !data.service || !data.service.state) {
                box.textContent = 'unknown';
                return;
            }
            var state = data.service.state;
            box.textContent = state.charAt(0).toUpperCase() + state.slice(1);
        }, 'json').fail(function () {
            box.textContent = 'unknown';
        });
    }

    // The token is rendered into the form so it can be edited, which means it
    // is in the page source. Masking it keeps it off a screenshot or a
    // shoulder; the toggle is only for checking a pasted value.
    var toggle = document.getElementById('komari-token-toggle');
    if (toggle) {
        toggle.addEventListener('click', function () {
            var field = form ? form.elements['TOKEN'] : null;
            if (!field) {
                return;
            }
            if (field.type === 'password') {
                field.type = 'text';
                toggle.value = 'Hide';
            } else {
                field.type = 'password';
                toggle.value = 'Show';
            }
        });
    }

    // An agent without a panel address or a token never starts, and the start
    // script exits silently by design. Warning here is friendlier than letting
    // the user wonder why the status stays "stopped".
    //
    // /update.php writes each value as KEY="value" with no escaping at all, so
    // a double quote inside a value would terminate the string early and turn
    // the rest of the value into a second, broken line. That would corrupt the
    // whole configuration file, not just that one key, so it is rejected here
    // rather than discovered later on the Status tab.
    var confirmed = false;
    if (form) {
        form.addEventListener('submit', function (event) {
            if (confirmed) {
                return;
            }

            var offenders = [];
            var fields = form.elements;
            for (var i = 0; i < fields.length; i++) {
                var field = fields[i];
                if (!field.name || field.name.charAt(0) === '#') {
                    continue;
                }
                if (field.type !== 'text' && field.type !== 'password'
                    && field.type !== 'number' && field.type !== 'hidden') {
                    continue;
                }
                if (field.value && field.value.indexOf('"') !== -1) {
                    offenders.push(field.name);
                }
            }

            if (offenders.length > 0) {
                event.preventDefault();
                var quoteMessage = 'These fields contain a double quote, which '
                    + 'cannot be stored in the configuration file: '
                    + offenders.join(', ')
                    + '. Remove the quote and press Apply again.';
                if (typeof swal === 'function') {
                    swal({
                        title: 'Invalid character',
                        text: quoteMessage,
                        type: 'error',
                        confirmButtonText: 'OK'
                    });
                } else {
                    window.alert(quoteMessage);
                }
                return;
            }

            var enabled = form.elements['ENABLED'];
            var endpoint = form.elements['ENDPOINT'];
            var token = form.elements['TOKEN'];

            if (!enabled || enabled.value !== '1') {
                return;
            }
            if (endpoint && endpoint.value.trim() !== '' && token && token.value.trim() !== '') {
                return;
            }

            event.preventDefault();

            var warning = 'The agent is enabled but the panel address or the agent '
                + 'token is empty. It will not start until both are filled in. '
                + 'Save anyway?';

            if (typeof swal === 'function') {
                swal({
                    title: 'Incomplete configuration',
                    text: warning,
                    type: 'warning',
                    showCancelButton: true,
                    confirmButtonText: 'Save anyway',
                    cancelButtonText: 'Cancel'
                }, function (isConfirmed) {
                    if (isConfirmed) {
                        confirmed = true;
                        form.submit();
                    }
                });
            } else if (window.confirm(warning)) {
                confirmed = true;
                form.submit();
            }
        });
    }

    function runAction(action, button) {
        // The button is disabled for the duration of the request so that a
        // double click cannot start the same script twice. It has to come back
        // on both outcomes: an action that failed still leaves the user in
        // front of the page and expects to retry.
        button.disabled = true;
        showResult('Working ...', '', false);

        function done() {
            button.disabled = false;
        }

        $.post(actionEndpoint, {action: action}, function (data) {
            var message = (data && data.message) ? data.message : 'Done.';
            showResult(message, '', !(data && data.ok));
            window.setTimeout(refreshState, 2500);
        }, 'json').fail(function () {
            showResult('The action failed.', 'See the WebGUI log for details.', true);
        }).always(done);
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

        // Clearing the counters interrupts reporting for a few seconds, so it
        // asks first. The other actions are cheap and reversible.
        if (target.getAttribute('data-komari-confirm')) {
            var question = 'Clearing the traffic counters stops the agent, replaces '
                + 'the statistics file and starts the agent again. Reporting pauses '
                + 'for a few seconds. Continue?';

            if (typeof swal === 'function') {
                swal({
                    title: 'Clear traffic counters',
                    text: question,
                    type: 'warning',
                    showCancelButton: true,
                    confirmButtonText: 'Clear',
                    cancelButtonText: 'Cancel'
                }, function (isConfirmed) {
                    if (isConfirmed) {
                        runAction(action, target);
                    }
                });
            } else if (window.confirm(question)) {
                runAction(action, target);
            }
            return;
        }

        runAction(action, target);
    });

    // The advanced section follows the usual Dynamix advanced view switch.
    $(function () {
        refreshState();

        var stored = null;
        try {
            stored = window.localStorage
                ? window.localStorage.getItem('komari_agent_view_mode')
                : null;
        } catch (error) {
            stored = null;
        }

        if (stored === 'advanced') {
            $('.advanced').show();
        } else {
            $('.advanced').hide();
        }

        if ($.fn.switchButton) {
            $('.advancedview').switchButton({
                labels_placement: 'left',
                on_label: 'Advanced',
                off_label: 'Basic',
                checked: stored === 'advanced'
            });
        }

        $('.advancedview').on('change', function () {
            var isAdvanced = $(this).is(':checked');
            if (isAdvanced) {
                $('.advanced').show('slow');
            } else {
                $('.advanced').hide('slow');
            }
            try {
                if (window.localStorage) {
                    window.localStorage.setItem(
                        'komari_agent_view_mode',
                        isAdvanced ? 'advanced' : 'basic'
                    );
                }
            } catch (error) {
                // A browser that refuses local storage only loses the memory
                // of the switch, which is not worth an error message.
            }
        });
    });
})();
</script>
