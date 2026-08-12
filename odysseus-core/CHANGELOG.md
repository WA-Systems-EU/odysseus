# Changelog

All notable changes to odysseus-core are documented here.

Entries for 0.3.1 and earlier were reconstructed from git history and the built
gem artifacts, so they are summaries rather than contemporaneous notes.

## [Unreleased]

Deploy reliability. `lib/odysseus/core/version.rb` currently reads 0.3.2, but
these change observable behaviour — `SSH#execute` and the Caddy client now raise
where they used to stay quiet — so a minor bump is the more honest release.

### Fixed
- `Deployer::SSH#execute` reads the channel's exit status and raises
  `SSHCommandError` on a non-zero exit. Previously every remote command appeared
  to succeed, so a failed `docker stop`, `docker rm`, `mkdir` or network create
  was invisible.
- `Deployer::SSH#execute` no longer merges stderr into its return value, so
  callers parsing stdout are not handed warning text. This also repairs
  `Docker::Client#health_status` for containers with no Health block.
- `Caddy::Client` raises `ProxyApiError` when a mutating admin API request
  fails. `curl` exits 0 for HTTP errors, so a rejected route write was parsed as
  an ordinary response and discarded — the deploy reported success while no
  traffic was routed. Reads still return nil, as Caddy answers 500 for config
  paths that do not exist yet.
- `Orchestrator::WebDeploy` aborts when Caddy fails to start. The result of
  `ensure_running` was discarded and the guard clause that raises had become
  dead code.
- A web container is always given a health command, defaulting to `GET /` on
  `proxy.app_port`. Without a `healthcheck` block — the shape both READMEs
  show — the container had no health command, its status stayed `none`, and every
  deploy timed out after 60s and rolled back. A web role with no `app_port` now
  fails fast with a config error.
- `Docker::Client#wait_healthy` honours the timeout it is passed instead of
  capping every wait at 60s, so the 120s requested by `JobDeploy` and
  `AccessoryDeploy` is respected.
- `Caddy::Client#add_upstream` reconciles a route's Host matcher, so editing
  `proxy.hosts` takes effect instead of requiring the route to be removed by
  hand.

### Changed
- Container environment is passed through a `0600` env file under
  `/var/lib/odysseus/env` and `--env-file`, instead of `-e KEY=VALUE` on the
  command line. Secrets no longer appear in the host's process list, and values
  containing spaces or shell metacharacters survive intact. A value containing a
  newline is rejected rather than silently truncated.
- Licensed under MIT. The gemspec and LICENSE previously said LGPL-3.0-only
  while the READMEs said MIT.

### Removed
- The unused `Odysseus::VERSION` constant, stale at 0.1.0.
  `Odysseus::Core::VERSION` is the single source of truth.

## [0.3.1] - 2026-04-05

### Fixed
- Ruby 4.0 compatibility: declare the `logger` dependency explicitly.

### Removed
- The AWS Auto Scaling Group host provider, extracted to
  `odysseus-sail-aws-asg`. `HostProviders` keeps the registry and the `aws:`
  config hook the sail consumes.

## [0.3.0] - 2026-03-30

### Added
- `Sails` plugin registry, with the rolling deploy strategy extracted to
  `odysseus-sail-rolling`. `servers.<role>.deploy.strategy` resolves through it.
- Volume namespacing: named volumes are prefixed with the service name so
  containers sharing a host no longer collide, reusing an existing
  un-namespaced volume rather than losing data.
- `Docker::Client#ensure_network`, so accessories can boot before any service
  deploy has created the network.
- Parsing for `servers.<role>.containers` and `servers.<role>.deploy`, including
  timeouts and an HTTP health check with a success threshold.

## [0.2.0] - 2025-12-30

### Added
- Encrypted secrets files (AES-256-GCM) with `Secrets::EncryptedFile` and
  `Secrets::Loader`.
- Builder with local and remote (build host) strategies, plus pussh
  distribution over SSH for registry-less deploys.
- Host provider registry behind `HostProviders`, with the static provider as
  the default.
- CPU and memory limits for containers.

## [0.1.0] - 2025-12-19

- Initial release: config parsing, SSH and Docker clients, Caddy proxy
  integration with automatic TLS, web and job orchestrators, and the accessory
  lifecycle.
