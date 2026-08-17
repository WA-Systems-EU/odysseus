# A deploy user, and the setup that creates it

Status: designed 2026-08-16, not yet implemented.

## Problem

Odysseus runs as root on every target host, and not by accident — three
mechanisms hold it there:

- `ssh.user` defaults to `'root'` (`config/parser.rb:184`, and again in
  `deployer/ssh.rb:15` and `builder/client.rb:276`).
- There is **no `sudo` anywhere in either gem**. A non-root user has no
  escalation path at all.
- Host state lives under `/var/lib/odysseus`, which a non-root user cannot
  create.

That last one is not merely awkward, it is fatal today. `write_env_file` runs
`chmod 700` on `/var/lib/odysseus/env` (`docker/client.rb:393`), and a
non-owner cannot chmod a root-owned directory. **A non-root deploy fails at
the first container start**, before anything else is reached. So "non-root is
unsupported" is the accurate description, not "untested".

Separately, target hosts must already have Docker; nothing installs or
verifies it. That is the first thing a stranger meets.

These are one problem. A deploy user that cannot be created is theory, and a
`setup` command with nothing to set up is busywork.

### What this is not

Membership of the `docker` group is root-equivalent: `docker run -v /:/host`
escapes it in one command. Moving off root buys real hygiene — no accidental
destruction as root, an auditable identity, and the shape people expect from
a deploy tool — but it is **not a security boundary**, and no document in this
project may imply that it is.

## Verified ground truth

Everything the design rests on, checked against the tree at 0.7.0:

| Fact | Where | Consequence |
| --- | --- | --- |
| `ssh.user` defaults to `root` | `config/parser.rb:184` | Changing it is a breaking change for configs that omit the key |
| No `sudo` in either gem | grep, both gems | Setup's bootstrap identity needs passwordless sudo, or must be root |
| `Net::SSH.start(non_interactive: true)` | `deployer/ssh.rb:166` | A sudo password prompt hangs and then fails. It can never be answered |
| `chmod 700` on the env dir | `docker/client.rb:393` | The env dir must move for non-root, or no container starts |
| `mkdir -p /var/lib/odysseus/caddy`, mounted `:/data` | `caddy/client.rb:40,51` | That directory is the Let's Encrypt certificate store |
| Deploy log at `/var/lib/odysseus/<service>/deploys.log` | `deploy_log.rb:12,46` | Rollback history. Read by `rollback --list` via `host_versions.rb:30` |
| `record_deploy` rescues and warns | `deployer/executor.rb:343-350` | A permissions failure erodes rollback history silently, deploy after deploy |

The Caddy directory is the one that shapes the migration. It holds issued
certificates, it is written by the Caddy container as root, and re-issuing
against Let's Encrypt rate limits is a real cost for no benefit. This was the
reasoning that first argued the directory must stay fixed; see the
correction under Host state for why that conclusion did not survive.

## Design

### Three identities, two configured

**The bootstrap identity** connects only for `odysseus setup`. It needs to be
root or to have passwordless sudo. It is configured separately from the deploy
identity because on a fresh host the deploy identity does not exist yet — a
single `ssh.user` cannot serve both, and a `setup` that cannot run on a fresh
host has no purpose.

**The deploy identity** is `ssh.user`, exactly as today. Setup creates *the
user named in `ssh.user`* rather than a user named in some new key, so it is
structurally impossible to create one user and then deploy as another.

**Root on the host** is reached from the bootstrap identity during setup, and
never again. The deploy identity gets `docker` group membership and its own
`$HOME`. It does not get sudo.

```yaml
ssh:
  user: odysseus          # deploy identity; default changes to this
  keys: [~/.ssh/id_ed25519]

setup:                    # read only by `odysseus setup`
  connect_as: root        # or ubuntu, on images where root SSH is disabled
  authorized_keys:        # optional; defaults to the .pub siblings of ssh.keys
    - ~/.ssh/id_ed25519.pub
```

**No sudo for the deploy user.** The verified deploy path needs the docker
socket and a writable home, and nothing else. Granting sudo later is one
`usermod`; withdrawing it from live fleets is a migration. This follows from
the rule below rather than being an independent decision.

### Setup is the only thing that touches the host

The deploy path never uses root or the bootstrap user. `setup` is the sole
exception, and it is exceptional by design: it configures a host once, and
afterwards odysseus can no longer modify that host at all.

Two consequences follow, and both are load-bearing rather than incidental:

- **The deploy-log migration has exactly one window.** After setup, the deploy
  user can read `/var/lib/odysseus/<service>/deploys.log` but can never write
  it. Copying it is not a convenience step; it is the only moment it can
  happen.
- **Adding another operator's key is a `setup` re-run**, connecting as the
  bootstrap identity. Odysseus offers no command to do it afterwards, because
  it has no privilege to.

### The default changes to `odysseus`

`ssh.user` defaults to `odysseus` rather than `root`.

This is a breaking change for any config that omits the key, and 1.0 is the
only honest moment to make it — later there may be installs relying on the
implicit default, and the tool would be stuck with root forever.

It is safe now for a specific, checked reason: **all six deploy.yml files in
use set `ssh.user: root` explicitly**, so none of them changes behaviour. The
published gems are odysseus-core 0.3.2 and odysseus-cli 0.3.0, far enough
behind that nobody upgrades into this by accident. Migration is therefore
opt-in, per service, by editing one line.

Root remains fully supported. It is the documented legacy mode, not a
deprecated one.

## What `setup` is for, and what it is not

**Preparing servers is not odysseus's job.** That belongs to OpenTofu,
Terraform or equivalent, which does it declaratively and at scale, and the cost
of standing up one host or ten that way is now small enough that most engineers
can reach it. Odysseus deploys to hosts; it does not manage them.

So `setup` has two halves with different lifespans, and they should be allowed
to grow differently.

`odysseus doctor` is the durable half. It answers "is this host actually usable
by odysseus as the user my config names?", which is worth asking on every host
however it was prepared — including one built by tofu, where it serves as the
acceptance test for that configuration. It should learn more checks over time.

The bootstrap half is a convenience for getting a single host going in order to
try the tool. **Ubuntu-only is the message, not a limitation to fix**: it says
plainly that this is for trial, and that anything beyond that should use a
provisioning tool and its own good practices. It should be resisted from growing
— every capability added to it is a step toward being a bad provisioning tool
instead of a good deploy tool.

Stated 2026-08-17, and it is why `setup` did not exist earlier: the omission was
deliberate, not an oversight.

## What `setup` does

Connect as `setup.connect_as`, then run the sequence below. Every step is
check-then-apply: a run that is interrupted re-converges on the next run, and
a second run against a healthy host changes nothing and says so. Commands
needing root are prefixed `sudo -n` **only** when `connect_as` is not root,
because minimal images often have no `sudo` at all.

0. **Escalation probe.** If `connect_as` is not root, run `sudo -n true`. On
   failure, refuse and say why: odysseus cannot answer a password prompt
   (`ssh.rb:166`), so this is a hard requirement rather than a preference.
1. **Distro gate.** Read `/etc/os-release` and require Ubuntu on one of the
   two most recent LTS releases — **26.04 and 24.04** as of this writing.
   Name the versions in code rather than computing "the last two", so that
   supporting a new LTS is a deliberate edit with a tested host behind it
   rather than something that silently becomes true on a date. Anything else
   is refused by name. Guessing at package managers we have no host to test
   against would mean shipping installers that can leave a machine
   half-configured.
2. **Docker.** If `docker info` succeeds, skip. Otherwise install from
   Docker's official apt repository. Both the keyring and the sources file are
   written whole every run rather than appended, so an interrupted run leaves
   a stale file the next run overwrites, never a corrupt one. Finish by
   re-running `docker info`; if the daemon does not answer, the step failed.
3. **User.** If `id -u <ssh.user>` succeeds, verify the home directory exists
   and is owned correctly, repairing if not — this is the half-created-user
   recovery. Otherwise `useradd --create-home`. The password stays locked;
   login is key-only by construction.
4. **Group.** `usermod -aG docker <user>`, idempotent by nature. No sudo group.
5. **Authorized keys.** Sources, in order: explicit `setup.authorized_keys`
   entries, else the `.pub` siblings of `ssh.keys` that exist locally. If that
   yields nothing, **refuse before creating anything** — a created user with
   no way to log in is the worst outcome available. Install by *appending*
   missing lines, never overwriting, so a second operator's key survives
   someone else's re-run. Create `~/.ssh` as `700` and `authorized_keys` as
   `600`, owned by the new user: sshd silently ignores them otherwise, with no
   error worth finding.
