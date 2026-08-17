# Changelog

All notable changes to odysseus-core are documented here.

Entries for 0.3.1 and earlier were reconstructed from git history and the built
gem artifacts, so they are summaries rather than contemporaneous notes.

## [Unreleased]

### Added
- `Odysseus::Setup::Escalation`, `Odysseus::Setup::PublicKey` and
  `Odysseus::Setup::Preparer`, the classes behind `odysseus setup`
  (odysseus-cli). `Escalation` gets root on the target host via passwordless
  sudo, or none at all when connected as root, and refuses up front —
  before anything is touched — if passwordless sudo isn't available, since
  a password prompt can't be answered. `PublicKey` resolves which key(s) to
  install, entirely on the local machine before any host is touched: from
  `--key`, or from each `ssh.keys` entry's `.pub` sibling, deriving one via
  `ssh-keygen -y` only when that sibling is empty or missing; a key that
  doesn't resolve, or a sibling with content that doesn't validate, refuses
  by name rather than silently substituting a different key. `Preparer`
  runs the actual sequence against a host: creates the deploy user and its
  home, adds it to the `docker` group, installs the resolved key(s),
  creates the state directory, and finishes by opening a second connection
  as that new user to prove Docker and the state directory both work
  before reporting success. Docker itself is not installed by this
  version — a host whose Docker daemon does not answer is refused, naming
  that it may not be installed or may simply be stopped, since `docker
  info` cannot tell the two apart.

## [0.8.0] - 2026-08-17

### Fixed
- `VersionResolver#resolve` now names the deployer for an explicitly-tagged
  deploy (`odysseus deploy --image v1.2.3`), instead of recording `nil`. The
  deployer comes from `git config user.email`, falling back to `$USER` — a
  lookup that needs no commit and no clean working tree, so withholding it
  alongside `ref` was never justified. Every explicitly-tagged deploy wrote a
  host-side log line with no name on it, which emptied the "by whom" column
  of `odysseus rollback --list` and left the host-side deploy history
  unattributed. `ref` still stays `nil` for an explicit tag: an arbitrary tag
  names no commit it honestly identifies, so there is nothing true to record
  there.
- `Caddy::Client#start_caddy` now publishes the admin API on
  `127.0.0.1:2019` instead of `2019:2019`, which bound it to every
  interface. That API can rewrite the proxy configuration — routes,
  upstreams, TLS — for every service on the host, so anyone who could reach
  the port controlled the proxy. `Caddy::Client` only ever calls it via
  `curl localhost` over SSH, so nothing needed the external exposure. The
  in-container `CADDY_ADMIN` bind stays `0.0.0.0:2019`, which is what the
  published port maps to — only where the port lands on the host changed.
  **This does not close the exposure on a host where Caddy is already
  running**: `ensure_running` returns early when the container is up, so
  the new binding only takes effect the next time Caddy is recreated
  (stopped and restarted, or removed). An already-running Caddy stays bound
  to every interface until that happens.
- `JobDeploy` now ensures the `odysseus` Docker network exists before
  starting a container, instead of assuming it. It ran every container with
  `network: 'odysseus'` but never created that network itself, so a jobs-only
  service deployed to a fresh host failed at `docker run`. The gap was
  invisible on any host that had ever deployed a web role or a dependency
  first: a web role's `ensure_caddy!` creates the network as a side effect of
  starting Caddy, and `DependencyDeploy` has always had its own
  `ensure_network!`. Found on a genuinely fresh host with the deploy user
  ready but no prior deploy of either kind.
- `Caddy::Client#ensure_running` now recreates a stopped Caddy container
  instead of trying to `docker run` a new one over it. Once Caddy had been
  stopped, `--name odysseus-caddy` collided with the container Docker still
  had by that name, and `docker run` refused every time after: every
  subsequent deploy failed and the proxy stayed down until someone removed
  the container by hand. Absent and already-running containers are
  unaffected. The stopped container is removed rather than `docker start`ed
  so it always picks up current configuration — notably the deploy-user
  Caddy directory added earlier in this file — instead of resuming with
  whatever it was created with.

### Added
- `Odysseus::HostPaths`, which decides where odysseus keeps state on a host
  from the connecting SSH user: `root` still gets `/var/lib/odysseus`, exactly
  as before and with no extra SSH round trip; any other user gets
  `$HOME/.odysseus`, resolved by asking the host once per connection.
- `Odysseus::HostVerifier`, a read-only diagnosis of one host, run as the
  user the config names rather than root. `#verify` runs distro, docker
  reachability, docker group membership, state-directory writability and
  deploy-log location, and returns one `Result` per check with a `:ok`,
  `:warn` or `:fail` status — it writes nothing to the host. `odysseus
  doctor` (odysseus-cli) drives it over every host in a config.

### Changed
- Env files (`Docker::Client`) and the deploy log (`DeployLog`) now follow
  `HostPaths` instead of a fixed `/var/lib/odysseus` constant. Before this,
  a non-root deploy could not work at all: `write_env_file` chmods its
  directory before writing into it, and a non-owner cannot chmod a directory
  root created, so the deploy died at the first container start. This is the
  change that makes a non-root deploy possible, on a host you have already
  configured for it.
- Caddy's certificate directory (`Caddy::Client`) now follows `HostPaths`
  too, instead of staying fixed at `/var/lib/odysseus/caddy`. It was
  deliberately left out of the earlier change in this release to avoid
  moving issued Let's Encrypt certificates or re-issuing against rate
  limits — but that risk only ever applied to root installs, which are the
  only ones with certificates at the old path. Deriving the directory
  protects them identically: root still resolves to
  `/var/lib/odysseus/caddy`, byte-identical. Leaving it fixed meant a
  non-root deploy user could never create it, so `ensure_running` failed at
  `mkdir -p /var/lib/odysseus/caddy` on every non-root web deploy — found on
  a real host. Root is unaffected.
