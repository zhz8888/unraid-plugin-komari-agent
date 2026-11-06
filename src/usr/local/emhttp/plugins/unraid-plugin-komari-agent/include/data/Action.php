<?php
/**
 * Action endpoint of the unraid-plugin-komari-agent WebGUI.
 *
 * Copyright (C) 2026 zhz8888
 * SPDX-License-Identifier: MIT
 *
 * The endpoint only accepts a fixed set of action names. The command that
 * belongs to an action is defined here and never taken from the request, so no
 * request value ever reaches the shell. That is the whole security model of
 * this file: there is no shell string interpolation of user input anywhere,
 * which is why it is safe to hand these commands to a shell at all.
 *
 * Every action is started in the background. `restart.sh` waits for the old
 * agent to flush its traffic counters and may take up to ten seconds before it
 * escalates to SIGKILL, which is long enough to exceed the FastCGI request
 * timeout and leave the browser with an empty response.
 */

require_once dirname(__DIR__) . '/common.php';

komari_json_begin();

/**
 * Whether a service script is present and executable.
 *
 * @param string $name
 *
 * @return bool
 */
function komari_action_script_ready($name)
{
    $path = komari_script_path($name);

    return $path !== null && @is_executable($path);
}

/**
 * Start a command in the background and detach it from this request.
 *
 * The command is a fixed string that was built in this file, so it is never
 * passed through escapeshellarg: it contains no user supplied part at all. The
 * output goes to the agent log, which is where a user looks anyway.
 *
 * @param string $command a fixed command, never built from request data
 *
 * @return bool whether the detached shell was started
 */
function komari_action_spawn($command)
{
    $full = 'nohup /bin/bash ' . $command
        . ' >>' . escapeshellarg(KOMARI_LOG) . ' 2>&1 &';

    $output = array();
    $code = 1;
    @exec($full, $output, $code);

    return $code === 0;
}

/**
 * Build the fixed command for one action name.
 *
 * The returned string always ends with the script path only, so the caller can
 * append a fixed argument without ever mixing in request data.
 *
 * @param string $script
 *
 * @return string
 */
function komari_action_command($script)
{
    return escapeshellarg(KOMARI_SCRIPTS . '/' . $script);
}

$ok = false;
$message = 'Unknown action.';
$script = null;

try {
    if (!komari_request_is_same_origin()) {
        @http_response_code(403);
        $message = 'The request did not come from the Unraid WebGUI.';
    } elseif (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
        @http_response_code(405);
        $message = 'Only POST is supported.';
    } else {
        $action = isset($_POST['action']) && is_string($_POST['action']) ? $_POST['action'] : '';

        // Each entry names the script to run and the text to show. Nothing is
        // interpolated into a command line from the request.
        $actions = array(
            'start' => array(
                'script' => 'start.sh',
                'message' => 'The agent is being started in the background. '
                    . 'Reload the page in a moment to see the new state.',
            ),
            'stop' => array(
                'script' => 'stop.sh',
                'message' => 'The agent is being stopped in the background. '
                    . 'It flushes its traffic counters before it exits.',
            ),
            'restart' => array(
                'script' => 'restart.sh',
                'message' => 'The agent is being restarted in the background. '
                    . 'The old process gets up to ten seconds to shut down cleanly.',
            ),
            'clear-traffic' => array(
                'script' => 'clear-traffic.sh',
                'message' => 'The traffic counters are being cleared in the background. '
                    . 'Because the agent holds them in memory and rewrites the file '
                    . 'every ten minutes, the counters can only be reset while it is '
                    . 'stopped: the agent is stopped, the file is replaced and the '
                    . 'agent is started again. Reporting pauses for a few seconds.',
            ),
        );

        if (!isset($actions[$action])) {
            $message = 'Unknown action.';
        } else {
            $script = $actions[$action]['script'];
            $path = komari_script_path($script);

            if ($path === null) {
                $message = 'The service script ' . $script . ' is missing from the '
                    . 'plugin installation. Reinstall the plugin.';
            } elseif (!komari_action_script_ready($script)) {
                $message = 'The service script ' . $script . ' is not executable. '
                    . 'Reinstall the plugin.';
            } else {
                komari_syslog('action ' . $action . ' requested from the WebGUI');
                if (komari_action_spawn(komari_action_command($script))) {
                    $ok = true;
                    $message = $actions[$action]['message'];
                } else {
                    $message = 'The action could not be started. See '
                        . KOMARI_LOG . ' for details.';
                }
            }
        }
    }
} catch (Throwable $error) {
    komari_log_exception($error);
    $ok = false;
    $message = 'The action failed unexpectedly. Details were written to '
        . KOMARI_PAGE_ERROR_LOG . '.';
}

komari_json_out(array(
    'ok' => $ok,
    'action' => isset($_POST['action']) && is_string($_POST['action']) ? $_POST['action'] : '',
    'script' => $script,
    'message' => $message,
));
