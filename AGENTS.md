# AGENTS.md

Shared context for Codex CLI and Claude Code working in this repo. Keep
this file up to date for both — it's the handoff point between them.

## Repo status

`orca-secure-sandbox` (originally scaffolded as `open-data-platform`,
renamed once its real purpose became clear) is a reusable, security-
focused per-workspace environment recipe for Orca — meant as a starting
point for *other* projects' dev sandboxes, not a one-off app. Public at
https://github.com/hevertoncss/orca-secure-sandbox. It has no
application code of its own beyond the recipe: `local-docker-sandbox` —
see below.

## `local-docker-sandbox` environment recipe

Defined in `orca.yaml`, implemented in `scripts/orca-vm/`. It gives each
Orca workspace its own ephemeral, SSH-reachable Docker container on this
machine, running Codex CLI as a non-root user, with this project's own
repo freshly cloned inside.

### How it works

- **Provider:** local Docker, always addressed through the host's
  **rootless** context (`docker --context <ctx> ...`). `docker-lib.sh`'s
  `resolve_docker_context` finds it by checking `SecurityOptions` for
  `name=rootless` (never trusts a context just because it's *named*
  "rootless") and fails loudly if none exists.
- **Connection mode:** SSH, not `orca serve`. `docker-create.sh` emits a
  `connection.type: "ssh"` block; Orca's SSH relay dials in.
- **Checkout mode: `provisioned-root`.** `orca.yaml` declares
  `checkoutMode: provisioned-root` — one ephemeral machine per workspace
  that provisions the finished checkout itself, rather than Orca
  layering its own `git worktree add` on top of what the recipe returns.
  This is **not** the default and took a real failure to learn: see
  "Why provisioned-root, not a bind mount" below. `docker-create.sh`
  checks `ORCA_RECIPE_RESULT_SCHEMA_VERSION=2` and fails loudly rather
  than silently falling back to the ordinary shape if it's ever missing.
- **Repo access: clone, not bind-mount.** On a container's first boot,
  `docker/orca-docker-ssh-entrypoint.sh` clones this project's own repo
  directly into `/workspace`, using `ORCA_REPO_URL` / `ORCA_REPO_REF` /
  `ORCA_REPO_REF_HEAD` / `ORCA_REPO_BRANCH` that `docker-create.sh` reads
  from its own environment (Orca supplies these for a provisioned-root
  recipe) and passes into the container as `-e` vars:
  ```bash
  git fetch "$ORCA_REPO_URL" "$ORCA_REPO_REF" || git fetch "$ORCA_REPO_URL" "$ORCA_REPO_REF_HEAD"
  git cat-file -e "${ORCA_REPO_REF_HEAD}^{commit}"
  git checkout -B "$ORCA_REPO_BRANCH" "$ORCA_REPO_REF_HEAD"
  ```
  The first fetch attempt is optimistic — see "Lessons" #7 below for why
  it falls back to fetching the pinned commit by SHA directly.
  Only on first boot — a *resume* (container restart) must never re-run
  this, or it would blow away whatever the agent has done since. Files
  end up natively owned by `agent` (the clone runs as root inside the
  entrypoint, then everything under `/workspace` is `chown`'d to
  `agent`), so none of the old bind-mount/rootless-uid-mapping ACL
  machinery is needed any more — removed from `docker-lib.sh`.
  `ORCA_REPO_URL` may arrive as an SSH-style URL
  (`git@github.com:owner/repo.git`); `docker-create.sh` rewrites it to
  HTTPS before passing it in, since auth is token-based (see next).
