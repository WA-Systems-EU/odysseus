# TODO list

Working list for getting Odysseus to a public 1.0. Grouped by what blocks a
public release, what closes the gap with Kamal, and what comes after. Order
within each group is not fixed.

P0 is done apart from CI and the templates, both waiting on a decision about
where the public repo lives. P1 is the next thing to prioritise.

## P0 — blocks going public

Done, on trunk:

- [x] **AWS ASG remnants.** Removed from both READMEs. The parsing hook and the
      `HostProviders` `aws:` branch are deliberately kept: they are the contract
      `odysseus-sail-aws-asg` consumes, and that gem has passing specs against
      them. The docs come back when plugin loading lands (P1) and a user can
      actually reach the feature.
- [x] **Charm mode docs.** Removed. Charm/gum was real in 0.2.0 and replaced by
      `CLI::UI` in 0.3.0; only the README still believed in it.
- [x] **`ratatui_ruby`.** Dropped from the gemspec.
- [x] **Version drift.** `Odysseus::VERSION` deleted;
      `Odysseus::Core::VERSION` and the new `Odysseus::CLI::VERSION` are the
      single sources, read by the gemspecs.
- [x] **`odysseus version` / `--version`.** Reports CLI, core and ruby versions
      before any config is loaded.
- [x] **Changelogs.** Both written from git history and the built gems, and
      `changelog_uri` now points at files that exist.
- [x] **CONTRIBUTING.md**, with the release process. Issue/PR templates still
      pending a decision on the repo host.
- [x] **CLI tests.** Harness plus 49 examples: subprocess coverage of dispatch
      and exit codes, unit cover of the commands against a doubled executor, and
      the UI's secret redaction.
- [x] **`validators/config.rb` and `sails.rb` specs.** 45 examples, each checked
      against a deliberate mutation of the code under test.
- [x] **`rake` passes** in both gems. Metrics debt is recorded in
      `.rubocop_todo.yml` per gem rather than hidden in the main config.

Also fixed along the way, unplanned:

- [x] The CLI gem shipped **no licence file** — `spec.files` looked for
      `LICENSE` while the file is `LICENSE.txt`.
- [x] The CLI's dependency on core was `~> 0.2`, which allowed installing a core
      without the deploy fixes it relies on. Now `~> 0.3, >= 0.3.2`.
- [x] `required_ruby_version` was `>= 3.0` in the CLI against core's `>= 3.2.0`,
      which could never have resolved.
- [x] The CLI lockfile still pinned `odysseus-core 0.1.0` and a `pastel`
      dependency the gemspec had dropped.

Still open:

- [ ] **CI.** Deferred: where the public repo will live is undecided. Both
      suites must be run locally until then, and CONTRIBUTING says so.
- [ ] **Issue and PR templates**, once the host is chosen.
- [ ] **`# frozen_string_literal: true`.** Missing in 36 core files. RuboCop can
      add it, but that is an unsafe correction — a literal mutated in place
      starts raising inside someone's deploy — so it needs an audit of string
      mutation first. The cop is disabled with that note.

## P1 — base features missing compared to Kamal

The gaps a Kamal user hits first. These need prioritising — roughly in the order
we'd feel their absence.

- [x] **`rollback`.** `odysseus rollback [VERSION]` and `--list` ship, reusing
      the deploy path so health gating and proxy handling are shared with
      `deploy`. A fleet pre-flight requires the target image on every host
      before any host is touched. **Verified on a real host 2026-08-13**, which
      the specs could not do: no unit test proves the deploy path accepts a tag
      it did not build.
- [x] **Retention/pruning of the images that pile up on hosts.** `deploy`
      prunes each host's superseded image versions once all of that host's
      roles are deployed, keeping `retain_versions` (default 5) and never a
      version a container still references. `rollback` deliberately does not
      prune. A git-notes trail for who-deployed-what is a separate future plan
      and stays open.
- [ ] **Deploy locks.** Nothing stops two people (or a person and CI) deploying
      at once and interleaving container swaps, and the same is true of a
      rollback racing a deploy or another rollback. Kamal: `kamal lock`.
- [ ] **Plugin (sail) loading.** `Sails` and the host-provider registry both
      raise "is the gem loaded?", but nothing ever loads a sail:
      `odysseus-sail-rolling` self-registers on `require` and the CLI only
      requires `odysseus`. With a `gem install`-ed CLI there is no Gemfile to do
      it, so `deploy.strategy: rolling` and `aws:` are unreachable for any end
      user. Needs a `plugins:`/`require:` key in deploy.yml or discovery of
      installed `odysseus-sail-*` gems.
- [ ] **Finish registry support.** The local half exists — build, `docker login`,
      `docker push`, and `Executor#uses_registry?` switching distribution — but no
      deploy target ever logs in, and `WebDeploy`/`JobDeploy` never call
      `Docker#pull`; they rely on `docker run`'s implicit pull. So registry mode
      works for public images and fails for a private one, which is the case
      anyone would actually use. Both READMEs document it as a first-class
      alternative to pussh. Needs: host-side login using the configured
      credentials (from the encrypted secrets file, not deploy.yml), an explicit
      pull step so a failure is attributable, and logout afterwards so
      credentials do not linger in the host's docker config. pussh covers a small
      team well enough that this is not release-blocking, but it is the next
      real gap.

