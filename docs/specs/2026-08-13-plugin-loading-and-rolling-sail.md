# Plugin loading, and bringing the rolling sail current

Status: designed 2026-08-13, not yet implemented.

## Problem

`Odysseus::Sails` and `Odysseus::HostProviders` are registries that nothing ever
populates. Both raise "is the gem loaded?" when a config names a strategy or host
provider, and that error fires for every user, because nothing loads a plugin.
`odysseus-sail-rolling` self-registers at the bottom of its entry file, and
`odysseus-sail-aws-asg` does the same — but the CLI only requires `odysseus`, and a
`gem install`-ed CLI has no Gemfile to require anything else. So
`servers.<role>.deploy.strategy` and the `aws:` host hook are unreachable for any end
user, while both READMEs describe them.

The rolling sail is not a stub. It is 425 lines that drain a container from Caddy,
wait out `drain_timeout`, stop with a grace period, start the replacement, gate on an
HTTP health check with a success threshold, and re-add to the proxy — one named slot
at a time, aborting on the first failed slot and reporting how many were replaced. It
passes 17 examples against core 0.5.0 and its orchestrator satisfies the current sail
contract exactly. The only thing missing is the `require`.

But it was written against core 0.2 and has silently fallen behind through four
releases. Being a satellite gem is what let it drift: nothing forced it to move when
core did.

## Design

### Loading plugins

A new top-level key, accepted under either name:

```yaml
plugins:
  - odysseus-sail-rolling

servers:
  web:
    deploy:
      strategy: rolling
```

`sails:` is accepted as an alias, matching the project's own vocabulary and the gem
names. **Both keys present is an error**, not a silent preference: a config with two
contradictory lists should say so rather than pick.

A new `Odysseus::Plugins` module owns loading, with one public method,
`Plugins.load!(names)`. Each name is `require`d directly — `odysseus-sail-rolling`
ships `lib/odysseus-sail-rolling.rb`, so requiring the gem name reaches the entry file
that ends in `Sails.register(:rolling, …)`. One mechanism covers both registries,
since the ASG gem self-registers into `HostProviders` the same way.

`Config::Parser#parse` gains one step, and the order is the whole point:

```
load_yaml → Plugins.load!(raw['plugins'] || raw['sails']) → validate! → normalize
```

Loading must precede `validate!`, because the validator is what asks whether `rolling`
is registered. Reading the list straight off the raw YAML breaks that cycle without
parsing the file twice.

**Alternatives rejected.** Auto-discovering installed `odysseus-sail-*` gems needs no
config, but makes the same `deploy.yml` behave differently depending on ambient gem
state, with no way to opt out of an installed sail — for a deploy tool, a config that
works on one machine and fails on another is worse than an explicit list. Relying on
the app's Gemfile to require the sail is what is implicitly assumed today, and is
exactly the gap: it only works when odysseus is a bundled dependency rather than an
installed CLI.

**`plugins:` validates itself.** Every other key is shape-checked by
`Validators::Config`, but `plugins:` is consumed before the validator runs, so
`Plugins.load!` raises `ConfigError` for a malformed list itself. This asymmetry is a
consequence of the ordering, not an oversight.

**Trust.** Core will `require` a string read from a config file. `deploy.yml` already
runs arbitrary docker commands as root on the target hosts, so this is not a new trust
boundary — but it is a more visible one and is stated here rather than left implicit.

**`odysseus validate` will load plugins**, because it parses. That makes validate a
real pre-flight: it now catches a missing plugin gem, which it cannot today. The cost
is that validate fails on a machine without the sail installed, where it passes now.
That is the correct trade.

### A shared versioning seam

The sail sets `odysseus.version` to a timestamp, which is the pre-0.4.2 behaviour that
deploy versioning replaced, and passes no `labels:` at all — so no `odysseus.git_ref`
and no `odysseus.deployed_at`. With the sail in play, `status` shows a timestamp rather
than a commit, and **retention's in-use guard goes blind**: `versions_in_use` collects
timestamps while `deploys.log` records SHAs, so they never match and nothing is
excluded as in use. Docker's own refusal still prevents deleting a running image, but
the three independent guards retention is designed around collapse to one.

Copying `WebDeploy`'s current logic into the sail would reset the same clock. Instead,
extract what `WebDeploy` and `JobDeploy` already duplicate — `deploy_version_tag` and
`version_labels` — into a core mixin, `Odysseus::Core::DeployVersioning`, included by
all three. There is precedent: the sail already includes
`Odysseus::Core::VolumeNamespacer`.

This turns version identity into a tested, public seam rather than a convention each
orchestrator re-implements. Any sail including it gets `odysseus.version`,
`odysseus.git_ref` and `odysseus.deployed_at` right by construction, which is what
makes `status`, `rollback` and retention see its containers.

### The rolling sail's other fixes

**Label non-web roles correctly.** The sail uses the bare service name in all five
places it labels or queries containers, never `Docker::Labels.service_for(service:,
role:)`. A `jobs` role under rolling labels its containers `myapp` instead of
`myapp-jobs`, so `status`, `rollback` and retention all miss them — the same defect
that blocked the retention branch at final review.