- **Push credentials.** The container authenticates to GitHub over
  HTTPS with a token, via git's built-in `credential.helper store`
  (persists for the container's whole lifetime, unlike the
  fetch-then-`rm` pattern used for a one-shot *build-time* clone — this
  container needs push access for the agent's entire dev session, not
  just an initial checkout). `docker-create.sh` reads `GH_TOKEN` or
  `GITHUB_TOKEN` from its own environment — **deliberately not** falling
  back to the operator's own `gh auth token`, since that would hand the
  sandboxed agent the same broad, multi-repo access as the human's own
  session. Use a fine-grained GitHub PAT scoped to just this repo
  (Settings → Contents → Read and write). Missing token → a clear
  stderr warning, not a hard failure: the container still works for a
  public repo's read access, just not push. Never logged, never written
  to `docker-state.json`, never baked into an image layer — lives only
  in the ephemeral container's own `~/.git-credentials` in plaintext
  (standard git credential-store format; the container is single-tenant
  and destroyed with the workspace) for the container's lifetime.
- **Images as snapshots:** local Docker has no cloud-style VM snapshot,
  so a tagged image plays that role. `docker-base-snapshot.sh` builds
  `orca-local-docker-sandbox-base` from `docker/Dockerfile.base`.
  `docker-base-auth.sh` boots it, has a human log Codex in interactively
  *inside the container*, verifies the login, and commits
  `orca-local-docker-sandbox-auth` — the image `docker-create.sh` boots
  per workspace. Host Codex credentials (e.g. `~/.codex`) are never read
  or copied into the image; the image only ever holds credentials from a
  login performed inside a container.
  **`orca-local-docker-sandbox-auth` itself contains live Codex
  credentials — never `docker push`/publish that image to any registry,
  public or private outside your own control.** This is about the built
  image, not this git repo: nothing in the repo's tracked files holds
  credentials, and images aren't git-tracked at all in this design.
- **Host keys:** generated fresh per container, on its first start, by
  the entrypoint (`ssh-keygen -A`) — never baked into an image, never
  reused across containers. `docker-create.sh` reads the new container's
  public key through a *trusted local* `docker exec` (never
  `ssh-keyscan`) and records it in `~/.ssh/known_hosts` under
  `[127.0.0.1]:<published-port>`, replacing only that exact endpoint's
  stale entry if the port was reused. `docker-destroy.sh` removes that
  known_hosts entry again, but only if it still matches the container
  being destroyed.
- **Identity key:** an SSH keypair generated once on first use and
  reused after, stored outside the repo entirely, at
  `${XDG_STATE_HOME:-~/.local/state}/orca-local-docker-sandbox/<hash of
  this worktree's scripts/orca-vm path>/`.

### Why provisioned-root, not a bind mount

The recipe's first working version bind-mounted the workspace's own
worktree into the container instead of cloning. It got all the way
through a live `--provision` self-test, then broke on a *real* Orca
workspace in two more stages:

1. A linked worktree's `.git` is a pointer to an absolute path in the
   primary checkout's real git dir — invisible inside a container that
   only mounts the worktree itself. Mounting that path too (in-place)
   fixed `git` failing entirely.
2. Once Orca recognized the project by a real git remote (see "Lessons"
   below on the remote-identity requirement), it stopped trusting
   `docker-create.sh`'s `/workspace` outright and instead tried its
   *normal* SSH-mode behavior: treat the target as a persistent, shared
   host and run `git worktree add` on it for each new workspace — which
   fails outright in a container that's already dedicated to exactly one
   workspace, at exactly one path.

`checkoutMode: provisioned-root` is the mode documented for precisely
this shape — "one ephemeral machine that provisions the finished
checkout itself" — and it expects a git **clone**, not a bind mount, so
that's what this recipe now does. The bind-mount design is gone; there's
nothing left of it to fall back to.

### Security properties (all enforced in `docker-create.sh` /
`docker/orca-docker-ssh-entrypoint.sh`)

- One container per workspace; `docker-destroy.sh` always `docker rm -f`s it.
- SSH published as `-p 127.0.0.1::22` — loopback-only, random host port.
- Session user is `agent` (non-root); `sshd_config.d/orca.conf` sets
  `PermitRootLogin no` and `AllowUsers agent`.
- **No bind mounts at all** — the repo arrives by clone, not by exposing
  any host path. In particular, never the host home directory, or
  `~/.claude`, `~/.codex`, `~/.ssh`, `~/.aws`, `~/.kube`, `~/.gnupg`, or
  `/var/run/docker.sock`.
