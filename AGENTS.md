# AGENTS.md

Shared context for Codex CLI and Claude Code working in this repo. Keep
this file up to date for both — it's the handoff point between them.

## Repo status

`open-data-platform` is a fresh repository (one empty initial commit, no
application code yet). The first thing built here is a per-workspace
Orca environment recipe, `local-docker-sandbox` — see below.

## `local-docker-sandbox` environment recipe

Defined in `orca.yaml`, implemented in `scripts/orca-vm/`. It gives each
Orca workspace its own ephemeral, SSH-reachable Docker container on this
machine, running Codex CLI as a non-root user, with the workspace's own
worktree bind-mounted in.

### How it works

- **Provider:** local Docker, always addressed through the host's
  **rootless** context (`docker --context <ctx> ...`). `docker-lib.sh`'s
  `resolve_docker_context` finds it by checking `SecurityOptions` for
  `name=rootless` (never trusts a context just because it's *named*
  "rootless") and fails loudly if none exists.
- **Connection mode:** SSH, not `orca serve`. `docker-create.sh` emits a
  `connection.type: "ssh"` block; Orca's SSH relay dials in.
- **Repo access:** the workspace's own worktree is **bind-mounted**
  read-write into the container at `/workspace` — it is *not* git-cloned
  inside the container. `docker-create.sh` captures `$(pwd)` as
  `_invocation_dir` *before* its own `cd` to its script directory (needed
  so `source ./docker-lib.sh` is reliable) and uses that as the mount
  source — i.e. the directory Orca invokes `create` from, that
  workspace's own checkout — never a path from `docker-state.json`,
  since state is shared across every workspace but each workspace has a
  different worktree. This also means the recipe needs no Git
  token/remote at all. The checkout may be a linked worktree (a `.git`
  *file*, not directory) — the sanity check uses
  `git rev-parse --is-inside-work-tree`, not `[ -d .git ]`, to accept that.
- **Images as snapshots:** local Docker has no cloud-style VM snapshot,
  so a tagged image plays that role. `docker-base-snapshot.sh` builds
  `orca-local-docker-sandbox-base` from `docker/Dockerfile.base`.
  `docker-base-auth.sh` boots it, has a human log Codex in interactively
  *inside the container*, verifies the login, and commits
  `orca-local-docker-sandbox-auth` — the image `docker-create.sh` boots
  per workspace. Host Codex credentials (e.g. `~/.codex`) are never read
  or copied into the image; the image only ever holds credentials from a
  login performed inside a container.
- **The permission problem this recipe solves:** rootless Docker maps
  *only* container UID 0 1:1 to the real host user; any other container
  UID (including the non-root `agent` user, UID 1000) lands somewhere in
  that user's `/etc/subuid` range instead (verified empirically on this
  host: container UID 1000 → real host UID `100999`). That means `agent`
  can't write into a bind-mounted directory the host user owns unless
  something grants it access. `docker-create.sh` solves this by computing
  that mapped UID (`mapped_host_id` in `docker-lib.sh`) and granting it a
  POSIX ACL (`setfacl -R -m u:<mapped-uid>:rwx -m d:u:<mapped-uid>:rwx`)
  on the worktree directory before starting the container — no chown, no
  changed ownership, no host-wide permission change. `docker-destroy.sh`
  revokes that same ACL entry on teardown. Requires `setfacl` (package
  `acl`) on the host; already present on this machine.
- **Host keys:** generated fresh per container, on its first start, by
  `docker/orca-docker-ssh-entrypoint.sh` (`ssh-keygen -A`) — never baked
  into an image, never reused across containers. `docker-create.sh` reads
  the new container's public key through a *trusted local* `docker exec`
  (never `ssh-keyscan`) and records it in `~/.ssh/known_hosts` under
  `[127.0.0.1]:<published-port>`, replacing only that exact endpoint's
  stale entry if the port was reused. `docker-destroy.sh` removes that
  known_hosts entry again, but only if it still matches the container
  being destroyed.
- **Identity key:** an SSH keypair generated once on first use and reused
  after, stored *outside* the repo entirely, at
  `${XDG_STATE_HOME:-~/.local/state}/orca-local-docker-sandbox/<hash of
  this worktree's scripts/orca-vm path>/`. Deliberately not repo-local:
  `docker-create.sh` recursively grants the whole bind-mounted worktree a
  *default* ACL entry (see above), which any new file created under the
  worktree inherits — a key generated inside the tree picks up that grant
  and OpenSSH then refuses to load it ("bad permissions"). This broke the
  first live `--provision` run for real; see "Lessons" below.

