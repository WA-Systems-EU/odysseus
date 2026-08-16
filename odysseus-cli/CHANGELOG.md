# Changelog

All notable changes to odysseus-cli are documented here.

Entries for 0.3.0 and earlier were reconstructed from git history and the built
gem artifacts, so they are summaries rather than contemporaneous notes.

## [Unreleased]

### Fixed
- `odysseus app exec|shell|console` now inject `env.secret` as well as
  `env.clear`. They injected the clear values alone, so the README's own
  example — `odysseus app exec web1 --command "rails db:migrate"` — started a
  container with no `DATABASE_URL` while the container deployed seconds earlier
  had one. Both orchestrators had always injected both; these three never did.
  The environment is now built by the same `Core::Environment` the deploy paths
  use, so a secret resolves from the encrypted file when one is configured and
  from the host's own environment otherwise, exactly as a deploy resolves it.
- A relative `secrets_file` is resolved against the directory holding the
  `deploy.yml` these commands were pointed at, not the working directory, which
  is the rule deploys already followed.
- `odysseus app shell|console` pass the environment to docker with `--env-file`
  instead of `-e KEY=VALUE`. The values were in the command string these
  commands run over ssh, so `ps` on the deploy target showed them to every user
  on the box; now only the file's path is. The file is `0600`, is held open for
  the whole session and is removed when the session ends, however it ends —
  including when the ssh connection it was written over has died while the
  session sat idle, which is removed over a fresh connection. Two cases still
  leave it on the host: the `odysseus` process being killed outright
  (`SIGKILL`, or the machine going down), where no cleanup can run at all, and
  a host that is unreachable when the session ends, where the removal has
  nowhere to go. The file is `0600` in `/var/lib/odysseus/env`, which is `0700`,
  so no other user on the box can read it, but nothing comes back for it.
  `app exec` reaches the same place through `run_once`, which writes an env
  file of its own — see odysseus-core's changelog.
- `odysseus dependency exec|shell` are unchanged: they `docker exec` into an
  already-running dependency, which carries the environment it was booted with.
- `odysseus app exec|shell|console` now take `--role` (default `web`) and look
  the container up by the label that role actually carries. They asked for the
  bare service name, which only the web role wears: on a jobs host they
  reported `No running container for myapp` while `myapp-jobs` containers were
  running, and for a service with no web role at all they could not work on any
  host, with no workaround. The `app` parser had no `--role` either, so naming
  one raised an `OptionParser::InvalidOption` backtrace.
- The not-found message from those commands now names the role, the
  `odysseus.service` label it searched for and the `--role` option, and lists
  the roles in the config. It does not search other roles: running your command
  against a role you did not name would be worse than being told what to type.
- `odysseus logs` and `odysseus dependency logs` read stopped containers as
  well as running ones. They asked `docker ps` without `-a`, so the container
  that had just exited — the one you want the logs of — was invisible, and they
  reported `No running containers found` and exited **0** while `docker logs`
  on that container would have worked. Deploys keep the previous two
  containers, so this was routine rather than an edge case.
- Those two commands now exit non-zero when there is no container at all: a
  request for logs that produced none is a failed request, not a success. When
  the only match is stopped they say so, and name the container, rather than
  streaming a dead container's logs and leaving you to wonder why it ends.
- Both of those messages go to **stderr**. `odysseus logs web1 > app.log` is
  the command most likely to be redirected or piped into something that parses
  what it gets, and a line about the logs does not belong inside them. The
  notice still reaches the terminal of whoever ran the command. Every other
  command writes where it always did.
- `odysseus app shell|console` and `odysseus dependency shell` now exit
  non-zero when the session fails. They discarded `system`'s return value, so a
  refused ssh, a missing image or a failed `docker run` all reported success.