- Never `--privileged`, `--network=host`, or `--pid=host` — not present
  anywhere in these scripts.
- Resource caps on every container: `--memory 8g --memory-swap 8g`
  (no extra swap beyond the 8 GB), `--cpus 4`, `--pids-limit 512`.
- `--security-opt no-new-privileges` on every container.
- The GitHub push credential is a repo-scoped fine-grained PAT, supplied
  fresh per `create` call, never persisted outside the ephemeral
  container it's used in.

### Operating it

Run these from the repo root (or let Orca invoke `create`/`suspend`/
`resume`/`destroy` itself — it already sets the working directory and
supplies the `ORCA_REPO_*` / `ORCA_RECIPE_RESULT_SCHEMA_VERSION` env vars).

```bash
# One-time / after editing docker/Dockerfile.base or the entrypoint:
./scripts/orca-vm/docker-base-snapshot.sh       # builds the base image

# One-time / whenever Codex's login expires — needs a real terminal:
./scripts/orca-vm/docker-base-auth.sh           # interactive device-auth login, commits the auth image

# Validate orca.yaml wiring (static, free, boots nothing):
ORCA vm recipe doctor local-docker-sandbox --repo-path . --json
# ORCA = orca-ide / orca-dev / orca, whichever this session resolved
# (see the orca-per-workspace-env skill's discovery stub).
```

`ORCA vm recipe doctor ... --provision` does **not** currently simulate
the `ORCA_REPO_*` env vars for a provisioned-root recipe, so it fails
fast with a clear "not set" error rather than testing anything — a known
gap in the local tooling, not a bug in this recipe. To test the actual
clone/push path by hand:

```bash
head_sha="$(git -C <primary-checkout-path> rev-parse master)"
ORCA_RECIPE_RESULT_SCHEMA_VERSION=2 \
ORCA_REPO_URL="git@github.com:hevertoncss/orca-secure-sandbox.git" \
ORCA_REPO_REF="some-test-branch" \
ORCA_REPO_REF_HEAD="$head_sha" \
ORCA_REPO_BRANCH="some-test-branch" \
GH_TOKEN="$(cat /path/to/a/token/file)" \
./scripts/orca-vm/docker-create.sh
```
(`ORCA_REPO_REF` deliberately set to a branch name that doesn't exist
upstream here, matching what a real workspace creation actually sends —
see "Lessons" #7. The fetch-by-SHA fallback is what's really being
tested.)
Then feed the printed `resourceId`/`dockerContext` to `docker-destroy.sh`
(as `{"recipeResult":{"userData":{...}}}` on stdin) to tear it down.

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

**Orca also needs the project to have a real git remote to trust a
non-local environment for it at all.** `orca repo list --json` shows
`gitRemoteIdentity: null` for a project imported from a bare local
folder; Orca then has no location-independent way to confirm "the
folder this SSH target reports really is the selected project," and
`projectHostSetups:setupExistingFolder` fails with "Imported folder does
not match the selected project identity." Fixed here by actually adding
a remote (`git@github.com:hevertoncss/orca-secure-sandbox.git`) — but
**Orca appears to cache `gitRemoteIdentity` and doesn't pick up a
newly-added remote automatically; restarting Orca was what made it
notice.** If a fresh remote still doesn't seem to register, that's the
first thing to try before assuming the recipe itself is broken.

### Status

