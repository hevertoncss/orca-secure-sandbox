#!/usr/bin/env bash
# Per-workspace `create` for the local-docker-sandbox recipe, in
# checkoutMode: provisioned-root -- one ephemeral container per
# workspace that clones the project's own repo itself (see AGENTS.md
# for why this replaced the original bind-mount design: Orca's normal
# SSH mode expects to manage worktrees ON the target itself, which
# conflicts with a fresh, single-purpose container per workspace).
# Prints exactly one schemaVersion 2 recipe-result JSON object to
# stdout; all progress and errors go to stderr.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./docker-lib.sh
source ./docker-lib.sh

[ "${ORCA_RECIPE_RESULT_SCHEMA_VERSION:-}" = "2" ] \
  || die "This recipe requires checkoutMode: provisioned-root (ORCA_RECIPE_RESULT_SCHEMA_VERSION=2). Got '${ORCA_RECIPE_RESULT_SCHEMA_VERSION:-<unset>}'. Check orca.yaml."

repo_url="${ORCA_REPO_URL:?ORCA_REPO_URL not set -- Orca should supply this for a provisioned-root recipe}"
repo_ref="${ORCA_REPO_REF:?ORCA_REPO_REF not set}"
repo_ref_head="${ORCA_REPO_REF_HEAD:?ORCA_REPO_REF_HEAD not set}"
repo_branch="${ORCA_REPO_BRANCH:?ORCA_REPO_BRANCH not set}"

# The container authenticates over HTTPS with a token (see below), not
# an SSH key, so normalize an SSH-style URL (git@host:owner/repo.git)
# to HTTPS. Already-HTTPS URLs pass through unchanged.
case "$repo_url" in
  git@*)
    repo_url="$(printf '%s' "$repo_url" | sed -E 's#^git@([^:]+):#https://\1/#')"
    ;;
esac

# Deliberately narrower than the general env->state->`gh auth token`
# pattern: this token ends up inside an ephemeral sandbox container, so
# it should be a credential scoped to just this repo (a fine-grained
# PAT), not the operator's own broad personal `gh` session. Warn, don't
# fail -- a token-less container still works for a public repo's read
# access, just not push. See AGENTS.md.
gh_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[ -n "$gh_token" ] || log "WARNING: no GH_TOKEN/GITHUB_TOKEN set; the container will be able to fetch a public repo but not push."

docker_context="$(resolve_docker_context)"
# Falls back to the fixed default tag, not "" -- docker-state.json is
# gitignored and worktree-local, so a *different* workspace's worktree
# (Orca creates a fresh one per workspace) never has it, even though the
# image itself already exists and is shared by the whole Docker daemon.
# The image-inspect check right below is the real existence check.
auth_image="$(env_or_state ORCA_DOCKER_AUTH_IMAGE authImage "$AUTH_IMAGE_DEFAULT")"
docker --context "$docker_context" image inspect "$auth_image" >/dev/null 2>&1 \
  || die "Authenticated image '$auth_image' not found on context '$docker_context'. Run docker-base-snapshot.sh then docker-base-auth.sh first."

recipe_id="$(sanitize_name_component "${ORCA_RECIPE_ID:-$RECIPE_ID}")"
instance_id="$(sanitize_name_component "${ORCA_VM_INSTANCE_ID:-$(date +%s)-$$}")"
name="orca-${recipe_id}-${instance_id}"

ensure_identity_key
pubkey="$(cat "${IDENTITY_FILE}.pub")"

cleanup_on_error() {
  local ec=$?
  if [ "$ec" -ne 0 ]; then
    log "create failed (exit $ec); container logs for '$name' (may be empty if it never started):"
    docker --context "$docker_context" logs "$name" >&2 2>&1 || true
    log "removing '$name'..."
    docker --context "$docker_context" rm -f "$name" >/dev/null 2>&1 || true
  fi
}
trap cleanup_on_error EXIT

