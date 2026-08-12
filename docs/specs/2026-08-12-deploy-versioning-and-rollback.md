# Deploy versioning and rollback

Status: approved, not yet implemented
Date: 2026-08-12
Affects: odysseus-core, odysseus-cli

## Problem

Odysseus cannot answer "what code is running?" and therefore cannot roll back.

The image tag defaults to `latest`, so every build overwrites the previous image
both locally and, via pussh, on each host. `odysseus.version` — the only version
label — holds the deploy *timestamp*, not the identity of the code. Nothing ties a
running container to a commit.

Observed on `dedalus-prod` on 2026-08-12, mid-incident: two `wa-systems-insights`
containers running side by side, both reporting image `wa-systems-insights:latest`,
one built from code two weeks old and one from that morning. The only
distinguishing information was `20260727171254` vs `20260812112759`.

Rollback material does not exist either. `WebDeploy#drain_and_remove` stops **and
removes** the old container, so `cleanup_old_containers(service:, keep: 2)` — which
only ever inspects `exited` containers — has nothing to act on. All 17 containers on
that host are `Up`; none are retained. Today a rollback means working out which
commit was live, rebuilding it, and redeploying, and step one has no recorded
answer.

## Goals

1. A deployed container can be traced to a commit.
2. Rolling back to the previous version, or a named version, requires no rebuild.
3. Deploy history — which commit shipped, when, by whom — is recorded in the app's
   git repository.
4. `status` answers "which commit is serving?".

## Non-goals

Deliberately excluded, with the reasoning, so they are not re-litigated mid-build:

- **Retaining stopped containers for an instant rollback.** Considered and deferred:
  it changes the deploy path's failure semantics, doubles the retention knobs, and
  keeps volumes and IPs alive on hosts already running many containers. Revisit once
  rollback exists and a ~30s rollback proves too slow.
- **Host-side registry authentication.** Tracked separately in `TODO.md`; pussh is
  the path this design assumes.
- **Deploy locks and multiple destinations.** Both interact with this work — see
  Known limitations — but are separate items.

## Design

### Version identity

The version is a git commit SHA and it is the image tag.

Resolution order, evaluated against the directory containing `deploy.yml`:

1. `--image TAG` given → use it verbatim; no git required. Rollback uses this path
   internally.
2. Directory is a git work tree → `git rev-parse --short=12 HEAD`.
3. Otherwise → raise `Odysseus::ConfigError` naming the directory and instructing
   the user to pass `--image`.

A dirty work tree aborts the deploy with guidance to commit or pass `--image`. There
is no `_uncommitted` suffix: shipping code that cannot be reproduced from its own
tag is the failure this design exists to prevent.

Dirtiness is `git status --porcelain --untracked-files=no` returning any output —
tracked modifications only. Untracked files produce a warning, not an abort.
Rationale: tracked changes mean the SHA misrepresents the committed code, whereas
untracked files are usually local noise. The residual risk is real and worth stating
— the Docker build context includes untracked files unless `.dockerignore` excludes
them, so an untracked file can change the image while the tag stays constant.

Supporting values, both informational:

- `git_ref`: `git rev-parse --abbrev-ref HEAD`, which yields `HEAD` when detached.
- `deployer`: `git config user.email`, falling back to `ENV['USER']`, then
  `unknown`.

`:latest` is no longer produced. It is the moving pointer this design removes, and
retaining it would reintroduce the ambiguity observed above. `--image latest`
remains available for anyone who needs the old behaviour.

### Container labels

`Docker::Client#build_run_command` gains three labels and repurposes one:

| Label | Value | Change |
| --- | --- | --- |
| `odysseus.service` | service name | unchanged |
| `odysseus.version` | the version (SHA) | **repurposed**; previously the timestamp |
| `odysseus.deployed_at` | ISO 8601 UTC | new; takes over the old meaning |
| `odysseus.git_ref` | branch or tag at deploy time | new |

No role label is added: the role is already recoverable from `odysseus.service`,
which is the bare service name for `web` and `<service>-<role>` for every other role.

Container names become `<service>-<version>-<timestamp>`, so `docker ps` is legible
without inspecting labels. The timestamp is retained because the same version may be
deployed more than once and names must stay unique.

### Host deploy history

