# Odysseus CLI

Command-line interface for deploying Docker containers with zero-downtime using Caddy as a reverse proxy.

## Installation

```bash
gem install odysseus-cli
```

Or add to your Gemfile:

```ruby
gem 'odysseus-cli'
```

## Quick Start

1. Create a `deploy.yml` in your project:

```yaml
service: myapp
image: myregistry/myapp

servers:
  web:
    hosts:
      - server1.example.com
  jobs:
    hosts:
      - server1.example.com
    cmd: bundle exec good_job

proxy:
  hosts:
    - myapp.example.com
  app_port: 3000
  ssl: true
  ssl_email: admin@example.com
  healthcheck:
    path: /health
    interval: 10
    timeout: 5

env:
  clear:
    RAILS_ENV: production
  secret:
    - DATABASE_URL
    - RAILS_MASTER_KEY

ssh:
  user: root
  keys:
    - ~/.ssh/id_ed25519
```

2. Build and deploy:

```bash
# Build, distribute, and deploy in one command
odysseus deploy --image v1.0.0 --build
```

The `--build` flag automatically chooses how to distribute the image:
- **Without `registry` config** → uses [pussh](https://github.com/psviderski/unregistry) to transfer images directly via SSH
- **With `registry` config** → pushes to registry, hosts pull from there

## Commands

### deploy

Deploy all roles to their configured hosts.

```bash
odysseus deploy [options]
```

Options:
- `--config FILE` - Path to deploy.yml (default: deploy.yml)
- `--image TAG` - Docker image tag (default: the git commit being deployed; required outside a clean git repository)
- `--build` - Build and distribute image before deploying
- `--dry-run` - Show what would be deployed without doing it
- `-v, --verbose` - Show SSH commands being executed

The `--build` flag automatically chooses the distribution method based on your config:
- **No `registry` config** → uses pussh (direct SSH transfer to each host)
- **Has `registry` config** → pushes to registry (hosts pull from there)

Examples:

```bash
# Deploy existing image
odysseus deploy --image v1.0.0

# Build, distribute, and deploy in one command
odysseus deploy --image v1.0.0 --build
```

### build

Build Docker image locally or on a remote build host.

```bash
odysseus build [options]
```

Options:
- `--config FILE` - Path to deploy.yml (default: deploy.yml)
- `--image TAG` - Docker image tag (default: the git commit being deployed; required outside a clean git repository)
- `--push` - Push image to registry after build
- `--context PATH` - Build context path (default: . relative to deploy.yml)
- `-v, --verbose` - Show build commands being executed

Examples:

```bash
# Build locally
odysseus build --image v1.0.0

# Build and push to registry
odysseus build --image v1.0.0 --push

# Build with custom context path
odysseus build --image v1.0.0 --context ./app
```

### pussh

Push Docker image directly to hosts via SSH (no registry needed). Uses [docker-pussh/unregistry](https://github.com/psviderski/unregistry) to transfer images.

> **Note:** When no `registry` is configured, `odysseus deploy --build` automatically uses pussh. This command is useful for manually pushing images without deploying.

```bash
odysseus pussh [options]
```

Options:
- `--config FILE` - Path to deploy.yml (default: deploy.yml)
- `--image TAG` - Docker image tag (default: the git commit being deployed; required outside a clean git repository)
- `--build` - Build image before pushing
- `-v, --verbose` - Show commands being executed

Examples:

```bash
# Push existing local image to all hosts
odysseus pussh --image v1.0.0

# Build and push in one step
odysseus pussh --image v1.0.0 --build
```

**Prerequisites:** Install docker-pussh on your local machine:
```bash
# macOS/Linux
curl -fsSL https://github.com/psviderski/unregistry/releases/latest/download/docker-pussh-$(uname -s)-$(uname -m) \
  -o ~/.docker/cli-plugins/docker-pussh && chmod +x ~/.docker/cli-plugins/docker-pussh
```

### status

Show service status on a server.

```bash
odysseus status <server> [--config FILE]
```

### containers

List containers for the service on a server.

```bash
odysseus containers <server> [--config FILE] [--service NAME]
```

### logs

Show logs for a service.

```bash
odysseus logs <server> [options]
```

Options:
- `--role ROLE` - Role to show logs for: web, jobs, etc (default: web)
- `-f, --follow` - Follow log output
- `-n, --lines N` - Number of lines to show (default: 100)
- `--since TIME` - Show logs since timestamp (e.g., '10m', '2h')

Stopped containers are included, since the container that has just exited is
usually the one whose logs you want; when the only match is stopped, the
command says so before printing them. That notice, and the message when no
container is found at all, go to stderr, so `odysseus logs web1 > app.log`
captures the logs and nothing else. Finding no container at all — running or
stopped — exits non-zero, and the message names the role, the label it
searched for and the roles this config has.

### cleanup

Clean up old containers and optionally prune images.

```bash
odysseus cleanup <server> [--prune-images]
```

### validate

Validate your deploy.yml configuration.

```bash
odysseus validate [--config FILE]
```

This loads `plugins:`/`sails:` before checking anything else, the same as
every other command, so it also catches a plugin gem that is not installed
on this machine — see `plugins` in the configuration reference below.

### rollback

Return every role on every host to a previously deployed version.

```bash
odysseus rollback              # to the previous version
odysseus rollback abc123def456 # to a specific version
odysseus rollback --list       # what each host could roll back to
```

The target is chosen from what the hosts have, not from your checkout: the
version must still have an image on **every** host, or the rollback refuses
without touching any of them.

A rollback re-runs the deploy path, so it starts a container and waits for
health checks — roughly the time of a normal deploy, minus build and transfer.

Only versions deployed by odysseus 0.4.2 or later can be rolled back to.
Earlier deploys were built from `:latest`, so no image identifies them.

### dependency

Manage dependencies (databases, Redis, etc). `dep` is accepted as shorthand.

**Renamed from `accessory`.** The old command name and the old `accessories:`
key in deploy.yml both still work, and the command prints a notice when you use
the old name. They will be removed in a later release, so rename the key in your
deploy.yml when convenient:

```yaml
dependencies:   # was: accessories:
  db:
    image: postgres:16
```

Nothing on your hosts changes when you rename the key. Container names and the
`odysseus.service` label are built from the service name plus the individual
dependency's name, so `db` stays `myapp-db` either way and running containers
are adopted rather than orphaned.

```bash
# These commands use hosts from dependency config (no server argument needed)
odysseus dependency boot --name db
odysseus dependency boot-all
odysseus dependency remove --name db
odysseus dependency restart --name db
odysseus dependency upgrade --name db
odysseus dependency status

# These commands require a server argument
odysseus dependency logs <server> --name db [-f] [-n 100]
odysseus dependency exec <server> --name db --command "psql -U postgres"
odysseus dependency shell <server> --name db
```

Dependency commands like `boot`, `remove`, `restart`, `upgrade`, and `status` read the target hosts from the dependency's `hosts` configuration in deploy.yml, similar to how `deploy` works. Only `logs`, `exec`, and `shell` require a server argument since they operate on a specific host.

### app

Run commands in app containers.

```bash
odysseus app shell <server>
odysseus app exec <server> --command "rails db:migrate"
odysseus app console <server> [--cmd "rails c"]
```

Options:
- `--role ROLE` - Role whose running image to use: web, jobs, etc (default: web)

Each of these runs a new container from the image the named role is currently
running on that host. Containers are labelled per role, so `--role` is required
to reach anything but web — including on a service that has no web role at all,
where the default matches nothing on any host:

```bash
odysseus app exec worker1.example.com --role jobs --command "rails runner …"
```

The container is given the same environment a deploy gives it — `env.clear` and
`env.secret` both — so `odysseus app exec web1 --command "rails db:migrate"`
talks to the same database as the app running beside it. The values travel in an
env file rather than on the command line; see [env](#env) for what that means
and for the one case where the file is left behind.

`shell` and `console` print a header before handing the terminal over — the
server, the role, the image that is serving and the command being run — because
the prompt you land on tells you none of it:

```
  App Shell
  Server: dedalus-prod
  Role: web
  Image: dedalus-production:v1.4.2
  Command: /bin/sh
  › New container from that image: the running app is untouched, and this one is discarded on exit.
```

That last line is the point. These commands `docker run` the serving image; they
do not attach to the container taking traffic. Nothing you do inside reaches the
running app, and the container is removed when you leave. `dependency shell` is
the other way round — it `docker exec`s into the running dependency, so what you
do there is live.

The header goes to **stderr**, so a session whose output you are capturing —
`odysseus app console web1 --cmd "rails runner 'puts Thing.count'" > count` —
gets the session's own output on stdout and nothing else.

### secrets

Manage encrypted secrets files.

```bash
# Generate a new master key
odysseus secrets generate-key

# Encrypt a plaintext secrets file
odysseus secrets encrypt --input secrets.yml --file secrets.yml.enc

# Decrypt and display secrets (values are masked)
odysseus secrets decrypt --file secrets.yml.enc

# Edit encrypted secrets using $EDITOR
odysseus secrets edit --file secrets.yml.enc
```

The master key should be set as `ODYSSEUS_MASTER_KEY` environment variable.

## Configuration Reference

### service

The name of your service. Used for container naming and Caddy routing.

### image

The Docker image name (without tag). Tags are specified at deploy time.

### plugins

Some features ship as separate gems ("sails") instead of being built into
Odysseus — a deploy strategy, a way of resolving a role's hosts. Having the
gem is not enough by itself: it also has to be named here, because Odysseus
never auto-discovers what happens to be installed. That is deliberate — the
same deploy.yml should behave identically on every machine, whether or not
some other gem is sitting in the local bundle.

```yaml
plugins:
  - odysseus-sail-example
```

`sails:` is accepted as the same key under a different name; a deploy.yml
carrying both is a config error, not a silent preference of one over the
other. Each name is `require`d before the rest of deploy.yml is checked —
that ordering is what lets `servers.<role>.deploy.strategy` below resolve to
a strategy the plugin registers. A name that will not `require` (not
installed, or misspelled) stops validation with an error that names the gem,
rather than failing later at deploy time. `odysseus validate` runs this same
loading step, so it catches a missing plugin gem too — which means
`validate` can fail on a machine that lacks the gem where it used to pass,
if your deploy.yml lists one.

**No sail gem is published to RubyGems.** `odysseus-sail-example` above is a
placeholder, not a gem you can install. The sails that exist live in their
own repositories alongside this one, so a deploy.yml that names one only
works where the gem is reachable from your app's Gemfile:

```ruby
# Gemfile — one or the other, not both
gem 'odysseus-sail-example', git: 'https://example.com/odysseus-sail-example.git'
gem 'odysseus-sail-example', path: '../odysseus-sail-example'
```

The failure a plugin that will not load raises suggests `gem install <name>`.
That is the right advice for a published gem, and no help for a sail: the fix
is the Gemfile entry above.

### servers

Define roles and their target hosts:

```yaml
servers:
  web:
    hosts:
      - web1.example.com
      - web2.example.com
    options:
      memory: 4g
      cpus: 2
  jobs:
    hosts:
      - worker1.example.com
    cmd: bundle exec good_job
    options:
      memory: 2g
      cpus: 1.5
```

Available options:
- `memory` - Hard memory limit (e.g., `4g`, `512m`)
- `memory_reservation` - Soft memory limit
- `cpus` - CPU limit (e.g., `2` for 2 cores, `1.5` for 1.5 cores)
- `cpu_shares` - Relative CPU weight (default: 1024)

**SSH configuration** (bastions, ProxyJump, etc.) is your responsibility. Odysseus only needs the hostnames/IPs and relies on your local SSH config.

Every role must carry a `hosts` array, or config validation rejects it with
`server role 'web' must have 'hosts' array`. A sail that resolves a role's
hosts for you — see `plugins` above — still needs the key present; it may be
empty, and the sail fills it in at deploy time.

#### containers

Run more than one container per host for a role — meaningful only to a
strategy that reads it. The built-in strategy always runs exactly one
container per role per host and ignores this block:

```yaml
servers:
  web:
    deploy:
      strategy: example
    containers:
      count: 3                 # containers per host on this role (default: 1)
      name_pattern: "web-%d"   # default for every role — see warning below
```

**`name_pattern` defaults to `"web-%d"` for every role, and a container's
name is built from the bare service name, not the role**
(`<service>-<name_pattern % slot>`). Two roles that both leave it at the
default — say `web` and a multi-container `jobs`, on the same multi-container
strategy and deployed to the same host — produce identically-named
containers, and each role's deploy will see and manage the other's
containers. Give every role beyond the first its own `name_pattern` (e.g.
`"jobs-%d"`) whenever more than one role runs multi-container on a shared
host.

#### deploy

```yaml
servers:
  web:
    deploy:
      strategy: example        # optional — see `plugins` above; omit for the built-in strategy
      drain_timeout: 30        # seconds to wait for in-flight connections before stopping the old container
      stop_timeout: 10         # seconds of grace before the old container is force-removed
      boot_timeout: 60         # seconds to wait for a new container to become healthy
      health_check:
        path: /up               # default: /up
        interval: 2             # seconds between checks (default: 2)
        threshold: 3            # consecutive successes required (default: 3)
        timeout: 5              # seconds per check (default: 5)
```

`strategy` chooses the orchestrator for the role. Leave it out for
Odysseus's built-in zero-downtime replacement (start new, health-check via
`proxy.healthcheck`, switch traffic, drain and stop old — its own timings,
not the ones below). Name a strategy a plugin registers — currently only
`rolling` — to use that instead; it must be loaded via `plugins:` first, or
config validation refuses it with "is not registered — is the sail plugin
gem loaded?".

`drain_timeout`, `stop_timeout`, `boot_timeout` and `health_check` are parsed
and shape-checked regardless of `strategy`, but **the built-in strategy does
not read them** — it drains for a fixed 5 seconds and waits up to a fixed 60
seconds for Docker's own health check, neither of which this block changes.
They exist for a strategy that chooses to read them; `rolling` does.

### proxy

Caddy reverse proxy configuration:

```yaml
proxy:
  hosts:
    - myapp.example.com
    - www.myapp.example.com
  app_port: 3000
  ssl: true
  ssl_email: admin@example.com
  healthcheck:
    path: /health
    interval: 10
    timeout: 5
    expect_status: 200  # Optional: expected HTTP status (default: 2xx)
```

A web container must report healthy before Odysseus routes traffic to it. If
you omit `healthcheck`, the container is probed with `GET /` on `app_port`.

### env

Environment variables:

```yaml
env:
  clear:
    RAILS_ENV: production
  secret:
    - DATABASE_URL
    - RAILS_MASTER_KEY
```

- `clear` - Plaintext values stored in deploy.yml
- `secret` - Keys to load from encrypted secrets file or server environment

Both are handed to the container through an env file written under the state
directory described in [ssh](#ssh) — `/var/lib/odysseus/env` for the default
root connection — with `0600` permissions, and removed once the container has
been created, so secrets never appear in the host's process list. A value
containing a newline is rejected, since a Docker env file cannot represent one.

`app exec`, `app shell` and `app console` get the same environment the same way.
An interactive session holds its env file for as long as the session lasts and
removes it on the way out, whether the session ended cleanly, exited non-zero or
was interrupted. A session that sits idle long enough for its ssh connection to
be dropped — an idle NAT timeout, an `sshd` `ClientAlive` limit, a Tailscale
relay change — is included: the file is removed over a fresh connection.

Two cases still leave the file on the host. The `odysseus` process being killed
outright — `SIGKILL`, or the machine going down — where no cleanup can run at
all; and a host that is unreachable when the session ends, where there is
nowhere to send the removal. The file is mode `0600` inside that same env
directory, which is `0700` for every connection, so another user on the box
still cannot read it; but nothing comes back to remove it, since the next run
writes its own file rather than tidying old ones.

### secrets_file

Path to an encrypted secrets file (relative to deploy.yml or absolute):

```yaml
secrets_file: secrets.yml.enc
```

Create the encrypted file using `odysseus secrets encrypt`. The secrets file should be YAML format:

```yaml
# secrets.yml (before encryption)
DATABASE_URL: postgres://user:pass@db/myapp
RAILS_MASTER_KEY: abc123def456
```

During deploy, secrets listed in `env.secret` are loaded from the encrypted file. If a key is not found in the secrets file, it falls back to the server's environment variables.

### dependencies

Long-running services like databases:

```yaml
dependencies:
  db:
    image: postgres:16
    hosts:
      - db.example.com
    volumes:
      - /srv/myapp/postgres:/var/lib/postgresql/data
    env:
      clear:
        POSTGRES_USER: myapp
        POSTGRES_DB: myapp_production
    healthcheck:
      cmd: pg_isready -U myapp
      interval: 10
      timeout: 5
```

Each dependency must define `hosts` - the servers where it should run.

### ssh

SSH connection settings:

```yaml
ssh:
  user: root
  keys:
    - ~/.ssh/id_ed25519
```

`user` defaults to `root` and also decides where odysseus keeps state on the
host. A root connection writes to `/var/lib/odysseus`, exactly as always. Any
other user writes under its own `$HOME/.odysseus` instead, because it cannot
create or `chmod` a directory root owns. Caddy's certificate directory
follows the same rule as everything else: `/var/lib/odysseus/caddy` for a
root connection, `$HOME/.odysseus/caddy` for any other user.

A non-root `user` must already exist on the target host — with membership in
the `docker` group and a writable home directory — and its key must be one of
`keys` above. Odysseus does not create this user, install Docker, or set up
the host for you; all of that is on you today.

### builder

Configuration for building Docker images:

```yaml
builder:
  strategy: local           # 'local' or 'remote'
  host: build-server        # Required if strategy is 'remote'
  dockerfile: Dockerfile    # Dockerfile name (default: Dockerfile)
  context: .                # Build context path (default: .)
  arch: amd64               # Target architecture
  build_args:               # Build arguments
    RUBY_VERSION: "3.2"
    NODE_VERSION: "18"
  cache: true               # Use Docker build cache (default: true)
  push: false               # Auto-push after build (default: false)
  multiarch: false          # Multi-platform builds with buildx
  platforms:                # Platforms for multi-arch builds
    - linux/amd64
    - linux/arm64
```

Build strategies:
- `local` - Build on the local machine (default)
- `remote` - Build on a remote host via SSH (useful for CI or dedicated build servers)

### registry

Docker registry configuration. When present, `odysseus deploy --build` will push images to the registry instead of using pussh:

```yaml
registry:
  server: docker.io         # Registry server (required to enable registry mode)
  username: myuser          # Registry username
  password: mypassword      # Registry password (consider using secrets)
```

**Image distribution modes:**

| Config | `deploy --build` behavior |
|--------|---------------------------|
| No `registry` | Build locally → pussh to each host via SSH |
| Has `registry` | Build locally → push to registry → hosts pull |

For better security, you can store registry credentials in your encrypted secrets file and reference them.

### retain_versions

How many distinct versions of your service's image each host keeps. Default 5.

```yaml
retain_versions: 5
```

After a successful deploy, images outside that window are removed from each
host. An image is only removed if the host's own deploy log records it, no
container on the host still references it, and docker accepts the removal —
so a version you are still running is never deleted, and a failure to delete
one image never fails the deploy.

Setting this to `1` is allowed but means the previous version's image becomes
eligible for removal as soon as you deploy, leaving `odysseus rollback` with
no candidate. Use at least 2 if you want to be able to roll back.

`latest` is never removed automatically. `odysseus cleanup --prune-images`
only removes *dangling* images, and a tagged `latest` is never dangling —
removing it means `docker image rm` by hand on the host.

## Server Requirements

Your target servers only need **Docker** installed. Odysseus automatically deploys and manages Caddy as a container (`odysseus-caddy`) - no manual Caddy installation required.

## How It Works

1. **Ensure Caddy** starts the Caddy container if not running
2. **Deploy** starts a new container with the specified image tag
3. **Health check** waits for the container to become healthy
4. **Caddy update** adds the new container to the upstream pool
5. **Drain** removes old containers from Caddy and waits for connections to close
6. **Cleanup** stops old containers and removes all but the 2 most recent
7. **Stale upstream cleanup** removes any Caddy routes pointing to stopped containers

This ensures zero-downtime deployments with automatic rollback if health checks fail.

## License

MIT