6. **Directories.** As the new user, create `~/.odysseus`. Caddy's data
   directory is not a special case here: it derives from the connection user
   like everything else in `HostPaths`, so it lands under `~/.odysseus/caddy`
   for this user, a directory they already own. The deploy path's own
   `mkdir -p` (`caddy/client.rb:41`) creates it the first time Caddy starts;
   setup has nothing to pre-create as root.
7. **Deploy-log migration**, per the section below.
8. **Self-test over a fresh connection as `ssh.user`.** Log in, run
   `docker info`, write a file under `~/.odysseus`. Setup reports success only
   if this passes.

Step 8 is the safety argument for the whole command. Setup only ever *adds*
access — it never modifies root's or the bootstrap user's configuration — so a
failure leaves the bootstrap path intact and the host reachable. It should
never hand back a host it has not proven it can reach.

**Setup refuses to**: run on an unsupported distro; proceed without
passwordless sudo; create a user with no installable public key; change an
existing user's shell, home or password; delete anything; touch the firewall,
swap, `sshd_config`, or unattended-upgrades.

`odysseus doctor` runs these checks read-only, as `ssh.user`:
distro, docker reachable, group membership, state directory writable,
deploy-log location. Caddy's directory is not on this list: since step 6 no
longer pre-creates it, it does not exist until the first deploy starts
Caddy, and checking for it right after setup would report a healthy host
that has not deployed yet as broken. It is **its own command, not a mode of `setup`** (decided
2026-08-17): the two have different lifespans, and naming the durable one after
the disposable one would mean someone who provisions with tofu and never runs
the bootstrap still reaching for a command called `setup`. It also lets the
bootstrap be deprecated later without taking the diagnostic with it.

## Host state

The base directory becomes a function of the connection user, computed in one
place — `Odysseus::HostPaths` — which the deploy lock will also consume.

| State | Root | Non-root |
| --- | --- | --- |
| Deploy log | `/var/lib/odysseus/<service>/deploys.log` | `$HOME/.odysseus/<service>/deploys.log` |
| Env files | `/var/lib/odysseus/env` | `$HOME/.odysseus/env` |
| Caddy certificates | `/var/lib/odysseus/caddy` | `$HOME/.odysseus/caddy` |

The env directory *must* move; see the `chmod 700` finding above.

**Correction, 2026-08-17.** This section originally argued the Caddy
directory must *not* move, since it is daemon-side state holding issued
certificates and moving it risks copying live certs or re-issuing against
Let's Encrypt's rate limits. That reasoning is sound, but it only ever
protects a *root* install — the only kind with certificates at the old path
today. Deriving the Caddy directory the same way as every other path here
protects root identically: root still resolves to exactly
`/var/lib/odysseus/caddy`, byte-identical, nothing moves and nothing
re-issues. What the fixed-path design actually did was make every non-root
web deploy fail outright, because `Caddy::Client#ensure_running` ran `mkdir -p
/var/lib/odysseus/caddy` over the deploy connection and a non-root user
cannot create that parent. This was found on a real deploy to a real host
(`dedalus-prototypes`), not in review. The Caddy directory now follows
`HostPaths#caddy_dir`, exactly like the deploy log and env files.

`$HOME` is resolved once per connection with `echo $HOME` and paths built
absolute, rather than relying on tilde expansion — remote paths travel through
both `ssh.execute` and SCP (`ssh.rb:89-93`), and the two need not agree.

### Migration

Setup copies each service's existing log to the new location and chowns it,
if and only if the old exists and the new does not. The original is never
deleted, and nothing in the codebase ever deletes `/var/lib/odysseus`.

Certificates are not part of this copy. A host migrating from root to a
deploy user re-issues its certificates exactly **once**, the next time Caddy
is recreated — whether because the container was removed by hand or because
`ensure_running` finds it stopped and recreates it (see `caddy/client.rb`).
The new user cannot read or move the root-owned certificate store at
`/var/lib/odysseus/caddy`, so the recreated container starts against an
empty `~/.odysseus/caddy` and Let's Encrypt is asked again. That is strictly
better than the old fixed-path design, which failed the deploy outright
instead of paying this one-time cost.

As a fallback for a host whose user was created by hand, `DeployLog#entries`
reads the new location, then the old: one shell fallback, no merging. Appends
always go to the new location.

A host that keeps deploying as root after a copy would fork its history across
two files. That is documented rather than engineered around — deploying one
service as two different users is not a supported shape.

