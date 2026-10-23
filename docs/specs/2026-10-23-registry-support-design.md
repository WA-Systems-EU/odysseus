# Finishing registry support

Status: designed 2026-10-23, not yet implemented.

## Problem

Registry mode works for a public image and fails for a private one, which is
the only case anyone actually has. Three gaps, each verified against 0.10.1:

- **Nothing ever logs in on a deploy host.** The single `docker login` in
  either gem is `builder/client.rb:264`, and it runs on the *build* machine. A
  deploy target is never given credentials.
- **`WebDeploy` and `JobDeploy` never pull.** Zero occurrences of `pull` in
  either. They rely on `docker run`'s implicit pull, so a fetch failure
  surfaces as a container that would not start rather than as an image that
  could not be fetched. `DependencyDeploy` is the exception: it pulls
  explicitly (`dependency_deploy.rb:148`), but still without credentials.
- **There is no way to keep the credential out of `deploy.yml`.** `parse_registry`
  (`config/parser.rb:268`) reads literal `server`, `username` and `password`.
  The CLI README nonetheless says "you can store registry credentials in your
  encrypted secrets file and reference them" -- a promise with no mechanism
  behind it, which `CONTRIBUTING.md` classes as a bug.

## Verified ground truth

Everything the design rests on, checked against the tree at 0.10.1:

| Fact | Where | Consequence |
| --- | --- | --- |
| `secrets_loader` already reaches all three orchestrators | `executor.rb:384-392` | No new plumbing is needed to resolve a secret at deploy time |
| `env.secret:` is a declared allowlist, not the whole file | `core/environment.rb:40` | A credential in the encrypted file does not reach any container unless listed |
| `secret_value` falls back to the host's own environment | `core/environment.rb:52-58` | Credentials must NOT resolve through `Environment`; see Non-goals |
| Sails receive `ssh:, config:, logger:, secrets_loader:` | `executor.rb:384` | A new orchestrator argument must be optional or `odysseus-sail-rolling` breaks |
| Each orchestrator builds its own `Docker::Client.new(ssh)` | `web_deploy.rb:23` and siblings | Threading a config dir through the constructor would touch every call site; per-call is cheaper |
| `CommandRedaction` matches `echo '<pw>' \| docker login ... --password-stdin` | `command_redaction.rb:12` | The host login must be built in that shape to stay redacted under `--debug` |
| `docker run` implicitly pulls a missing image | docker behaviour | With an explicit pull first, `run` needs no credentials -- so the session can close before containers start |

## Design

### Credential resolution

A new `Odysseus::Registry::Credentials` resolves `server`, `username` and
`password`, and reports whether it is complete.

```yaml
registry:
  server: ghcr.io
  username: wa-systems
  password_secret: REGISTRY_TOKEN   # a key in the encrypted secrets file
```

Sources are **not** a cascade. A silent fallback between credential sources is
how a deploy authenticates with the wrong one:

1. `password_secret:` resolves through `Secrets::Loader#get`. A key the file
   does not contain is a `ConfigError` naming both the key and the file.
2. `password:` is still accepted and warns, for removal one release later --
   the same treatment `accessories:` got when it became `dependencies:`.
3. Both set is a `ConfigError`, not a precedence rule.
4. Neither set consults `ODYSSEUS_REGISTRY_PASSWORD`, read on the machine
   running odysseus, for CI where the secrets file and its key are not
   available.
5. Absent there too, registry mode runs without credentials -- today's
   public-image behaviour, which stays valid.

`username` stays literal. It is not the secret, and making it secret-able
doubles the configuration surface for nothing.

### The host session

`Odysseus::Registry::HostSession` opens, yields, and closes:

- `mktemp -d` on the host, mode `700`
- `docker --config <dir> login <server> -u <user> --password-stdin`
- `rm -rf <dir>` in an `ensure`

An isolated `--config` directory rather than `docker login` followed by
`docker logout`, for three reasons. Credentials never enter
`~/.docker/config.json`. A deploy that dies between login and logout leaves
nothing behind, where the logout approach leaves exactly what it was meant to
clean up. And `docker logout` against the default config would remove
credentials that host already had for its own purposes -- a side effect a
deploy has no business having.

`Executor` opens one session per host before the role orchestrators run and
closes it after. One login per host per deploy, one owner, one `ensure`.
Because the explicit pull puts the image on the host, the session can close
before any container starts.

### Explicit pull

`Docker::Client#pull(image, config_dir: nil)` -- per-call, so no other docker
command changes. `WebDeploy` and `JobDeploy` take an optional
`registry_config_dir:` and pull before starting a container.
`DependencyDeploy` already pulls and needs only the directory.

A pull failure aborts the deploy naming the image and the registry, so the
failure is attributable rather than arriving later as a container that would
not start.

### Error handling

| Failure | Behaviour |
| --- | --- |
| `password_secret` names a key the file lacks | `ConfigError`, naming the key and the file. Before any connection. |
| Both `password` and `password_secret` set | `ConfigError`. Before any connection. |
| `docker login` rejected on a host | Abort before any container starts, naming the server. Password redacted. |
| `docker pull` fails | Abort, naming image and registry. |
| Session teardown fails | Warn, naming the directory left behind. Never fails the deploy -- but never silent either, because what was left is a credential on a host. |

## Testing, and what the tests cannot show

Specs cover credential resolution across every source combination including
both error cases; session open and close, including close when the block
raises; the redaction shape of the login command; and that each orchestrator
pulls before it runs. Each checked against a deliberate mutation of the code
it covers.

**Every docker and SSH call in the suite is a double.** Nothing in it proves
that a real private registry accepts the login, that `--config` isolates
credentials the way the documentation says, or that teardown removes what
login wrote. Those are the three claims that matter most and none of them is
testable here.

So the README's **experimental** marking stays until someone runs this against
a real private registry. The suite proves the commands are constructed; it
does not prove registry mode works.

## Non-goals

- **Credentials do not resolve through `Core::Environment`.** Its
  `secret_value` falls back to the deploy host's own environment when the
  encrypted file lacks a key. For application config that is defensible; for a
  registry credential it means a host that happens to have `REGISTRY_TOKEN` set
  for an unrelated reason would silently authenticate your deploy. Credentials
  resolve straight through `Secrets::Loader#get` with no host fallback.
- **No registry credential is injected into any container.** Nothing here adds
  to the container environment. A credential in the encrypted file reaches a
  container only if the user lists it in `env.secret:`, which is their choice
  and not this design's doing.
- **`username` is not secret-able.** See above.
- **The `Environment` host fallback is not changed here.** It is recorded as
  its own TODO entry; fixing it is a behaviour change for application config
  and does not belong in a registry change.

## Documentation

The CLI README's registry section gains the real mechanism in place of its
gesture at one, and keeps its experimental warning with the reason now stated:
not that the code is unfinished, but that it is unverified against a real
private registry.