**Do not pull when there is no registry.** `@docker.pull(image)` is unconditional, so
rolling is broken under pussh, which is the default distribution: there is no registry
to pull from. Neither `WebDeploy` nor `JobDeploy` pulls at all; they rely on `docker
run`'s implicit pull. Make the pull conditional on registry configuration.

**Fix the gemspec constraint.** `odysseus-core ~> 0.2` becomes `~> 0.5`.
(**Corrected 2026-08-16:** this paragraph claimed `~> 0.2` "excludes 0.5.0
outright" and that the suite passed "only through the local `path:` override".
Both wrong — `~> 0.2` is `>= 0.2, < 1.0` and admits 0.5.0 fine. The real reason
to tighten it is the mixin: the sail now includes `Odysseus::Core::DeployVersioning`,
so a constraint that admits a core without it resolves and then fails with a
`NameError` at load. On release the constraint became `~> 0.6` for exactly that
reason — 0.5.0 has no such mixin.)

Container naming stays slot-based (`<service>-web-1`). Stable slot identity is the
point of a rolling deploy, and `status` reports the version from the label rather than
the name.

### Aligning `dependencies:` and `accessories:`

`Config::Parser#normalize` currently reads `config['dependencies'] ||
config['accessories']`, silently preferring the new key when both are present. That is
the same ambiguity `plugins:`/`sails:` is being designed to reject. Both present
becomes a `ConfigError` too, for consistency.

## Backwards compatibility

A config with no `plugins:` key behaves exactly as today: the registries stay empty and
naming a strategy still fails with the existing error. Nothing about the default deploy
path changes.

The sail's fixes change the labels its containers carry. A host currently running
rolling-deployed containers would see the next deploy label them differently — but
nothing is running rolling anywhere, because it has never been loadable.

## Error handling

| Situation | Behaviour |
| --- | --- |
| Both `plugins:` and `sails:` present | `ConfigError` naming both keys |
| `plugins:` is not an array of strings | `ConfigError` from `Plugins.load!` |
| A named gem is not installed | `ConfigError` naming the gem, suggesting `gem install <name>` |
| A gem loads but registers nothing | The existing "is the sail plugin gem loaded?" error, now accurate |
| `strategy:` names an unregistered sail | Unchanged `ConfigValidationError` |
| Both `dependencies:` and `accessories:` present | `ConfigError` naming both keys |

Every one fails before a host is contacted.

## Testing

`Plugins.load!` is tested against a **real file on `$LOAD_PATH`** that really registers
a fake sail — not a stubbed `require`. This follows the discipline the deploy
versioning spec set for `VersionResolver`, which is tested against real temporary git
repositories because stubbing the command under test only asserts that the stub was
called. Stubbing `Kernel#require` would prove nothing about whether a gem registers.

The `DeployVersioning` extraction is verified twice over: its own specs, and the
existing `WebDeploy` and `JobDeploy` suites passing unchanged, which is what
demonstrates the extraction preserved behaviour.

The sail's four fixes get specs in the sail's own repository, whose Gemfile already
points at local core via `path:`, so it exercises the new mixin immediately.

Every new spec is checked against a deliberate mutation of the code under test, as
`CONTRIBUTING.md` requires.

## Implementation

Two repositories, two branches:

1. **`Odysseus`** — `Odysseus::Plugins`, the parser ordering, the `DeployVersioning`
   mixin, the `dependencies:`/`accessories:` alignment, docs.
2. **`odysseus-sail-rolling`** — the four fixes above.

The sail cannot be released until core is, because its gemspec will require `~> 0.5`.

## Known limitations

- **This ships unexercised on a real host.** Rollback and retention were both proven
  with a real deploy to dedalus-prod, which caught defects no double could. Rolling
  will not be, because there is no near-term need for it. The READMEs must say so
  rather than imply parity with the built-in strategies.
- **`odysseus-sail-aws-asg` is untouched by this work**, though it will load through the
  same `plugins:` mechanism. **Correction to an earlier draft of this spec**, which
  claimed the gem could not `bundle install` and that its suite could not run: that was
  wrong. Once bundled, its suite passes 14 examples. The original observation came from
  running `bundle exec rspec` in a checkout that had never been `bundle install`ed, and
  reported a broken gem where the truth was an unbundled directory.
  **A second correction, 2026-08-16.** The paragraph above then claimed its
  `odysseus-core ~> 0.3` constraint "excludes 0.5.0". That was also wrong:
  `~> 0.3` means `>= 0.3, < 1.0`. So the correction of the first false claim
  about this gem contained a second one. Nothing is wrong with its constraint;
  what it still lacks is any exercise through `plugins:`. Recorded in `TODO.md`.
- **One plugin does not prove an architecture.** If a second strategy never
  materialises, folding rolling into core and retiring the gem stays the better end
  state. This design keeps the gem because it is close to usable and may be tried
  soon, not because the plugin system has earned its place yet.