Each host keeps one log per **service**, at
`/var/lib/odysseus/<service>/deploys.log`, appended after a deploy succeeds **on that
host**, mode 0644 in a 0755 directory.

`<service>` is the `service:` value from `deploy.yml`, not the role-suffixed name used
in `odysseus.service`. The log is service-level because the artifact it describes is
service-level: `web` and `jobs` deploy the same image with different commands, so a
per-role log would let one role prune an image the other still needs. Each role
appends its own line and names itself in the `role` field.

Fields, space-separated, timestamp first so the file sorts chronologically:

`<iso8601> <version> <role> <git_ref> <deployer> <kind> [from=<version>]`

```
2026-08-12T11:27:59Z abc123def456 web  main thomas@imfiny.com deployed
2026-08-12T11:28:14Z abc123def456 jobs main thomas@imfiny.com deployed
2026-08-12T14:02:11Z 9f8e7d6c5b4a web  main thomas@imfiny.com rolled-back from=abc123def456
```

`kind` is `deployed` or `rolled-back`; `from=` appears only on the latter.

This exists because ordering cannot be derived reliably from image timestamps —
images can arrive on a host out of order, and `CreatedAt` reflects build time, not
deploy time. It is also the host-side audit trail, and it survives container removal
and image pruning.

Fields are shell-escaped when the append command is built (`Shellwords.escape`); a
git ref or committer email is attacker-influenced input in the general case.

### Rollback

```
odysseus rollback [VERSION] [--config FILE] [-v]
odysseus rollback --list [--config FILE]
```

With no `VERSION`, the target is the most recent version in `deploys.log` that is
not currently running and whose image is present on the host. With a `VERSION`, that
version is used. Rollback then runs the **existing deploy path** with
`image_tag: VERSION`, skipping build and distribution entirely, so zero-downtime
behaviour, health gating and proxy handling are shared with `deploy` rather than
reimplemented.

A rollback covers **every role** in the config, exactly as `deploy` does. Rolling
back `web` while leaving `jobs` on newer code is not a mode this command offers.

Target resolution, per host:

1. Available versions: `docker images <image> --format '{{.Tag}}'`.
2. Current version: the `odysseus.version` label of the running container.
3. Candidates: entries in `deploys.log`, newest first, whose version is available
   and is not current.

When `deploys.log` is absent — a host that has not yet deployed under this
scheme — fall back to image `CreatedAt` ordering and warn that the ordering is
approximate.

**Fleet pre-flight.** Before touching any host, verify the target image exists on
every host across all roles. If any host lacks it, abort and report which hosts have
which versions. A half-rolled-back fleet is worse than a refused command.

`rollback --list` prints, per host: version, deployed_at, ref, deployer, whether the
image is present, and which version is serving. It reads only the host, so it works
without a git repository or fetched notes.

### Retention

`retain_versions` at the top level of `deploy.yml`, default 5, validated as an
integer ≥ 1.

After a successful deploy on a host, prune images for that service beyond the newest
`retain_versions` distinct versions in `deploys.log`, always keeping the running
version. Removal uses `docker image rm <image>:<tag>` per image, and each removal is
individually rescued: an image still referenced by a container makes Docker exit
non-zero, which now raises `SSHCommandError`, and one unremovable image must not
fail a successful deploy. Skipped images are logged.

`latest` images left over from before this change are never removed automatically,
since something may still reference them. `cleanup --prune-images` remains the
manual sweep.

### Git notes

Deploy history is appended to `refs/notes/odysseus/deploys` in the app repository:

```
2026-08-12T11:27:59Z  wa-systems-insights  thomas@imfiny.com  hosts=dedalus-prod
image:  wa-systems-insights:abc123def456
result: deployed
```

- Written **after** the deploy resolves, so the record reflects the outcome. A note
  written on trigger would claim commits that never served traffic — precisely what
  the 409 incident would have produced.
- `result` is `deployed`, `failed: <step>: <message>`, or `rolled-back from=<version>`.
- `git notes --ref=odysseus/deploys append` rather than `add`, so repeated deploys of
  one commit accumulate instead of colliding.
- **Best-effort.** A failed note write warns and never fails a deploy that
  succeeded. Notes are a record, not a gate.
- Not pushed automatically; writing to someone's remote as a side effect of a deploy
  is a surprise. The README documents the refspecs:
  `git push origin refs/notes/odysseus/deploys` and
  `git fetch origin 'refs/notes/*:refs/notes/*'`.