- The same three quote what they put in the command they run. Values were
  interpolated raw into a string that passes through two shells, so ordinary
  `env.clear` values broke them: a value containing a space made docker read
  the wrong token as the image name, and an apostrophe (`SMTP_FROM: "Bob's
  App"`) unbalanced the quoting — an odd number left `sh: unexpected EOF` and
  nothing running (reported as success, per the bug above), an even number
  rebalanced the quotes and ran the text between them through the *local*
  shell. An SSH key path containing a space failed the same way.
- `odysseus app console --cmd` is split into words the way a shell would, so
  `--cmd "rails c"` still reaches docker as two arguments, and a `--cmd` whose
  own quoting cannot be read is reported instead of being passed on.

### Changed
- `bin/odysseus`'s dispatch table no longer lists `dependency`, `app` and
  `secrets`. Their entries named methods the CLI has never had
  (`dependency_dispatch`, `app_dispatch`, `secrets_dispatch`); the subcommand
  guards intercept those verbs first, so nothing changes today, but the entries
  would have turned any reordering of a guard into a `NoMethodError` backtrace.
  The suite now runs every verb the help lists.

## [0.6.0] - 2026-08-15

### Changed
- `odysseus validate` now loads `plugins:`/`sails:` before checking the rest
  of the config, so it catches a plugin gem that is not installed instead of
  only discovering the gap at deploy time. It will fail on a machine that
  does not have the gem, where it passed before. See odysseus-core's
  changelog for the loading mechanism itself.
- Requires odysseus-core `~> 0.6.0`. The dependency was `~> 0.5.0`, which
  excludes 0.6.0 outright, so the two gems could not resolve together at all.
- The README documents dynamic ASG hosts again, now that `plugins:` makes them
  reachable. The example it previously carried could not have parsed: it showed
  an `aws:` role with no `hosts:` key, which every role requires.

## [0.5.0] - 2026-08-13

### Changed
- Requires odysseus-core `~> 0.5.0`. The previous `~> 0.4.4` constraint
  excludes 0.5.0 outright, so this is not a tightening but a necessary move:
  without it the two gems cannot resolve together at all.
- `odysseus deploy` now prunes old images on each host, keeping the newest
  `retain_versions` (default 5). See odysseus-core's changelog for what is
  protected from removal.

## [0.4.4] - 2026-08-13

### Changed
- Requires odysseus-core `~> 0.4.4`. The dependency was `~> 0.4.3`, which
  allowed installing a core whose `Executor` still named its six methods
  `deploy_accessory`, `boot_accessories` and so on — all of which the dependency
  commands call under their new names, so they would have failed with a
  NoMethodError rather than a resolvable error.
- `odysseus accessory` is now `odysseus dependency`, with `dep` accepted as
  shorthand. The old verb still works and prints a notice naming the
  replacement, because a silent alias never gets migrated away from; it will be
  removed in a later release. The `accessories:` key in deploy.yml is likewise
  now `dependencies:`, with the old key still accepted — see odysseus-core's
  changelog for why nothing on a host changes when you rename it.
- Help text, subcommand output and the `Dependency name required` error read
  "dependency" throughout.

## [0.4.3] - 2026-08-13

### Added
- `odysseus rollback [VERSION]`, returning every role on every host to a
  previously deployed version. With no VERSION, the target is the most recent
  version in the hosts' deploy logs that is not already serving and whose image
  is still present everywhere. Refuses, changing nothing, when any host lacks
  the image.
- `odysseus rollback --list`, showing per host: every version deployed, when,
  by whom, from which commit, whether the image is still present, and what is
  serving. Reads only the hosts, so it works without a git repository.

### Changed
- Requires odysseus-core `~> 0.4.3`. The dependency was `~> 0.4.2`, which
  allowed installing a core without `Executor#rollback_plan`, `#rollback_all`
  or `#version_survey` — all of which `rollback` calls, so the command would
  have failed with a NoMethodError rather than a resolvable error.

### Fixed
- `odysseus accessory status` now works. It has raised `NoMethodError` since
  before the subcommand shipped in 0.2.0; see odysseus-core's changelog for the
  root cause and fix.

