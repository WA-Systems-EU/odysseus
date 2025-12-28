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

Deploy:

```bash
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

### Accessories

Manage databases, Redis, and other services:

```yaml
accessories:
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

### AWS Auto Scaling Groups

Dynamically resolve hosts from AWS ASGs:

```yaml
servers:
  web:
    aws:
      asg: my-web-asg
      region: us-east-1
```

## Documentation

See [odysseus-cli/README.md](odysseus-cli/README.md) for complete CLI documentation and configuration reference.

## Project Structure

```
odysseus/
├── odysseus-core/    # Core library (config parsing, deployers, orchestrators)
├── odysseus-cli/     # Command-line interface
└── doc-site/         # Documentation website
```

## Development

```bash
cd odysseus-core
bundle install
bundle exec rspec
```

## Requirements

**Local machine:**
- Ruby 3.2+
- Docker (for building images)

**Target servers:**
- Docker
- SSH access

Caddy is automatically deployed as a container - no manual installation needed.

## License

MIT

---

*OpenSource is great. You can get inspiration from projects, do something different that fits your needs, and turn a page at the same time.* — T.R^3
