# Odysseus

Zero-downtime Docker deployments over SSH with automatic HTTPS.

> **Beta:** Odysseus is under active development. APIs and configuration may change. Feedback and contributions welcome!

Odysseus deploys containerized applications to your own servers using SSH, Docker, and Caddy. No Kubernetes. No container orchestration platform. Just simple, reliable deployments.

## Why Odysseus?

- **Zero-downtime deployments** - New containers start before old ones stop
- **Automatic HTTPS** - Caddy handles SSL certificates via Let's Encrypt
- **No registry required** - Push images directly to servers via SSH with [pussh](https://github.com/psviderski/unregistry)
- **Minimal server requirements** - Just Docker and SSH access
- **Familiar configuration** - YAML config inspired by Kamal

## How It Works

```
┌─────────────┐     SSH      ┌─────────────────────────────────────┐
│   odysseus  │─────────────▶│            Your Server              │
│     CLI     │              │  ┌───────────┐    ┌──────────────┐  │
└─────────────┘              │  │   Caddy   │───▶│  App (new)   │  │
                             │  │  (proxy)  │    └──────────────┘  │
                             │  └───────────┘    ┌──────────────┐  │
                             │        │         │  App (old)   │  │
                             │        └────────▶│  (draining)  │  │
                             │                  └──────────────┘  │
                             └─────────────────────────────────────┘
```

1. Build your Docker image locally
2. Push it to servers via SSH (or registry)
3. Start new container, wait for health check
4. Update Caddy routing to new container
5. Drain connections from old container
6. Stop and clean up old containers

## Quick Start

Install the CLI:

```bash
gem install odysseus-cli
```

Create `deploy.yml`:

```yaml
service: myapp
image: myapp

servers:
  web:
    hosts:
      - app.example.com

proxy:
  hosts:
    - myapp.example.com
  app_port: 3000
  ssl: true
  ssl_email: admin@example.com

ssh:
  user: root
  keys:
    - ~/.ssh/id_ed25519
```

Prepare a fresh host, if you have one to prepare:

```bash
# Creates the user ssh.user names, adds it to the docker group, installs your
# key, and installs Docker if the host has none. Ubuntu 24.04/26.04 only, and
# for getting a single host going — servers at scale belong to OpenTofu or an
# equivalent tool. Skip this entirely for a host you provisioned yourself.
odysseus setup

# Read-only, and worth running however the host was prepared
odysseus doctor
```

Deploy:

```bash
# From a git repository with everything committed — the version is the commit
odysseus deploy --build

# Anywhere else, name the version yourself (see odysseus-cli/README.md,
# "Naming the version", for what this costs)
odysseus deploy --build --image v1.0.0
```

## Features

### Roles

Deploy different container configurations to different servers:

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
      - worker.example.com
    cmd: bundle exec good_job
```

### Dependencies

Manage databases, Redis, and other services:

```yaml
dependencies:
  db:
    image: postgres:16
    hosts:
      - db.example.com
    volumes:
      - /var/lib/odysseus/myapp/postgres:/var/lib/postgresql/data
```

### Encrypted Secrets

Store sensitive environment variables securely:

```bash
odysseus secrets generate-key
odysseus secrets encrypt --input secrets.yml --file secrets.yml.enc
```

### Health Checks

Configurable health checks ensure containers are ready before receiving traffic:

```yaml
proxy:
  healthcheck:
    path: /health
    interval: 10
    timeout: 5
    expect_status: 200
```

### Rollback

Return every role on every host to a previously deployed version, chosen from
what the hosts actually have rather than your local checkout:

```bash
odysseus rollback              # to the previous version
odysseus rollback --list       # what each host could roll back to
```

### Image Retention

After a successful deploy, superseded image versions are pruned from each
host, keeping the newest `retain_versions` (default 5). A version still
referenced by a container, running or stopped, is never removed, and
`latest` never is either:

```yaml
retain_versions: 5
```

Setting this below 2 leaves `odysseus rollback` with no candidate, since the
previous version's image becomes eligible for removal as soon as you deploy.

### Sail Plugins

Some features — a deploy strategy, a way of resolving a role's hosts — ship
as separate gems rather than being built in. Installing the gem is not
enough on its own; it also has to be named in deploy.yml, since Odysseus
never auto-discovers what happens to be installed:

```bash
gem install odysseus-sail-rolling
```

```yaml
plugins:
  - odysseus-sail-rolling

servers:
  web:
    deploy:
      strategy: rolling
```

`odysseus-sail-rolling` replaces a role's containers one at a time instead of
all at once, bounding the extra memory a deploy needs. **It has not been
exercised against a real host**, unlike `deploy` and `rollback` above — treat
it as unproven until you've run it yourself. See
[odysseus-cli/README.md](odysseus-cli/README.md#plugins) for the full
reference, including `odysseus-sail-aws-asg` for dynamic hosts and a
container-naming collision worth knowing about before using more than one
role with `rolling`.

## Documentation

See [odysseus-cli/README.md](odysseus-cli/README.md) for complete CLI documentation and configuration reference.

## Project Structure

```
odysseus/
├── odysseus-core/    # Core library (config parsing, deployers, orchestrators)
└── odysseus-cli/     # Command-line interface
```

## Development

```bash
cd odysseus-core
bundle install
bundle exec rspec
```

Both gems have their own bundle and test suite. See
[CONTRIBUTING.md](CONTRIBUTING.md) for setup, how changes are expected to
arrive, and the release process.

## Requirements

**Local machine:**
- Ruby 3.2+
- Docker (for building images)

**Target servers:**
- SSH access
- Docker — or a supported Ubuntu (24.04/26.04) and `odysseus setup`, which
  installs it. Deploys themselves never check the distro: any host with a
  working Docker daemon will do.

Caddy is automatically deployed as a container - no manual installation needed.

## Roadmap

- **Odysseus Pro** (coming soon) - Web dashboard, team management, deployment history, and more

## License

MIT

---

*OpenSource is great. You can get inspiration from projects, do something different that fits your needs, and turn a page at the same time.* — T.R^3
