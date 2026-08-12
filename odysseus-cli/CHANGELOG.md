# Changelog

All notable changes to odysseus-cli are documented here.

Entries for 0.3.0 and earlier were reconstructed from git history and the built
gem artifacts, so they are summaries rather than contemporaneous notes.

## [Unreleased]

### Added
- `Odysseus::CLI::VERSION`, so the gem version has one source of truth instead
  of being hardcoded in the gemspec.

### Changed
- Requires odysseus-core `~> 0.3, >= 0.3.2`. The dependency was `~> 0.2`, which
  allowed installing a core old enough to lack the deploy fixes the CLI relies
  on.
- Requires Ruby >= 3.2.0, matching odysseus-core. The gemspec asked for >= 3.0,
  which could not have worked.
- Licensed under MIT. The gemspec previously said LGPL-3.0-only while the README
  said MIT.

### Fixed
- The gem now ships its license file. `spec.files` looked for `LICENSE` while
  the file is `LICENSE.txt`, so published gems contained no license text.

### Removed
- The `ratatui_ruby` dependency. Nothing in the CLI required or referenced it —
  it pulled a native extension into every install for nothing.
- Documentation for Charm mode (`--charm`, `ODYSSEUS_CHARM=1`, `gum`), removed
  from the code in 0.3.0 but left in the README, and for AWS Auto Scaling Group
  hosts, which moved to a sail gem nothing currently loads.

## [0.3.0] - 2026-04-04

### Changed
- Rewrote terminal output as numbered steps with animated spinners resolving to
  ✓/✗, rendered by `CLI::UI`, replacing the gum-backed Charm mode. `--debug`
  (or `ODYSSEUS_DEBUG=1`) switches to verbose plain text.
- Secret values are redacted from streamed output via `RedactingIO`.

## [0.2.0] - 2025-12-30

### Added
- Charm TUI mode (`--charm`, `ODYSSEUS_CHARM=1`) built on gum, for styled
  headers, spinners, tables and confirmations. Superseded in 0.3.0.
- `secrets` subcommands: generate-key, encrypt, decrypt, edit.
- `accessory` subcommands: boot, boot-all, remove, restart, upgrade, status,
  logs, exec, shell.
- `pussh` command for pushing images to hosts over SSH without a registry.

## [0.1.0] - 2025-12-21

- Initial release: deploy, build, status, containers, logs, cleanup, validate,
  and the `app` subcommands.
