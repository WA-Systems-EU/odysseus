# Contributing to Odysseus

Thanks for taking an interest. Odysseus deploys other people's production
systems, so the bar for changes is "would I want this running my deploy at 2am".
This guide is about how to work in the repo; the [Code of
Conduct](CODE_OF_CONDUCT.md) covers how we work with each other.

## Repository layout

This repo holds two gems that are released together:

| Path | Gem | What it is |
| --- | --- | --- |
| `odysseus-core/` | `odysseus-core` | Config parsing, SSH and Docker clients, Caddy integration, orchestrators |
| `odysseus-cli/` | `odysseus-cli` | The `odysseus` executable and its terminal UI |

Deploy strategies and host providers live outside this repo as **sails** —
separate gems that register themselves with `Odysseus::Sails` or
`Odysseus::HostProviders` when required (for example `odysseus-sail-rolling`,
`odysseus-sail-aws-asg`).

## Getting set up

Ruby 3.2 or newer. Each gem has its own bundle:

```bash
cd odysseus-core && bundle install
cd ../odysseus-cli && bundle install
```

`odysseus-cli` resolves `odysseus-core` from a path, so changes in core are
picked up without reinstalling.

To run your working copy of the CLI:

```bash
cd odysseus-cli
bundle exec ruby -Ilib bin/odysseus version
```

## Running the tests

```bash
cd odysseus-core && bundle exec rspec
cd ../odysseus-cli && bundle exec rspec
```

`rake` in `odysseus-core` runs RSpec and RuboCop together.

There is **no CI yet** — where the public repo will live is still being
decided — so please run both suites locally before opening a pull request, and
say in the PR that you did.

The specs never touch a real server. `odysseus-core` mocks the SSH connection;
`odysseus-cli` doubles the executor, and its `bin_spec` runs the real
executable in a subprocess but only along paths that stop at argument handling.
A test that would open a network connection is a test that needs redesigning.

## How we expect changes to arrive

**Write the test first, and watch it fail.** A test written after the code
proves only that the code does what it does. If you're fixing a bug, the failing
test should reproduce the bug before you touch the fix.

If you're adding tests to code that has none, that's welcome — but check they
have teeth. Break the code deliberately and confirm the new test fails. Several
specs in this repo were verified that way and it is worth the two minutes.

Other things we care about:

- **Don't let a failure pass silently.** Most of the bugs found in this codebase
  had the same shape: a return value ignored, an exit status unread, an HTTP
  error swallowed. If an operation can fail, the caller must find out.
- **Secrets never reach a command line.** They go through env files with `0600`
  permissions. `ps` on a deploy target must not reveal a customer's database
  password.
- **Match the surrounding code.** Same comment density, same naming, same idiom.
  A patch that reformats untouched lines is hard to review.
- Keep a commit to one idea, and write the message so the *why* survives: what
  broke, what the consequence was, what changed.

## Pull requests

1. Branch from `trunk`.
2. Make the change, with tests.
3. Run both suites.
4. Update the relevant `CHANGELOG.md` under `## [Unreleased]`.
5. Open the PR describing what breaks if the change is wrong.

Documentation counts as part of the change. A README that promises a feature the
code doesn't have is a bug — we have shipped that mistake before.

## Releasing

Both gems are versioned in lockstep and released together.

1. Bump `odysseus-core/lib/odysseus/core/version.rb` and
   `odysseus-cli/lib/odysseus/cli/version.rb`. These are the only places a
   version is written; the gemspecs read them.
2. If core's version changed in a way the CLI depends on, raise the floor in
   `odysseus-cli.gemspec` (`spec.add_dependency "odysseus-core", ...`).
3. Move `## [Unreleased]` to the new version in both changelogs, with the date.
   Behaviour changes are a minor bump, not a patch.
4. Run both test suites.
5. Build and check what actually goes in the gem, including the licence:
   ```bash
   cd odysseus-core && gem build odysseus-core.gemspec
   cd ../odysseus-cli && gem build odysseus-cli.gemspec
   tar -xOf odysseus-cli-*.gem data.tar.gz | tar -tzf -
   ```
6. `gem push` core first, then the CLI, so the dependency resolves.
7. Tag the release.

## Reporting a bug

Include the output of `odysseus version`, the command you ran, and your
`deploy.yml` with secrets removed. `--debug` (or `ODYSSEUS_DEBUG=1`) prints
every command Odysseus runs, with secret-looking values redacted — that output
is usually what we need.

## Security

Please don't open a public issue for a vulnerability. Email
thomas@imfiny.com instead.

## Licence

Odysseus is MIT licensed, and contributions are accepted under the same terms.
