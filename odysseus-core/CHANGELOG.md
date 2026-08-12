# Changelog

All notable changes to odysseus-core are documented here.

Entries for 0.3.1 and earlier were reconstructed from git history and the built
gem artifacts, so they are summaries rather than contemporaneous notes.

## [Unreleased]

### Added
- The image tag now defaults to the git commit being deployed, and containers
  carry `odysseus.version`, `odysseus.deployed_at` and `odysseus.git_ref` labels,
  so a running container can be traced to a commit. `odysseus.version` previously
  held the deploy timestamp, which `odysseus.deployed_at` now carries.
- Each host records successful deploys in `/var/lib/odysseus/<service>/deploys.log`.

### Changed
- `deploy`, `build` and `pussh` no longer default to the `latest` tag. Outside
  a git repository, or with uncommitted changes, they stop and ask for
  `--image`. The version resolves before the dry-run check, so `--dry-run`
  also requires a resolvable version even though it makes no changes.

## [0.4.1] - 2026-08-12

### Fixed
- `Caddy::Client#enable_tls_for_hosts` updates an existing `tls` app in place
  instead of trying to recreate it. Caddy's `PUT` creates and answers 409 if the
  key is already there, so on any host whose Caddy already had a `tls` app this
  call had always failed and the policy update had always been discarded — a
  domain added to `proxy.hosts` after the first deploy never got a policy and so
  never got an ACME account email. Certificates still arrived through Caddy's
  implicit automation, which is why it went unnoticed. 0.4.0 did not break this;
  it stopped hiding it.
- The new policy is merged onto the existing `tls` config rather than replacing
  it, so sibling settings — explicit certificate loaders, `on_demand` limits —
  survive a deploy.

## [0.4.0] - 2026-08-12

Deploy reliability. `SSH#execute` and the Caddy client now raise where they used
to stay quiet, so this is a minor bump rather than a patch: a deploy that
previously reported success while failing will now stop and say so.

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

### Internal
- `validators/config.rb` and `sails.rb` are covered by specs for the first time.
- `rake` runs RSpec and RuboCop clean. Remaining Metrics offences are recorded
  in `.rubocop_todo.yml` rather than hidden in the main configuration.

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
