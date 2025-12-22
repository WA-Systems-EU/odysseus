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

2. Deploy:

```bash
odysseus deploy --image v1.0.0
```

## Commands

### deploy

Deploy all roles to their configured hosts.

```bash
odysseus deploy [options]
```

Options:
- `--config FILE` - Path to deploy.yml (default: deploy.yml)
- `--image TAG` - Docker image tag (default: latest)
- `--dry-run` - Show what would be deployed without doing it
- `-v, --verbose` - Show SSH commands being executed

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

## How It Works

1. **Deploy** starts a new container with the specified image tag
2. **Health check** waits for the container to become healthy
3. **Caddy update** adds the new container to the upstream pool
4. **Drain** removes old containers from Caddy and waits for connections to close
5. **Cleanup** stops old containers and removes all but the 2 most recent

This ensures zero-downtime deployments with automatic rollback if health checks fail.

## License

MIT
