# Documentation

Deep-dive documents for `unraid-plugin-komari-agent`.

These documents are written in Chinese. Code, scripts, the WebGUI page text and
the top-level README are in English.

| Document | Contents |
|---|---|
| [01-design-decisions.md](01-design-decisions.md) | Why the official GitHub Release asset is used instead of a source build: measured comparison, weighted decision matrix, residual risks and mitigations |
| [02-technical-design.md](02-technical-design.md) | Unraid plugin mechanics, the daemon process model, why a supervisor loop replaces systemd, install/uninstall flow, why the working directory has to be the flash directory, reproducible packaging, the WebGUI data endpoints |
| [03-verification-log.md](03-verification-log.md) | What was verified on the build machine and how, the two packaging defects that were found and fixed there, and the explicit list of what can only be verified on a real Unraid host — with the commands to run |
| [05-unraid-plugin-conventions.md](05-unraid-plugin-conventions.md) | Rule by rule mapping of the official Unraid plugin rules onto this plugin: hard requirements, best practices, daemon specific pitfalls, the design trade-offs this project settled on, and the points that still need verification on a real host |

The numbering leaves a gap on purpose: `04` is reserved for a roadmap, which
will be written once the plugin has been exercised on a real Unraid host and
the milestone plan can be based on measurements instead of estimates.

## Reading order

If you are evaluating whether to trust this plugin:

1. `01-design-decisions.md` — where the binary comes from and why
2. `03-verification-log.md` — what has actually been checked, and what has not
3. `05-unraid-plugin-conventions.md` — which official rules the packaging has to
   satisfy, and which of them are still unverified

If you are modifying the packaging:

1. `02-technical-design.md` — how the `.plg`, the rc script and the supervisor
   fit together
2. `03-verification-log.md` — the checks that must stay green, and the build
   machine quirks that make them look green when they are not
3. `05-unraid-plugin-conventions.md` — the rules the packaging must not break,
   and the daemon specific pitfalls that are easy to reintroduce

## Related top-level documents

- [`../README.md`](../README.md) — project overview (English)
- [`../README.zh-CN.md`](../README.zh-CN.md) — project overview (Chinese)
- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) — development setup, the check
  matrix (which command covers what, and which need the network or a build), and
  the PR checklist
- [`../SECURITY.md`](../SECURITY.md) — reporting vulnerabilities, security defaults
- [`../CHANGELOG.md`](../CHANGELOG.md) — release history

## Checks, and where their logic lives

The workflows contain no logic. Every step calls a script, so the same
commands run on a contributor's machine and on a runner:

| Script | Workflow that calls it |
|---|---|
| [`../scripts/lint-repo.sh`](../scripts/lint-repo.sh) | `build.yml` (verify job) |
| [`../scripts/check-php-syntax.py`](../scripts/check-php-syntax.py) | `build.yml` (verify job) |
| [`../scripts/build-plugin.sh`](../scripts/build-plugin.sh) | `build.yml` (verify job) |
| [`../scripts/lint-plg.sh`](../scripts/lint-plg.sh) | `build.yml` (verify job) |
| [`../scripts/verify-release.sh`](../scripts/verify-release.sh) | `build.yml` (verify job) |
| [`../scripts/smoke-test.sh`](../scripts/smoke-test.sh) | `build.yml` (verify job) |
| [`../scripts/check-upstream.sh`](../scripts/check-upstream.sh) | `upstream-check.yml` |
| [`../scripts/update-upstream.sh`](../scripts/update-upstream.sh) | maintainer tool, not run in CI |
