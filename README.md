# Odysseus - Self-Hosted Deployment Tool

Kamal config format + SSH + Docker + Caddy + Unregistry for simple, pragmatic deployments.

## Structure

- `odysseus-core/` - Core gem with config parsing, generators, deployers
- `odysseus-cli/` - CLI tool for deployments
- `odysseus-web/` - (Future) Hanami web UI
- `odysseus-bot/` - (Future) Slack/Discord bot

## Quick Start

```bash
# Install dependencies
cd odysseus-core
bundle install
bundle exec rspec

# Test CLI
cd ../odysseus-cli
bundle install
./bin/odysseus validate --config ../odysseus-core/spec/fixtures/deploy.yml
```

## Deploy

```bash
odysseus deploy app1.example.com --image myapp:v1.2.3
odysseus generate docker-compose
odysseus generate caddyfile
```

## A message

OpenSource is great, you can get inspiration from projects, do something different that fit your needs and turn a page at the same time.
-- T.R^3