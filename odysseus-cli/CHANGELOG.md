# Changelog

All notable changes to odysseus-cli are documented here.

Entries for 0.3.0 and earlier were reconstructed from git history and the built
gem artifacts, so they are summaries rather than contemporaneous notes.

## [Unreleased]

## [0.5.0] - 2026-08-13

### Changed
- Requires odysseus-core `~> 0.5.0`. The previous `~> 0.4.4` constraint
  excludes 0.5.0 outright, so this is not a tightening but a necessary move:
  without it the two gems cannot resolve together at all.
- `odysseus deploy` now prunes old images on each host, keeping the newest
  `retain_versions` (default 5). See odysseus-core's changelog for what is
  protected from removal.

## [0.4.4] - 2026-08-13

### Changed
- Requires odysseus-core `~> 0.4.4`. The dependency was `~> 0.4.3`, which
  allowed installing a core whose `Executor` still named its six methods
  `deploy_accessory`, `boot_accessories` and so on — all of which the dependency
  commands call under their new names, so they would have failed with a
  NoMethodError rather than a resolvable error.
- `odysseus accessory` is now `odysseus dependency`, with `dep` accepted as
  shorthand. The old verb still works and prints a notice naming the
  replacement, because a silent alias never gets migrated away from; it will be
  removed in a later release. The `accessories:` key in deploy.yml is likewise
  now `dependencies:`, with the old key still accepted — see odysseus-core's
  changelog for why nothing on a host changes when you rename it.
- Help text, subcommand output and the `Dependency name required` error read
  "dependency" throughout.

## [0.4.3] - 2026-08-13

### Added
- `odysseus rollback [VERSION]`, returning every role on every host to a
  previously deployed version. With no VERSION, the target is the most recent
  version in the hosts' deploy logs that is not already serving and whose image
  is still present everywhere. Refuses, changing nothing, when any host lacks
  the image.
- `odysseus rollback --list`, showing per host: every version deployed, when,
  by whom, from which commit, whether the image is still present, and what is
  serving. Reads only the hosts, so it works without a git repository.

### Changed
- Requires odysseus-core `~> 0.4.3`. The dependency was `~> 0.4.2`, which
  allowed installing a core without `Executor#rollback_plan`, `#rollback_all`
  or `#version_survey` — all of which `rollback` calls, so the command would
  have failed with a NoMethodError rather than a resolvable error.

### Fixed
- `odysseus accessory status` now works. It has raised `NoMethodError` since
  before the subcommand shipped in 0.2.0; see odysseus-core's changelog for the
  root cause and fix.

### Internal
- Rollback commands moved out of the main `CLI` class into
  `Odysseus::CLI::RollbackCommands`, to keep the class under its existing size
  limit without changing its public API.

## [0.4.2] - 2026-08-13

### Changed
- `deploy`, `build` and `pussh` no longer default `--image` to the `latest`
  tag; the tag now defaults to the git commit being deployed, and is required
  outside a clean git repository.
- `status` reports the version, ref and deploy time of each container.
- `app exec`, `app shell` and `app console` run the version that is currently
  serving instead of `:latest`.
- Requires odysseus-core `~> 0.4.2`. The dependency was `~> 0.4`, which allowed
  installing a core without `Executor#deploy_version` or `Docker::Labels` — both
  of which these commands now call, so `deploy` would have failed with a
  NoMethodError rather than a resolvable error.

## [0.4.1] - 2026-08-12

Released in lockstep with odysseus-core 0.4.1, which fixes the Caddy TLS
policy update. No changes to the CLI itself.

## [0.4.0] - 2026-08-12

### Added
- `odysseus version` and `--version`, reporting the CLI, odysseus-core and ruby
  versions. Answered before any config is loaded, so it works without a
  deploy.yml or a reachable server.
- `Odysseus::CLI::VERSION`, so the gem version has one source of truth instead
  of being hardcoded in the gemspec.
- A test suite: RSpec, `.rspec` and a `rake` default task. Argument dispatch and
  exit codes are covered by running the real executable in a subprocess, the
  commands are unit-tested against a doubled executor, and the redaction of
  secrets from streamed output is pinned.
- RuboCop, sharing odysseus-core's configuration.

### Changed
- Requires odysseus-core `~> 0.4`. The dependency was `~> 0.2`, which allowed
  installing a core old enough to lack the deploy fixes the CLI relies on.
- Requires Ruby >= 3.2.0, matching odysseus-core. The gemspec asked for >= 3.0,
  which could not have worked.
- Licensed under MIT. The gemspec previously said LGPL-3.0-only while the README
  said MIT.
- `CLEAN_MESSAGES` is a `private_constant`; it sat after a `private` modifier,
  which does nothing for constants.
- Development dependencies live in the Gemfile only, as in odysseus-core; the
  gemspec declared rspec and pry-byebug a second time.

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
