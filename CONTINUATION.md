# Continuation — `feat/registry-support`

Handoff note for picking this branch back up. Written 2026-11-10 at
`01b2b5f`. The full design and plan are in
`docs/specs/2026-10-23-registry-support-design.md` and
`docs/plans/2026-10-23-registry-support.md`; this file only says where things
stand.

## State

- Branch is pushed: `github/feat/registry-support` = local HEAD. Not merged;
  `trunk` is still at `af0d451` (Release cli 0.10.1), the branch's base.
- All seven plan tasks are implemented, plus a fix found in final review: the
  build step's push now resolves its login through the same
  `Registry::Credentials` instance as the deploy host's login (it used to read
  `registry[:password]` off the raw hash and push with an empty password for a
  `password_secret:`-only config).
- `bundle exec rake` is green in both gems as of this note:
  odysseus-core 833 examples / 0 failures, RuboCop clean (95 files);
  odysseus-cli 199 examples / 0 failures, RuboCop clean (15 files).
- Changes are recorded in `odysseus-core/CHANGELOG.md` under `[Unreleased]`,
  the registry entry in `TODO.md` (P1), and `odysseus-cli/README.md`.

## Not done — do not claim otherwise

- **Never run against a real private registry.** Every docker and SSH call in
  the suite is a double; the specs prove the commands are built correctly,
  not that registry mode works. The README's experimental warning stays until
  a real run (e.g. a private `ghcr.io` image to a test host) succeeds.
- **Sails can't pull from a private registry.** `build_orchestrator` withholds
  `registry_config_dir:` from a sail when it is nil; `odysseus-sail-rolling`
  (and any other sail) needs the keyword added to its constructor. Open in
  `TODO.md`.
- **The sail constructor contract has no test.** Open in `TODO.md`, next to
  the entry above.

## Next steps

1. Verify against a real private registry, then decide whether the README's
   experimental warning can be softened.
2. Open the PR from `feat/registry-support` into `trunk`.
3. Release core (the `[Unreleased]` entry) and bump the CLI's core dependency
   if it relies on this.
4. Then the sail keyword work, as its own change in the sail gems.

## Things to keep in mind

- The login runs as `export DOCKER_CONFIG=<dir> && echo '<pw>' | docker login
  ...` on purpose: `CommandRedaction::STDIN_PIPE` only redacts when the pipe
  is directly followed by `docker login`, so `docker --config <dir> login` and
  a `DOCKER_CONFIG=<dir>` prefix would both leak the password into logs.
- `registry.password:` is deprecated and warns once per deploy; it is due for
  removal one release after this ships.
