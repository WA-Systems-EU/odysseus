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
- `--image TAG` - Docker image tag (default: latest)
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
- `--image TAG` - Docker image tag (default: latest)
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
- `--image TAG` - Docker image tag (default: latest)
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

### accessory

Manage accessories (databases, Redis, etc).

```bash
odysseus accessory boot <server> --name db
odysseus accessory boot-all <server>
odysseus accessory remove <server> --name db
odysseus accessory restart <server> --name db
odysseus accessory upgrade <server> --name db
odysseus accessory status <server>
odysseus accessory logs <server> --name db [-f] [-n 100]
odysseus accessory exec <server> --name db --command "psql -U postgres"
odysseus accessory shell <server> --name db
```

### app

Run commands in app containers.

```bash
odysseus app shell <server>
odysseus app exec <server> --command "rails db:migrate"
odysseus app console <server> [--cmd "rails c"]
```

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
```

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

### accessories

Long-running services like databases:

```yaml
accessories:
  db:
    image: postgres:16
    volumes:
      - /var/lib/odysseus/myapp/postgres:/var/lib/postgresql/data
    env:
      clear:
        POSTGRES_USER: myapp
        POSTGRES_DB: myapp_production
    healthcheck:
      cmd: pg_isready -U myapp
      interval: 10
      timeout: 5
```

### ssh

SSH connection settings:

```yaml
ssh:
  user: root
  keys:
    - ~/.ssh/id_ed25519
```

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

## How It Works

1. **Deploy** starts a new container with the specified image tag
2. **Health check** waits for the container to become healthy
3. **Caddy update** adds the new container to the upstream pool
4. **Drain** removes old containers from Caddy and waits for connections to close
5. **Cleanup** stops old containers and removes all but the 2 most recent

This ensures zero-downtime deployments with automatic rollback if health checks fail.

## License

MIT