### Internal
- Rollback commands moved out of the main `CLI` class into
  `Odysseus::CLI::RollbackCommands`, to keep the class under its existing size
  limit without changing its public API.

## [0.4.2] - 2026-08-13

### Changed
- `deploy`, `build` and `pussh` no longer default `--image` to the `latest`
  tag; the tag now defaults to the git commit being deployed, and is required
  outside a clean git repository.
- `status` reports the version, ref and deploy time of each container.
- `app exec`, `app shell` and `app console` run the version that is currently
  serving instead of `:latest`.
- Requires odysseus-core `~> 0.4.2`. The dependency was `~> 0.4`, which allowed
  installing a core without `Executor#deploy_version` or `Docker::Labels` — both
  of which these commands now call, so `deploy` would have failed with a
  NoMethodError rather than a resolvable error.

## [0.4.1] - 2026-08-12

Released in lockstep with odysseus-core 0.4.1, which fixes the Caddy TLS
policy update. No changes to the CLI itself.

## [0.4.0] - 2026-08-12

### Added
- `odysseus version` and `--version`, reporting the CLI, odysseus-core and ruby
  versions. Answered before any config is loaded, so it works without a
  deploy.yml or a reachable server.
- `Odysseus::CLI::VERSION`, so the gem version has one source of truth instead
  of being hardcoded in the gemspec.
- A test suite: RSpec, `.rspec` and a `rake` default task. Argument dispatch and
  exit codes are covered by running the real executable in a subprocess, the
  commands are unit-tested against a doubled executor, and the redaction of
  secrets from streamed output is pinned.
- RuboCop, sharing odysseus-core's configuration.

### Changed
- Requires odysseus-core `~> 0.4`. The dependency was `~> 0.2`, which allowed
  installing a core old enough to lack the deploy fixes the CLI relies on.
- Requires Ruby >= 3.2.0, matching odysseus-core. The gemspec asked for >= 3.0,
  which could not have worked.
- Licensed under MIT. The gemspec previously said LGPL-3.0-only while the README
  said MIT.
- `CLEAN_MESSAGES` is a `private_constant`; it sat after a `private` modifier,
  which does nothing for constants.
- Development dependencies live in the Gemfile only, as in odysseus-core; the
  gemspec declared rspec and pry-byebug a second time.

### Fixed
- The gem now ships its license file. `spec.files` looked for `LICENSE` while
  the file is `LICENSE.txt`, so published gems contained no license text.

### Removed
- The `ratatui_ruby` dependency. Nothing in the CLI required or referenced it —
  it pulled a native extension into every install for nothing.
- Documentation for Charm mode (`--charm`, `ODYSSEUS_CHARM=1`, `gum`), removed
  from the code in 0.3.0 but left in the README, and for AWS Auto Scaling Group
  hosts, which moved to a sail gem nothing currently loads.

## [0.3.0] - 2026-04-04

### Changed
- Rewrote terminal output as numbered steps with animated spinners resolving to
  ✓/✗, rendered by `CLI::UI`, replacing the gum-backed Charm mode. `--debug`
  (or `ODYSSEUS_DEBUG=1`) switches to verbose plain text.
- Secret values are redacted from streamed output via `RedactingIO`.

## [0.2.0] - 2025-12-30

### Added
- Charm TUI mode (`--charm`, `ODYSSEUS_CHARM=1`) built on gum, for styled
  headers, spinners, tables and confirmations. Superseded in 0.3.0.
- `secrets` subcommands: generate-key, encrypt, decrypt, edit.
- `accessory` subcommands: boot, boot-all, remove, restart, upgrade, status,
  logs, exec, shell.
- `pussh` command for pushing images to hosts over SSH without a registry.

## [0.1.0] - 2025-12-21

- Initial release: deploy, build, status, containers, logs, cleanup, validate,
  and the `app` subcommands.