Done and verified end-to-end: scaffolding, the base image, Codex auth
inside the sandbox, and a manual clone-and-push test (real commit, real
`git push` to a throwaway branch, since the local `--provision` tooling
can't simulate `ORCA_REPO_*` — see above) all pass. Merged onto the
primary checkout's branch, pushed to GitHub, and confirmed visible in
the Orca app's "Run on" picker after a restart. Ready to use for a real
workspace.

### Lessons from live testing

The static doctor only validates `orca.yaml` wiring; it never boots
anything, so none of these surfaced until either `--provision` or a real
Orca workspace exercised the scripts for real.

1. **cwd captured after `cd`.** A script needs its own script directory
   as cwd (to `source ./docker-lib.sh` reliably) but also needs the
   *original* invocation directory for anything relative to where Orca
   invoked it from. Capture the original `$(pwd)` *before* the `cd`, not
   after.
2. **Worktrees have a `.git` file, not directory.** Never assume
   `[ -d "$path/.git" ]` — Orca's default per-workspace checkout is a
   linked worktree, where `.git` is a pointer file. Ask git itself
   (`git -C "$path" rev-parse --is-inside-work-tree`) instead.
3. **`docker-state.json` is worktree-local, but Docker images aren't.**
   Orca creates a fresh worktree per workspace; only the *first*
   worktree (the one `docker-base-auth.sh` was actually run in) has a
   `docker-state.json` recording `authImage`, since that file is
   gitignored and never committed. Fall back to a fixed default tag
   name, not `""` — the image exists in the shared Docker daemon
   regardless of which worktree asks — and let `docker image inspect`
   be the real existence check.
4. **A bind-mounted linked worktree needed its primary checkout's `.git`
   mounted too**, and even then, git's dubious-ownership check still
   refused it (the mounted files' apparent owner, through rootless
   Docker's uid mapping, didn't match `agent`'s own uid from inside its
   own namespace). Both fully moot now — see "Why provisioned-root, not
   a bind mount" above — but the general shape (a `--provision` run from
   one worktree can look clean while a *different* worktree, or a real
   Orca workspace, hits an entirely different failure) is the recurring
   pattern worth remembering here.
5. **A project needs a real git remote before Orca will trust a
   non-local environment for it, and Orca may need a restart to notice
   a newly-added one.** See the "Run on" picker note above.
6. **Once a real remote exists, Orca's SSH mode assumes it can run its
   own `git worktree add` on the target** — a persistent-host model,
   not an ephemeral-one-checkout-per-workspace model. That's what forced
   the move to `checkoutMode: provisioned-root` (see above) rather than
   a smaller patch.
7. **`ORCA_REPO_REF` isn't reliably a ref the remote actually has.** The
   guide describing provisioned-root fetches `$ORCA_REPO_URL`
   `$ORCA_REPO_REF` directly, implying it names an existing base branch.
   In practice it arrived as the *new workspace's own branch name*
   (e.g. `test-sandbox`), which by definition doesn't exist upstream yet
   — `git fetch` failed with "couldn't find remote ref". The entrypoint
   now tries `$ORCA_REPO_REF` first, and on failure falls back to
   fetching `$ORCA_REPO_REF_HEAD` directly by SHA (verified GitHub
   allows this for a public repo). The pinned commit is the one thing
   actually guaranteed; don't depend on the ref name resolving.
8. **The auth image's entrypoint now requires `ORCA_REPO_*` env vars on
   first boot** (that's the whole point), which broke the hot-patch
   maintenance flow (`docker run -d --name x "$auth_image"` with no
   extra vars, used to copy in a fixed entrypoint without redoing the
   Codex login) — the container died immediately on the missing vars
   before it could be `cp`'d into. Fix: override the entrypoint for that
   one maintenance container (`docker run --entrypoint sleep "$auth_image"
   infinity`), patch, commit, remove — never invoke the real entrypoint
   for a patch-only container.

If `--provision` (or a manual `docker-create.sh` run) fails, read
stderr/`provisionTranscript` before guessing — it has the exact point of
failure. But note lesson 4's general pattern: a clean run from *this*
worktree, or *this* set of env vars, doesn't prove a different one will
work too.

## Working conventions

- Both Codex CLI and Claude Code should read this file first in this
  repo and keep it current as the project grows beyond this scaffold.
- Local-side scripts under `scripts/orca-vm/` run on the host (bash,
  `set -euo pipefail`); only the *final* JSON object goes to stdout,
  everything else to stderr — don't add stray `echo`s to those files.
