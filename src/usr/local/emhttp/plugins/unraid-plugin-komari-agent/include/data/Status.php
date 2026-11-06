<?php
/**
 * Status data endpoint of the unraid-plugin-komari-agent WebGUI.
 *
 * Copyright (C) 2026 zhz8888
 * SPDX-License-Identifier: MIT
 *
 * The status tab renders its static part from include/Pages/Status.php and
 * fetches everything that can be slow or can change here.
 *
 * Two sources are combined, and the split is deliberate:
 *
 *   scripts/status.sh     owns the service, config, binary and log facts. It
 *                         is the same code the boot process and the command
 *                         line use, so the page cannot drift away from what
 *                         the system actually thinks. Reimplementing its
 *                         checks in PHP would create a second source of truth
 *                         for "is the agent running".
 *   this file             decodes net_static.json. That file is a JSON
 *                         document, and status.sh documents that it is left
 *                         to the PHP endpoint because a hand written JSON
 *                         parser in awk would be slower and easier to get
 *                         wrong than the decoder PHP already ships with.
 *
 * The panel reachability probe is added here as well: it is a network
 * operation with its own timeout, and it has no place in a script that the
 * boot process calls.
 *
 * The token is never part of the response. Only whether one is set is
 * reported, so a polled endpoint cannot leak the credential into the browser
 * cache, the page source or a screenshot.
 */

require_once dirname(__DIR__) . '/common.php';

komari_json_begin();

/**
 * Run scripts/status.sh and return its decoded document.
 *
 * @return array{ok:bool,data:array<string,mixed>|null,error:string|null}
 */
function komari_status_snapshot()
{
    $path = komari_script_path('status.sh');
    if ($path === null) {
        return array(
            'ok' => false,
            'data' => null,
            'error' => 'scripts/status.sh is missing from the installation',
        );
    }

    $result = komari_exec(escapeshellarg($path) . ' 2>/dev/null', 10);
    if ($result['timedout']) {
        return array(
            'ok' => false,
            'data' => null,
            'error' => 'scripts/status.sh did not finish within 10 seconds',
        );
    }

    $raw = trim($result['stdout']);
    if ($raw === '') {
        return array(
            'ok' => false,
            'data' => null,
            'error' => 'scripts/status.sh produced no output',
        );
    }

    $data = json_decode($raw, true);
    if (!is_array($data)) {
        return array(
            'ok' => false,
            'data' => null,
            'error' => 'scripts/status.sh produced output that is not valid JSON',
        );
    }

    return array('ok' => true, 'data' => $data, 'error' => null);
}

/**
 * Translate the status.sh document into the shape the page renders.
 *
 * Keeping the translation in one place means the page only ever deals with the
 * compact shape, and a change to the script's schema is absorbed here.
 *
 * @param array<string,mixed> $snapshot
 *
 * @return array<string,mixed>
 */
