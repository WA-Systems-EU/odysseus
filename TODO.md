# TODO list

Working list for getting Odysseus to a public 1.0. Grouped by what blocks a
public release, what closes the gap with Kamal, and what comes after. Order
within each group is not fixed — pick from the top of P0 first.

## P0 — blocks going public

Housekeeping that would embarrass us in front of a first-time user.

- [ ] **Remove the AWS ASG feature remnants.** The provider was deleted in
      7bd4ffc but `Config::Parser#parse_aws_config` still parses an `aws:` block
      and `HostProviders.build` raises pointing at `odysseus-sail-aws-asg`, a gem
      nobody can install. Both READMEs still document ASG as a supported feature
      with a config example. Either finish the plugin path (see plugin loading
      below) or drop the parsing and the docs.
- [ ] **Remove the Charm mode docs.** `odysseus-cli/README.md` documents a
      `--charm` flag, `ODYSSEUS_CHARM=1`, and installing `gum`. None of it
      exists; the CLI renders its own spinners in `cli/ui.rb`.
- [ ] **Drop the `ratatui_ruby` dependency.** `odysseus-cli.gemspec` requires
      `ratatui_ruby ~> 1.4` and nothing requires or references it — a native
      extension pulled in for nothing on every install.
- [ ] **Fix the version drift.** `Odysseus::VERSION` is 0.1.0 while
      `Odysseus::Core::VERSION` is 0.3.2; `odysseus-cli.gemspec` hardcodes 0.3.0.
      Pick one source of truth per gem and delete the other constant.
- [ ] **Add `odysseus version` / `--version`.** There is no way to ask the CLI
      what it is, which makes bug reports guesswork.
- [ ] **Maintain the changelog.** `odysseus-core/CHANGELOG.md` stops at "0.1.0
      Initial release" four releases ago, and the gemspec's `changelog_uri`
      points at `trunk/CHANGELOG.md`, which does not exist at the repo root.
- [ ] **Add CI.** No `.github/` and no pipeline: run `rspec` for both gems on
      push, plus `rubocop`. (Originally scoped as Buildkite — decide which.)
- [ ] **Add CONTRIBUTING.md.** Plus issue/PR templates and a documented release
      process. `CODE_OF_CONDUCT.md` already exists.
- [ ] **Test the CLI.** `odysseus-cli` has no spec directory, no `.rspec` and no
      Rakefile — 1,281 lines of argument parsing, `exit 1` paths, secrets
      subcommands and `system("ssh …")` shell-outs with zero coverage.
- [ ] **Spec `validators/config.rb` and `sails.rb`.** All of the config
      validation logic and the whole plugin registry are untested.
- [ ] **Get `rake` passing.** The default task is `spec + rubocop` and rubocop
      reports ~1,842 offenses across 37 files, so `rake` fails out of the box.
      Mostly autocorrectable; decide the house style and land it in one sweep.

## P1 — base features missing compared to Kamal

The gaps a Kamal user hits first. These need prioritising — roughly in the order
we'd feel their absence.

- [ ] **`rollback`.** The biggest one. There is no deployed-version tracking and
      no way back other than re-running `deploy` with an older tag by hand.
      Needs a record of what is running per host, then a reverse deploy.
- [ ] **Deploy locks.** Nothing stops two people (or a person and CI) deploying
      at once and interleaving container swaps. Kamal: `kamal lock`.
- [ ] **Plugin (sail) loading.** `Sails` and the host-provider registry both
      raise "is the gem loaded?", but nothing ever loads a sail:
      `odysseus-sail-rolling` self-registers on `require` and the CLI only
      requires `odysseus`. With a `gem install`-ed CLI there is no Gemfile to do
      it, so `deploy.strategy: rolling` and `aws:` are unreachable for any end
      user. Needs a `plugins:`/`require:` key in deploy.yml or discovery of
      installed `odysseus-sail-*` gems.
- [ ] **Multiple destinations/environments.** One `deploy.yml` per project, no
      overlay. Kamal: `-d staging` with `deploy.staging.yml`.
- [ ] **Deploy hooks.** No pre-build / pre-deploy / post-deploy hooks, so
      migrations, notifications and CI gating have nowhere to live.
- [ ] **Multi-host failure semantics.** `deploy_all` walks hosts sequentially
      and a failure on host 2 leaves host 1 on the new version with no unwind.
      Needs a decision: fail fast and leave a mixed fleet, roll back the hosts
      already done, or deploy in batches. Related: parallel host deploys.
- [ ] **`audit`.** No record of who deployed what, when.
- [ ] **Server bootstrap (`setup`).** Target hosts must already have Docker;
      nothing installs or verifies it.
- [ ] **App lifecycle commands.** No `redeploy`, `app start`/`stop`, `details`,
      or `proxy reboot`.
- [ ] **`retain_containers` equivalent.** Cleanup keeps a hardcoded 2 old
      containers (`cleanup_old_containers(keep: 2)`); not configurable.

## P2 — after the gap closes

- [ ] Secrets from external sources: OpenBao (self-hosted), AWS Secrets Manager.
- [ ] Static marketing site (see `odysseus-site`, `Odysseus-doc-site`).
- [ ] Web UI: Hanami, GitHub auth, list services / available images / currently
      deployed version, storage for deploy logs (see `odysseus-pro`).
- [ ] Canary and blue/green strategies as sails, alongside rolling.

## Known rough edges

Smaller findings worth fixing but not blocking anything.

- [ ] `Docker#run_once` and the CLI's `app shell`/`console`/`exec` still inline
      `-e KEY=VALUE` unquoted, so a clear env value containing a space breaks the
      command. Deploy-path env now goes through a 0600 `--env-file`; these paths
      did not follow.
- [ ] `use_tailscale: true` is hardcoded in both `Executor#connect_to_server` and
      the CLI, so every connection timeout suggests Tailscale troubleshooting.
- [ ] The Caddy client assumes a single `srv0` HTTP server and relies on the
      stock `caddy:2-alpine` Caddyfile having created it. A Caddy started with an
      empty config has no `srv0` and route writes would fail.
- [ ] `WebDeploy#internal_port_mapping` always returns nil — dead code.
- [ ] `logs` only ever reads the first container of a role, on one host.
- [ ] `drain_and_remove` sleeps a fixed 5s instead of waiting for connections to
      drain; `deploy.drain_timeout` is parsed but unused by `WebDeploy`.
- [ ] Root `.gitignore` ignores `**/deploy.yml`, so example configs cannot be
      committed for the docs.
