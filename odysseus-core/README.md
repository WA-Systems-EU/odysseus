# Odysseus Core

Core library for [Odysseus](https://github.com/WA-Systems-EU/odysseus), a zero-downtime Docker deployment tool with Caddy reverse proxy integration.

## Installation

```bash
gem install odysseus-core
```

Or add to your Gemfile:

```ruby
gem 'odysseus-core'
```

## Overview

Odysseus Core provides the foundational components for Docker container deployment:

- **Configuration parsing** - YAML-based deploy.yml configuration
- **Docker client** - Container lifecycle management via SSH
- **Caddy client** - Reverse proxy configuration and routing
- **Deployer** - Zero-downtime deployment orchestration
- **Secrets** - Encrypted secrets file support

## Usage

This gem is primarily used by [odysseus-cli](https://rubygems.org/gems/odysseus-cli). For direct usage:

```ruby
require 'odysseus'

# Parse configuration
parser = Odysseus::Config::Parser.new('deploy.yml')
config = parser.parse

# Create executor
executor = Odysseus::Deployer::Executor.new('deploy.yml')

# Deploy
executor.deploy_all(image_tag: 'v1.0.0')
```

## Components

### Odysseus::Config::Parser

Parses deploy.yml configuration files with support for:
- Server roles (web, jobs, workers)
- Proxy configuration (Caddy)
- Accessories (databases, Redis, etc.)
- Environment variables and secrets

### Odysseus::Docker::Client

Docker operations via SSH:
- Container lifecycle (run, stop, remove)
- Image management
- Health checks
- Log streaming

### Odysseus::Caddy::Client

Caddy reverse proxy management:
- Dynamic upstream configuration
- Zero-downtime routing updates
- TLS certificate management

### Odysseus::Deployer::Executor

Deployment orchestration:
- Build and distribute images
- Zero-downtime container replacement
- Health check verification
- Automatic rollback on failure

### Odysseus::Secrets::EncryptedFile

Encrypted secrets management:
- AES-256-GCM encryption
- Environment variable injection
- Secure key management

## License

MIT