- `rollback --list` keeps its history across the move: a host that deployed
  as root and later switches to a deploy user still has its old log read as
  a fallback when the new location is absent (or unreadable) rather than
  empty — an empty file at the new location exits 0 and suppresses the
  fallback. Reads fall back to the old location; appends only ever go to the
  new one.
- `Executor#host_roles` is public API now, not a private helper. It answers
  the same question the CLI needs answered — which hosts does this config
  target, and which roles does each serve — so `odysseus doctor` can visit
  every host once, however many roles it serves, without duplicating the
  host-resolution logic this method already implements.
- Nothing changes for a root install.

## [0.7.0] - 2026-08-16

A minor bump for two reasons: there is new public API, and a one-off container's
environment changes shape. Anything that ran `app exec` and relied on reading
`-e` flags out of the host's process list — or on a secret being *absent* from
one-off runs — sees different behaviour.

### Fixed
- A one-off container — what `app exec`, `app shell` and `app console` run —
  no longer has its environment inlined into the docker command as `-e
  KEY=VALUE`. Every value now travels in the same 0600 env file a deployed
  container's does, so a customer's database password is no longer visible in
  `ps` on the deploy target, and a value containing a space or a shell
  metacharacter arrives intact instead of splitting or being interpreted. The
  file is named so it cannot collide with a running container's, and is
  removed even when the command fails.
- The env file is removed over a fresh connection when the connection it was
  written over has died in the meantime. Cleanup rescued `Odysseus::SSHError`
  alone, and a connection that drops mid-session raises `IOError`,
  `Net::SSH::Disconnect`, `Errno::EPIPE` or `Errno::ECONNRESET` — none of them
  an `SSHError`. The cleanup's own failure therefore escaped the ensure and
  replaced whatever the block was raising, so a file of secrets was left on the
  host *and* an interactive session's exit status arrived as a backtrace. The
  interactive paths are where this is likeliest: they hold the connection open,
  idle and unpumped, for as long as the user's session lasts, which is what an
  idle NAT timeout, sshd's `ClientAlive` limit or a Tailscale relay change need.
  Any failure of the removal is now swallowed rather than raised — including on
  the second attempt, after which the file is left behind, `0600` in a `0700`
  directory.
- An upload that fails partway no longer orphans a partial env file. The path
  was learned from the return value of the write, so a write that raised left
  the caller with `nil` and its cleanup with nothing to remove — while scp had
  already created the remote file and begun streaming secrets into it. The path
  is settled before the write now, so the file removed is the file written,
  whether or not the write finished.

### Added
- `Odysseus::Core::Environment`, the environment a container starts with —
  `env.clear` merged with each `env.secret` resolved from the encrypted
  secrets file or the host's own environment. WebDeploy and JobDeploy each had
  their own copy; one-off commands had neither, which is why `rails
  db:migrate` on a one-off container started without a `DATABASE_URL`.
- `Docker::Client#with_env_file`, which writes an env file, yields its path
  and removes it afterwards even on failure. `app shell` and `app console`
  need an interactive TTY and so run docker themselves; this is how their
  environment reaches the host as a file rather than as `-e` flags.

## [0.6.0] - 2026-08-15

A minor bump: `plugins:` is a new key, and `odysseus validate` can now fail
where it used to pass — on a machine that does not have a named plugin gem
installed. That is the point of the change, but it is a behaviour change.

### Added
- `plugins:` in deploy.yml, a list of gem names loaded before the config is
  validated, so a sail can register its strategy in time for
  `servers.<role>.deploy.strategy` to resolve. `sails:` is accepted as an
  alias. Until now nothing ever loaded a sail: both registries raised "is the
  gem loaded?" for every user, so `deploy.strategy` and the `aws:` host hook
  were unreachable while both READMEs described them.
- `Odysseus::Core::DeployVersioning`, the shared container version identity —
  `odysseus.version`, `odysseus.git_ref` and `odysseus.deployed_at` — included
  by both built-in orchestrators and available to sails. `status`, `rollback`
  and image retention all read these labels, so an orchestrator that invents
  its own scheme is invisible to them.

### Changed
- A deploy.yml carrying both `plugins:` and `sails:`, or both `dependencies:`
  and `accessories:`, is now an error. Silently preferring one meant editing
  the wrong key had no visible effect.
- `odysseus validate` loads plugins, so it now catches a plugin gem that is
  not installed. It will fail on a machine without the gem, where it passed
  before.
- A plugin that fails to load now reports the file that was actually missing,
  and says so differently when the plugin itself was found. A sail whose own
  dependency is absent — `odysseus-sail-aws-asg` without `aws-sdk-autoscaling`
  — used to read as if the sail were not installed, advising an install that
  could not fix it. The advice also names the Gemfile, which is what a
  `bundle exec odysseus` run needs.
- Plugin errors quote the key the deploy.yml actually used. Writing `sails:`
  and getting told about `plugins:` named a key that was not in the file.

## [0.5.0] - 2026-08-13

A minor bump rather than a patch: odysseus now deletes images on your hosts.
Nothing did that before, and there is no undo, so the release number should
make you read this entry.

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
  (stopped containers included, since a stopped container still references its
  image and an operator may still need it), and docker must accept the
  removal. Each removal is attempted on its own, so one
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