### Security properties (all enforced in `docker-create.sh`)

- One container per workspace; `docker-destroy.sh` always `docker rm -f`s it.
- SSH published as `-p 127.0.0.1::22` — loopback-only, random host port.
- Session user is `agent` (non-root); `sshd_config.d/orca.conf` sets
  `PermitRootLogin no` and `AllowUsers agent`.
- No bind mount of the host home directory, or of `~/.claude`, `~/.codex`,
  `~/.ssh`, `~/.aws`, `~/.kube`, or `~/.gnupg` — the *only* mount is the
  workspace's own worktree.
- `/var/run/docker.sock` is never mounted.
- Never `--privileged`, `--network=host`, or `--pid=host` — not present
  anywhere in these scripts.
- Resource caps on every container: `--memory 8g --memory-swap 8g`
  (no extra swap beyond the 8 GB), `--cpus 4`, `--pids-limit 512`.
- `--security-opt no-new-privileges` on every container.

### Operating it

Run these from the repo root (or let Orca invoke `create`/`suspend`/
`resume`/`destroy` itself — it already sets the working directory).

```bash
# One-time / after editing docker/Dockerfile.base:
./scripts/orca-vm/docker-base-snapshot.sh       # builds the base image

# One-time / whenever Codex's login expires — needs a real terminal:
./scripts/orca-vm/docker-base-auth.sh           # interactive device-auth login, commits the auth image

# Validate orca.yaml wiring (static, free, boots nothing):
ORCA vm recipe doctor local-docker-sandbox --repo-path . --json
# ORCA = orca-ide / orca-dev / orca, whichever this session resolved
# (see the orca-per-workspace-env skill's discovery stub).

# Full live self-test (boots a real container, validates the result, tears it down):
ORCA vm recipe doctor local-docker-sandbox --repo-path . --provision --json
```

`docker-state.json` (gitignored) threads the Docker context name and
image tags between these scripts. It's local-machine state, not shared —
every teammate builds their own base and auth images.

**The "Run on" picker in the Orca app only reads `orca.yaml` from the
*primary* checkout** (`orca repo show` / `git worktree list` tells you
which path that is), not from whatever worktree you happen to be editing
it in. If a recipe you just added doesn't show up there, it's almost
always this: commit it in the worktree, then in the primary checkout
`git merge --ff-only <that-branch>` (or pull/checkout as appropriate) —
don't just add more to orca.yaml assuming it's not being picked up.
Bit us the first time: this repo's primary checkout was on `master` while
the working worktree was on a separate `main`, so the recipe was
invisible until fast-forwarded across.

### Status

Done and verified: scaffolding, the base image, Codex auth inside the
sandbox, and a live `--provision` self-test all pass (recipe boots,
connects over SSH as `agent`, writes through the bind mount, tears down
cleanly). Merged onto the primary checkout's branch and confirmed visible
in the Orca app's "Run on" picker. Ready to use for a real workspace.

### Lessons from the first live `--provision` run

The static doctor only validates `orca.yaml` wiring; it never boots
anything, so none of these surfaced until the real self-test ran. Fixed,
but worth knowing if something in this area changes later:

1. **cwd captured after `cd`.** `docker-create.sh` needs its own script
   directory as cwd (to `source ./docker-lib.sh` reliably) but also needs
   the *original* invocation directory (the workspace's checkout) for the
   bind-mount source. Capture the original `$(pwd)` *before* the `cd`, not
   after — grabbing it after just returns the script's own directory.
2. **Worktrees have a `.git` file, not directory.** A sanity check of
   `[ -d "$host_project_root/.git" ]` rejects every Orca-managed linked
   worktree, which is the default, expected checkout shape. Use
   `git -C "$host_project_root" rev-parse --is-inside-work-tree` instead.
3. **The identity key can't live inside the bind-mounted tree.** See
   "Identity key" above — a *default* ACL entry applies to files created
   after the grant too, so ordering doesn't help; the key has to be
   somewhere the recipe never mounts or ACL-grants.

If `--provision` fails again, read `provisionTranscript` in its JSON
output before guessing — it has the exact stderr from the failing stage.

## Working conventions

- Both Codex CLI and Claude Code should read this file first in this
  repo and keep it current as the project grows beyond this scaffold.
- Local-side scripts under `scripts/orca-vm/` run on the host (bash,
  `set -euo pipefail`); only the *final* JSON object goes to stdout,
  everything else to stderr — don't add stray `echo`s to those files.