**dedalus-prod** carries five services — `wa-systems-pel`, `zafu-shop`,
`wa-systems-insights`, `wa-systems-landing`, `odysseus-landing` — so it is one
host and five logs. It gets a hand-written migration, checked service by
service, rather than being the first exercise of an automated path.

Related, and worth fixing in the same phase: `record_deploy` rescues
`StandardError` and only warns (`executor.rb:343-350`). A permissions mistake
therefore erodes rollback history invisibly, one deploy at a time.
`odysseus doctor` checking log-directory writability is what keeps that a
one-time event.

## Phasing

Each phase ships alone and leaves the tool deployable, because real services
are deployed with it between releases.

1. **`HostPaths` and non-root state.** Base directory derived from `ssh.user`;
   env directory and deploy log follow; the fallback read. Root installs are
   bit-for-bit unchanged. Independently useful: non-root deploys work on a
   host you configure by hand.
2. **`odysseus doctor`.** Read-only diagnosis. Most of the surprise removed for
   a fraction of the work, and the half that lasts.
3. **`setup` bootstrap**, without the Docker install: config block, sudo
   probe, user, group, keys, directories, log migration, self-test. A host
   without Docker is refused plainly.
4. **Docker install.** The riskiest part — repository keys, apt locks on a
   minutes-old host, dpkg state — lands last, behind the distro gate.
5. **Docs.** The quickstart becomes setup-then-deploy; root documented as the
   legacy mode. `odysseus-cli/README.md:670` ("your target servers only need
   Docker installed") changes in the phase that makes it true, not before.

## What could go wrong

- **A created user that cannot log in.** Prevented by construction: refuse
  without an installable key, append rather than overwrite, and report success
  only after logging in as that user over a fresh connection.
- **A sudo password prompt.** Hangs rather than prompting. The `sudo -n true`
  probe turns it into one sentence.
- **A half-created user.** Re-run guards on `id -u`, repairs home ownership,
  appends missing keys. No step assumes the previous run finished.
- **An interrupted Docker install.** Keyring and sources rewritten whole. An
  apt lock held by cloud-init or unattended-upgrades — the normal state of a
  minutes-old host — gets a bounded wait and then an error naming the holder,
  never a silent stall. Setup does not attempt to repair a broken apt state it
  did not create.
- **The wrong `connect_as`.** Surfaces as an authentication failure, already
  mapped to a readable message (`ssh.rb:150`); setup names the *bootstrap*
  identity so the reader fixes the right key.
- **The deploy user losing docker group membership.** Every deploy fails on
  the socket. `odysseus doctor` is the diagnosis. Note `usermod -aG` affects
  only new sessions — harmless here, since every deploy opens a fresh one, but
  the self-test must use a fresh connection or it tests the wrong thing.
- **Tailscale's red herring.** `use_tailscale: true` is hardcoded
  (`executor.rb:391`), so every connection timeout suggests Tailscale
  troubleshooting — on exactly the fresh hosts that do not have Tailscale.
  Worth suppressing on the setup path.
- **Orphaned root-owned env files.** The documented SIGKILL leftover becomes
  unreachable to the new user. Harmless; it stays root's.

## Decisions taken

| Decision | Rationale |
| --- | --- |
| Deploy user gets no sudo | The verified deploy path needs docker and `$HOME`. Adding later is trivial; removing is a migration |
| 1.0 includes the Docker install | Scoped to the last two Ubuntu LTS releases only |
| Default `ssh.user` becomes `odysseus` | 1.0 is the only honest moment. Safe now because every config in use sets it explicitly |
| Caddy's directory follows the connection user | Reversed 2026-08-17: the original "does not move" reasoning (root-owned certificates, rate-limited to re-issue) only ever protected root, and deriving the path protects root identically while letting a non-root deploy user create its own directory. Found by a real non-root deploy failing at `mkdir` |
| Setup touches nothing belonging to root or the bootstrap user | It only adds access, so failure always leaves a reachable host |
| No `odysseus key add` | Setup has the privilege; the deploy identity does not |

## Open

- **Debian.** The earlier scoping said apt generally; this narrows to Ubuntu
  LTS. Debian is not refused because it is unsuitable, but because there is no
  host to test it against.
- **Pinning Docker's GPG key fingerprint.** Not doing so trusts TLS to
  `download.docker.com`, which is what Docker's own instructions do. Pinning
  defends against a CA-level compromise but turns Docker's key rotation into
  every user's outage.
- **The deploy lock** (designed separately) reads its base path from
  `HostPaths` and is otherwise unaffected by this work.