Notes are authoritative for *history* only. Nothing in the rollback path reads them:
hosts are authoritative for what can actually run. This split is deliberate — a
deploy process killed between acting and writing, a change made by hand on a host, or
a rebuilt host all put git and reality out of step, and rollback must not depend on a
record that can drift.

### Commands that change

- `app exec`, `app shell`, `app console` currently hardcode `#{image}:latest`. They
  resolve the version from the running container's label instead, so the one-off
  container runs the code that is actually serving. When nothing is running for the
  service they fail with that message rather than silently running a stale image.
- `status` reports version, `deployed_at` and `git_ref` per container, making
  "which commit is serving?" answerable.

## Backwards compatibility

Containers deployed before this change carry `odysseus.version=<timestamp>` and were
built from `:latest`, so they cannot be rollback targets — no SHA-tagged image exists
for them. `rollback --list` shows such versions as unavailable rather than implying
otherwise. The first deploy after upgrading establishes a SHA-tagged image and, on
that host, `deploys.log`.

The default deploy behaviour changes: `odysseus deploy` with no `--image` previously
deployed `latest` and now resolves a SHA, or aborts outside a git repository. This is
the intended correction and belongs in a minor release with a note in both
changelogs.

## Error handling

| Situation | Behaviour |
| --- | --- |
| Dirty work tree | `ConfigError`, before any host is contacted |
| Not a git repository, no `--image` | `ConfigError` naming the directory |
| `retain_versions` not an integer ≥ 1 | `ConfigValidationError` from the config validator |
| Rollback target image missing on any host | Abort with a per-host report, nothing touched |
| Rollback with no candidate version | Abort explaining what the host does have |
| `deploys.log` unreadable or absent | Warn, fall back to image ordering |
| Image pruning blocked by a container | Log and continue; never fail the deploy |
| Note write fails | Warn; deploy result unaffected |

## Testing

Version resolution is tested against **real temporary git repositories** rather than
stubbed `git` invocations — clean, dirty-tracked, dirty-untracked-only, detached
HEAD, and not-a-repo. Stubbing the command under test would only assert that the
stub was called.

Unit coverage, all offline against the existing SSH and Docker doubles:

- label construction, including the repurposed `odysseus.version`
- container naming with version and timestamp
- `deploys.log` line format and shell escaping of ref and deployer
- rollback target resolution: happy path, no candidates, missing log, version not
  available on a host
- fleet pre-flight refusal when one host of several lacks the image
- retention selection: which images are chosen for removal, current version never
  chosen, an unremovable image not failing the deploy
- note formatting for each `result` value, and a failed note write not raising
- `app exec` resolving the running version, and its error when nothing runs

Each new spec is checked against a deliberate mutation of the code under test before
being considered done, as `CONTRIBUTING.md` requires.

## Implementation phasing

The design is one coherent change but should land in independently useful pieces,
each shippable on its own:

1. **Version identity, labels, `status`, `app exec`.** Answers "what commit is
   serving?" and fixes the `:latest` staleness in the one-off container commands.
   Valuable even with no rollback command, and the foundation everything else reads.
2. **Host deploy history.** `deploys.log` and its append step. Gives the host-side
   audit trail, and is what makes "previous version" unambiguous.
3. **`rollback` and the fleet pre-flight.** Depends on 1 and 2.
4. **Retention and pruning.** Depends on 2 for ordering. Until it lands, images
   accumulate — acceptable briefly, since SHA-tagged images share layers, but it
   should not be left out for long.
5. **Git notes.** Independent of 2–4; can land any time after 1.

## Known limitations

- **No deploy lock.** Two concurrent deploys, or a deploy racing a rollback, can
  interleave. The lock item in `TODO.md` addresses this; this design does not.
- **Multi-host rollback is sequential** and inherits the existing partial-failure
  semantics: a failure on host 3 of 5 leaves a mixed fleet. The pre-flight makes the
  common cause — a missing image — impossible, but does not make the roll atomic.
- **Untracked files can still change an image** without changing its tag, as noted
  under Version identity.
- **Rollback re-runs the deploy path**, so it boots a container and waits for health
  checks: expect roughly the time of a normal deploy minus build and transfer, not
  the sub-second re-point that retained containers would allow.
