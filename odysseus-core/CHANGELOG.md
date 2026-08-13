# Changelog

All notable changes to odysseus-core are documented here.

Entries for 0.3.1 and earlier were reconstructed from git history and the built
gem artifacts, so they are summaries rather than contemporaneous notes.

## [Unreleased]

### Added
- `retain_versions` in deploy.yml, default 5: how many distinct versions of a
  service's image each host keeps. After a successful deploy, images beyond
  that window are removed from the host. Until now SHA-tagged images
  accumulated without limit — `cleanup --prune-images` only removes *dangling*
  images, and a tagged image is never dangling.
- `RetentionPlanner`, `Docker::Client#remove_image` and
  `Docker::Client#versions_in_use`.

### Changed
- `deploy` prunes old images on each host once all of that host's roles are
  deployed. `rollback` deliberately does not: deleting images during a
  recovery is the wrong moment, and the version just rolled back from is the
  most likely next thing wanted.

  Three independent things must agree before an image is deleted: it must
  fall outside the retain window, no container on the host may reference it
  (stopped containers included, since cleanup keeps two per service), and
  docker must accept the removal. Each removal is attempted on its own, so one
  refusal is a logged skip rather than a failed deploy. A host with no
  `deploys.log` is skipped entirely rather than pruned by image creation time,
  which is build time and can be out of order. `latest` is never removed
  automatically.

## [0.4.4] - 2026-08-13

A rename, with the old names still working. Nothing on a host changes.

### Changed
- `accessories:` in deploy.yml is now `dependencies:`. The old name implied
  optional extras, when a database the app cannot boot without is not optional.
  The old key is still accepted and parses identically, so existing deploy.yml
  files keep working; it will be removed in a later release.
- Nothing on a host changes as a result. Container names and the
  `odysseus.service` label are built from the service name plus the individual
  dependency's name, so the top-level key never reaches a host and running
  containers are adopted rather than orphaned. A spec runs the real parser over
  a legacy fixture and asserts the resulting container name, so this cannot
  regress silently.
- `Orchestrator::AccessoryDeploy` is `Orchestrator::DependencyDeploy`,
  `Deployer::AccessoryManager` is `Deployer::DependencyManager`, and
  `Executor`'s six accessory methods are now `deploy_dependency`,
  `remove_dependency`, `restart_dependency`, `upgrade_dependency`,
  `dependency_status` and `boot_dependencies`. No deprecated aliases: nothing
  outside odysseus-cli consumes these, and the two gems ship in lockstep.
- The config error messages changed accordingly: `Dependency 'x' not found in
  config` and `No hosts configured for dependency x`.

### Internal
- `Config::Parser#parse_accessories` and its two helpers are now
  `parse_dependencies`, `parse_dependency_healthcheck` and
  `parse_dependency_proxy`. The parser gained its first coverage for this block
  in the process.

## [0.4.3] - 2026-08-13

Rollback. A previously deployed version can be put back on the whole fleet, and
the fleet refuses to move at all unless every host has the image.

### Added
- `Executor#rollback_plan` and `#rollback_all`, which return every role on
  every host to a previously deployed version by reusing the deploy path, so
  health gating and proxy handling are shared with `deploy`. The target is
  chosen from what the hosts report — running container labels, images present,
  and each host's `deploys.log` — never from the local repository, which can
  drift from what a host can actually run.
- A fleet pre-flight: the target image must be present on every host across all
  roles before any host is touched. A half-rolled-back fleet is worse than a
  refused command.
- `Executor#version_survey`, `HostVersions` and `RollbackPlanner`.
- `Docker::Client#image_tags`, listing the tags a host has for a repository.

### Changed
- Deploys are recorded on the host by `Executor` rather than by each
  orchestrator. A rollback now records `kind=rolled-back` with the version it
  replaced, and a role deployed by a sail-provided strategy gets the same audit
  trail instead of none.
- `VersionResolver#deployer` is public, so a rollback can name who ran it even
  though its version came from a host rather than a commit.

### Fixed
- `odysseus accessory status` never worked in any released version. The code
  called `orchestrator.get_status(name:)`, but `Orchestrator::AccessoryDeploy`
  defines `list_status` and no `get_status`, so the command always raised
  `NoMethodError`. The bad call was introduced on 2025-12-27 in `343030b`,
  three days before the `accessory status` subcommand itself shipped in
  odysseus-cli 0.2.0 (2025-12-30) — so there was never a working version to
  regress from. Fixed in `188a695`: `AccessoryManager#status_on` now calls
  `list_status` and selects the requested accessory out of its results, and a
  new spec exercises it through a verifying double, so a future rename of
  `list_status` breaks the build instead of the command.

### Internal
- Accessory lifecycle methods (`deploy`, `remove`, `restart`, `upgrade`,
  `status`, `boot_all`) moved out of `Executor` into
  `Deployer::AccessoryManager`, to keep both classes under their existing size
  limits. The public API is unchanged, and `AccessoryManager` gets the first
  spec coverage that code has ever had.

## [0.4.2] - 2026-08-13

A running container can now be traced back to the commit it was built from. The
notable behaviour change is that the image tag no longer defaults to `latest`.

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