log "Starting ephemeral container '$name' on context '$docker_context'..."
docker --context "$docker_context" run -d \
  --name "$name" \
  --restart no \
  -p 127.0.0.1::22 \
  --memory "$CONTAINER_MEMORY" \
  --memory-swap "$CONTAINER_MEMORY" \
  --cpus "$CONTAINER_CPUS" \
  --pids-limit "$CONTAINER_PIDS_LIMIT" \
  --security-opt no-new-privileges \
  -e "ORCA_SSH_PUBLIC_KEY=${pubkey}" \
  -e "ORCA_REPO_URL=${repo_url}" \
  -e "ORCA_REPO_REF=${repo_ref}" \
  -e "ORCA_REPO_REF_HEAD=${repo_ref_head}" \
  -e "ORCA_REPO_BRANCH=${repo_branch}" \
  -e "GH_TOKEN=${gh_token}" \
  "$auth_image" >&2

port="$(docker --context "$docker_context" port "$name" 22/tcp | tail -1 | sed -E 's/.*:([0-9]+)$/\1/')"
[ -n "$port" ] || die "Could not read the published SSH port for '$name'."

log "Waiting for '$name' to generate its SSH host key..."
host_key_line=""
for _ in $(seq 1 40); do
  host_key_line="$(docker --context "$docker_context" exec "$name" cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null || true)"
  [ -n "$host_key_line" ] && break
  sleep 0.25
done
[ -n "$host_key_line" ] || { docker --context "$docker_context" logs "$name" >&2 || true; die "Container '$name' never produced an SSH host key; see logs above."; }

key_type="$(awk '{print $1}' <<<"$host_key_line")"
key_data="$(awk '{print $2}' <<<"$host_key_line")"
log "Recording the container's host key for [127.0.0.1]:$port in known_hosts (read via trusted docker exec, per AGENTS.md)..."
record_known_host "127.0.0.1" "$port" "[127.0.0.1]:${port} ${key_type} ${key_data}"

# sshd only execs once the entrypoint's clone step finishes, so a
# reachable SSH session already implies the clone succeeded -- no
# separate "wait for clone" step needed. A clone can take longer than
# host-key generation, though, so this retries for longer (up to ~60s).
log "Verifying SSH login as '$AGENT_USER' and that the repo was actually provisioned..."
remote_check="id -un && cd ${CONTAINER_PROJECT_ROOT} && git rev-parse --is-inside-work-tree && git rev-parse HEAD >/dev/null && git ls-remote origin >/dev/null && echo ORCA_GIT_OK"
verify_out=""
for _ in $(seq 1 60); do
  if verify_out="$(ssh -i "$IDENTITY_FILE" -p "$port" \
        -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes \
        "${AGENT_USER}@127.0.0.1" "$remote_check" 2>&1)"; then
    break
  fi
  # If the container itself has already exited (almost always because
  # the entrypoint's clone/checkout step failed under set -e, so sshd
  # never got exec'd), retrying the SSH connection for the rest of the
  # 60s is pointless -- bail now with the container's own logs, which
  # have the actual git error.
  status="$(docker --context "$docker_context" inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
  if [ "$status" != "running" ]; then
    docker --context "$docker_context" logs "$name" >&2 || true
    die "Container '$name' exited (status: ${status:-unknown}) before SSH ever came up; logs above."
  fi
  sleep 1
done
printf '%s\n' "$verify_out" >&2
grep -qx "$AGENT_USER" <<<"$verify_out" || die "SSH session did not authenticate as '$AGENT_USER'. Output above."
grep -q '^ORCA_GIT_OK$' <<<"$verify_out" || die "SSH connected but ${CONTAINER_PROJECT_ROOT} isn't a working repo with a reachable origin (clone/checkout/credentials likely failed -- check 'docker logs $name'). Output above."

jq -n \
  --arg root "$CONTAINER_PROJECT_ROOT" \
  --arg host "127.0.0.1" \
  --argjson port "$port" \
  --arg user "$AGENT_USER" \
  --arg idf "$IDENTITY_FILE" \
  --arg label "$name" \
  --arg ctx "$docker_context" \
  '{
    schemaVersion: 2,
    checkoutMode: "provisioned-root",
    connection: {
      type: "ssh",
      projectRoot: $root,
      target: {
        label: $label,
        host: $host,
        port: $port,
        username: $user,
        identityFile: $idf,
        identitiesOnly: true
      }
    },
    userData: {
      provider: "local-docker-ssh",
      resourceId: $label,
      dockerContext: $ctx
    }
  }'

trap - EXIT
