## What changed

<!-- Describe the change and why it is needed. -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Documentation
- [ ] Build / CI
- [ ] Upstream version bump

## Checklist

- [ ] `./scripts/build-plugin.sh` succeeds
- [ ] `./scripts/lint-plg.sh` passes
- [ ] `./scripts/check-php-syntax.py src/` passes
- [ ] `./scripts/verify-release.sh` passes
- [ ] The build is still reproducible (same txz SHA256 on a second run)
- [ ] `CHANGELOG.md` updated (for user-visible changes)
- [ ] Comments, log messages and user-facing output are in English
- [ ] No hostnames, IP addresses or personal paths were introduced
- [ ] No agent token, real or sample, was added to any file

## Plugin script rules

These are enforced by `lint-plg.sh` and `verify-release.sh`, but check them by
hand as well — a non-zero exit aborts the install on the user's host:

- [ ] The install script is idempotent (it runs again on every boot)
- [ ] The install script never exits non-zero
- [ ] No plugin script enables `set -e` or `set -u`
- [ ] The remove script keeps the configuration file and the traffic counters
- [ ] The agent token is passed through the environment, never on a command line

## Upstream version bump

If this PR bumps the bundled `komari-agent` version:

- Previous version:
- New version:
- `plugin/upstream.lock` refreshed with `./scripts/update-upstream.sh`: <!-- yes/no -->
- The `Makefile` pin, the `scripts/build-plugin.sh` default and the lock file all agree: <!-- yes/no -->
- Upstream changelog reviewed for added or renamed `AGENT_*` variables: <!-- yes/no -->

If the upstream release added or renamed an `AGENT_*` variable, the Settings page
and the configuration table in `README.md` have to be updated together:

- [ ] `src/.../include/Pages/Settings.php` maps the variable
- [ ] The configuration table in `README.md` and `README.zh-CN.md` lists it
