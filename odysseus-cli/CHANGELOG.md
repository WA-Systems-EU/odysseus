# Changelog

All notable changes to odysseus-cli are documented here.

Entries for 0.3.0 and earlier were reconstructed from git history and the built
gem artifacts, so they are summaries rather than contemporaneous notes.

## [Unreleased]

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