function komari_status_view(array $snapshot)
{
    $plugin = isset($snapshot['plugin']) && is_array($snapshot['plugin'])
        ? $snapshot['plugin']
        : array();
    $config = isset($snapshot['config']) && is_array($snapshot['config'])
        ? $snapshot['config']
        : array();
    $binary = isset($snapshot['binary']) && is_array($snapshot['binary'])
        ? $snapshot['binary']
        : array();
    $service = isset($snapshot['service']) && is_array($snapshot['service'])
        ? $snapshot['service']
        : array();
    $log = isset($snapshot['log']) && is_array($snapshot['log'])
        ? $snapshot['log']
        : array();
    $traffic = isset($snapshot['traffic']) && is_array($snapshot['traffic'])
        ? $snapshot['traffic']
        : array();

    // The script reports running/supervised as two booleans. The page shows a
    // single state, because "supervised but not running" is the case a user
    // has to act on and deserves its own word rather than a combination of
    // two flags they have to interpret.
    $running = !empty($service['running']);
    $supervised = !empty($service['supervised']);
    if ($running) {
        $state = 'running';
    } elseif ($supervised) {
        $state = 'degraded';
    } else {
        $state = 'stopped';
    }

    $agentPids = array();
    if (isset($service['agent_pids']) && is_array($service['agent_pids'])) {
        foreach ($service['agent_pids'] as $pid) {
            $pid = (int) $pid;
            if ($pid > 0) {
                $agentPids[] = $pid;
            }
        }
    }

    $supervisorPid = isset($service['supervisor_pid']) ? (int) $service['supervisor_pid'] : 0;
    $agentPid = isset($service['agent_pid']) ? (int) $service['agent_pid'] : 0;

    $uptime = 0;
    if ($running && isset($service['agent_uptime'])) {
        $uptime = (int) $service['agent_uptime'];
    } elseif ($supervised && isset($service['supervisor_uptime'])) {
        $uptime = (int) $service['supervisor_uptime'];
    }

    $binarySize = isset($binary['size']) ? (int) $binary['size'] : 0;
    $binaryInstalled = !empty($binary['installed']);
    $sha256Checked = !empty($binary['sha256_checked']);
    $sha256Ok = !empty($binary['sha256_ok']);

    // "could not be checked" and "does not match" are different statements: a
    // mismatch is a security finding, an unchecked file is only an unknown.
    if (!$binaryInstalled) {
        $pinState = 'not installed';
    } elseif (!$sha256Checked) {
        $pinState = 'could not be verified';
    } elseif ($sha256Ok) {
        $pinState = 'yes';
    } else {
        $pinState = 'no - the installed file is not the pinned release';
    }

    $logLines = array();
    if (isset($log['lines']) && is_array($log['lines'])) {
        foreach ($log['lines'] as $line) {
            $line = (string) $line;
            // status.sh emits one empty element when the log is absent or
            // empty, because it splits on a trailing newline. Passing that
            // through would make an empty log look like a one line log.
            if ($line !== '') {
                $logLines[] = $line;
            }
        }
    }

    $logSize = isset($log['size']) ? (int) $log['size'] : 0;

    return array(
        'state' => $state,
        'plugin' => array(
            'name' => isset($plugin['name']) ? (string) $plugin['name'] : KOMARI_PLUGIN_NAME,
            'version' => isset($plugin['version']) ? (string) $plugin['version'] : '',
            'upstream_version' => isset($plugin['upstream_version'])
                ? (string) $plugin['upstream_version']
                : '',
        ),
        'config' => array(
            'file' => isset($config['file']) ? (string) $config['file'] : KOMARI_CFG_FILE,
            'exists' => !empty($config['exists']),
            'enabled' => !empty($config['enabled']),
            'configured' => !empty($config['configured']),
            'endpoint' => isset($config['endpoint']) ? (string) $config['endpoint'] : '',
            'token_set' => !empty($config['token_set']),
            'interval' => isset($config['interval']) ? (string) $config['interval'] : '3',
            'disable_auto_update' => !empty($config['disable_auto_update']),
            'disable_web_ssh' => !empty($config['disable_web_ssh']),
        ),
        'service' => array(
            'state' => $state,
            'running' => $running,
            'supervised' => $supervised,
            'supervisor_pid' => $supervisorPid > 0 ? $supervisorPid : null,
            'agent_pid' => $agentPid > 0 ? $agentPid : null,
            'agent_pids' => $agentPids,
            'uptime' => $uptime > 0 ? $uptime : null,
            'uptime_human' => komari_format_duration($uptime > 0 ? $uptime : null),
            'pidfile' => isset($service['pidfile']) ? (string) $service['pidfile'] : KOMARI_PIDFILE,
            'pidfile_present' => !empty($service['pidfile_present']),
            'log_path' => isset($log['path']) ? (string) $log['path'] : KOMARI_LOG,
            'rc_script' => KOMARI_RC_SCRIPT,
        ),
        'binary' => array(
            'path' => isset($binary['path']) ? (string) $binary['path'] : KOMARI_BINARY,
            // status.sh reports "installed" as "exists and is executable", so
            // there is no separate executable flag to carry here. Copying it
            // would assert the same fact twice and hide a lost execute bit.
            'installed' => $binaryInstalled,
            'size' => $binarySize,
            'size_human' => komari_format_bytes($binarySize),
            'pin_state' => $pinState,
            'matches_pin' => $sha256Checked ? $sha256Ok : null,
            'cache_path' => isset($binary['cache_path'])
                ? (string) $binary['cache_path']
                : KOMARI_BIN_CACHE,
            'cache_present' => !empty($binary['cache_present']),
        ),
        'log' => array(
            'path' => isset($log['path']) ? (string) $log['path'] : KOMARI_LOG,
            'lines' => $logLines,
            'size' => $logSize,
            'size_human' => komari_format_bytes($logSize),
            'error' => empty($logLines)
                ? (!empty($log['present']) ? 'the log is empty' : 'the log file does not exist yet')
                : null,
        ),
        'traffic_meta' => array(
            'file' => isset($traffic['file']) ? (string) $traffic['file'] : KOMARI_NET_STATIC,
            'present' => !empty($traffic['present']),
            'size' => isset($traffic['size']) ? (int) $traffic['size'] : 0,
        ),
    );
}

try {
    $snapshot = komari_status_snapshot();

    if (!$snapshot['ok']) {
        // The script is the authority on the service state. When it cannot be
        // run at all the page still renders and says so, rather than showing a
        // confident "stopped" that would be a guess.
        komari_json_out(array(
            'ok' => false,
            'error' => $snapshot['error'],
            'generated_at' => time(),
            'generated_at_human' => date('Y-m-d H:i:s'),
        ));

        return;
    }

    $view = komari_status_view($snapshot['data']);

    // The traffic counters are decoded here, see the file comment.
    $traffic = komari_traffic_summary();
    $traffic['file'] = $view['traffic_meta']['file'];
    $traffic['present'] = $view['traffic_meta']['present'];

    $panel = komari_panel_probe($view['config']['endpoint'], 3, 10);

    komari_json_out(array(
        'ok' => true,
        'generated_at' => isset($snapshot['data']['generated_at'])
            ? (int) $snapshot['data']['generated_at']
            : time(),
        'generated_at_human' => date('Y-m-d H:i:s'),
        'plugin' => $view['plugin'],
        'service' => $view['service'],
        'binary' => $view['binary'],
        'config' => $view['config'],
        'panel' => $panel,
        'traffic' => $traffic,
        'log' => $view['log'],
    ));
} catch (Throwable $error) {
    komari_log_exception($error);
    komari_json_out(array(
        'ok' => false,
        'error' => 'the status could not be collected',
        'detail' => $error->getMessage(),
    ));
}