- [ ] **Multiple destinations/environments.** One `deploy.yml` per project, no
      overlay. Kamal: `-d staging` with `deploy.staging.yml`.
- [ ] **Deploy hooks.** No pre-build / pre-deploy / post-deploy hooks, so
      migrations, notifications and CI gating have nowhere to live.
- [ ] **Multi-host failure semantics.** `deploy_all` walks hosts sequentially
      and a failure on host 2 leaves host 1 on the new version with no unwind.
      `rollback_all` has the same gap once past its pre-flight: the pre-flight
      only removes the most common cause, a missing image, not the possibility
      of a host failing mid-roll for some other reason. Needs a decision: fail
      fast and leave a mixed fleet, roll back the hosts already done, or deploy
      in batches. Related: parallel host deploys.
- [ ] **`audit`.** No record of who deployed what, when.
- [ ] **Server bootstrap (`setup`).** Target hosts must already have Docker;
      nothing installs or verifies it.
- [ ] **App lifecycle commands.** No `redeploy`, `app start`/`stop`, `details`,
      or `proxy reboot`.
- [ ] **`retain_containers` equivalent.** Cleanup keeps a hardcoded 2 old
      containers (`cleanup_old_containers(keep: 2)`); not configurable.
- [x] **Rename `accessories` to `dependencies`.** Done 2026-08-13. `services:`
      was rejected because `deploy.yml` already has `service:` and `servers:`.
      The old key and the old `odysseus accessory` verb both still work, the
      verb printing a notice; remove them a release after this one.
- [ ] **Drop the `accessories:` key and the `accessory` verb**, one release
      after the rename ships. Both are accepted for back-compat today:
      `Config::Parser#normalize` falls back to `config['accessories']`, and
      `bin/odysseus`'s `DEPENDENCY_ALIASES` includes `accessory`. Update the
      seven app `deploy.yml` files before removing them.

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
      command. The deploy path now uses a 0600 `--env-file`; these did not
      follow.
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
- [ ] RuboCop's `Style/FormatStringToken` rewrote curl's `%{http_code}` to
      Ruby's `%<http_code>s` during the lint sweep, which would have broken the
      health check and silently disabled the Caddy API error handling. Specs now
      pin curl's syntax and the cop is off, but the shell strings scattered
      through the clients are worth extracting somewhere they cannot be mistaken
      for Ruby.
- [ ] odysseus-cli's spec suite never sets `config.warnings = true`, unlike
      `odysseus-core/spec/spec_helper.rb:24`, so Ruby warnings in CLI specs go
      unnoticed.
- [ ] `DependencyManager#status_on` calls `list_status` once per dependency/host
      pair where once per host would do — O(N²) docker calls for N dependencies.
      Deliberately left as-is for now: restructuring it to call `list_status`
      once per host would change the CLI's row order.
- [ ] `rollback --list`'s `Image` column holds `present`/`missing`; it would
      read better as `Available`.
- [ ] `rollback --list` should mark the running release in the table itself —
      an arrow or dot on that row — instead of only naming it in the `Serving`
      line above the table. Reported from real use: scanning IDs to work out
      which one is live is the wrong job to give a reader mid-incident. Note
      this reverses a call I made during the rollback plan: the original design
      had a `Serving` column carrying `←`, and I dropped it as a column
      repeating one value down every row. A marker on one row is the better
      shape — it costs no width and answers the question at a glance. Fold the
      `Available` rename above into the same change.
- [ ] `odysseus-cli/bin/odysseus`'s positional-VERSION extraction for `rollback`
      (`options[:version] = command_args[0] if command == 'rollback' && ...`)
      has no regression test. It is awkward to cover offline because the
      version is only echoed back after `rollback_plan` has connected to
      hosts. Honest options: move the extraction somewhere `cli_spec` can
      reach it directly, or accept the gap.
- [ ] `Docker::Labels.service_for` is the single source of truth for reading a
      role's `odysseus.service` label back, but not for writing it:
      `WebDeploy` (`web_deploy.rb:139`) and `JobDeploy` (`job_deploy.rb:28`)
      still build the value inline. Read and write can therefore still drift —
      which is exactly the bug the whole-branch review caught in the rollback
      survey. Route both writers through it.
- [ ] A dependency and a server role sharing a name collide: both
      `dependencies.db` and `servers.db` produce the container service label
      `myapp-db`, so each would see the other's containers. Nothing validates
      against it.
- [ ] Zeitwerk's `eager_load` raises on `lib/odysseus/core/version.rb`, which
      defines `VERSION` where the path implies `Version`. Nothing calls
      `eager_load` today — the gemspec requires that file explicitly, so the
      constant resolves — but it would break anyone booting the gem eagerly.
