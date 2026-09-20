#!/usr/bin/env bash
# Per-workspace `create` for the local-docker-sandbox recipe. Invoked by
# Orca with the workspace's own checkout as the working directory. Prints
# exactly one SSH-connection recipe-result JSON object to stdout; all
# progress and errors go to stderr. See AGENTS.md.
set -euo pipefail
# Captured before the cd below, which is only so ./docker-lib.sh sources
# reliably regardless of invocation cwd -- this is what must survive as
# the bind-mount source (see the comment further down).
_invocation_dir="$(pwd)"
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./docker-lib.sh
source ./docker-lib.sh

docker_context="$(resolve_docker_context)"
# Falls back to the fixed default tag, not "" -- docker-state.json is
# gitignored and worktree-local, so a *different* workspace's worktree
# (Orca creates a fresh one per workspace) never has it, even though the
# image itself already exists and is shared by the whole Docker daemon.
# The image-inspect check right below is the real existence check.
auth_image="$(env_or_state ORCA_DOCKER_AUTH_IMAGE authImage "$AUTH_IMAGE_DEFAULT")"
docker --context "$docker_context" image inspect "$auth_image" >/dev/null 2>&1 \
  || die "Authenticated image '$auth_image' not found on context '$docker_context'. Run docker-base-snapshot.sh then docker-base-auth.sh first."

# The bind-mount source is always THIS invocation's own workspace
# checkout -- deliberately never read from state, because state is
# shared across every workspace while each workspace has its own
# worktree. Orca runs `create` with that worktree as the working
# directory; ORCA_PROJECT_ROOT is an override for manual testing.
host_project_root="${ORCA_PROJECT_ROOT:-$_invocation_dir}"
# Not `[ -d .git ]`: a linked worktree (Orca's default per-workspace
# checkout) has a .git *file* pointing at the real gitdir, not a
# directory. Ask git itself so both shapes work.
git -C "$host_project_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "host_project_root '$host_project_root' doesn't look like a git checkout. Refusing to bind-mount it."

# A linked worktree's .git is a *pointer file* containing an absolute
# host path into the primary checkout's real git dir (objects, refs,
# HEAD, index for this worktree) -- none of that lives inside
# host_project_root itself. Bind-mounting only host_project_root leaves
# that pointer dangling inside the container, so git (and Orca's own
# "is this a real repo" check) fails there even though it's a perfectly
# valid worktree on the host. Fix: mount the common git dir too, at the
# *same* absolute path, so the pointer still resolves inside the
# container. Not needed for a plain (non-worktree) clone, where the
# common dir is already inside host_project_root and thus already
# covered by the main mount above.
git_common_dir="$(git -C "$host_project_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
if [ -n "$git_common_dir" ] && [ "$git_common_dir" != "$host_project_root/.git" ]; then
  log "Linked worktree detected; will also mount its shared git dir at $git_common_dir (see AGENTS.md)."
else
  git_common_dir=""
fi

recipe_id="$(sanitize_name_component "${ORCA_RECIPE_ID:-$RECIPE_ID}")"
instance_id="$(sanitize_name_component "${ORCA_VM_INSTANCE_ID:-$(date +%s)-$$}")"
name="orca-${recipe_id}-${instance_id}"

ensure_identity_key
pubkey="$(cat "${IDENTITY_FILE}.pub")"

log "Granting the container's agent user access to $host_project_root (POSIX ACL; see AGENTS.md)..."
grant_agent_acl "$host_project_root" grant
if [ -n "$git_common_dir" ]; then
  log "Granting the container's agent user access to $git_common_dir too..."
  grant_agent_acl "$git_common_dir" grant
fi

extra_mount_args=()
if [ -n "$git_common_dir" ]; then
  extra_mount_args+=(--mount "type=bind,source=${git_common_dir},target=${git_common_dir}")
fi

cleanup_on_error() {
  local ec=$?
  if [ "$ec" -ne 0 ]; then
    log "create failed (exit $ec); removing '$name'..."
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
  --mount "type=bind,source=${host_project_root},target=${CONTAINER_PROJECT_ROOT}" \
  "${extra_mount_args[@]}" \
  -e "ORCA_SSH_PUBLIC_KEY=${pubkey}" \
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

log "Verifying SSH login as '$AGENT_USER', bind-mount write access, and that git actually works there..."
remote_check="id -un && touch ${CONTAINER_PROJECT_ROOT}/.orca-write-check && rm -f ${CONTAINER_PROJECT_ROOT}/.orca-write-check && echo ORCA_SSH_OK && git -C ${CONTAINER_PROJECT_ROOT} rev-parse --is-inside-work-tree && echo ORCA_GIT_OK"
verify_out=""
for _ in $(seq 1 40); do
  if verify_out="$(ssh -i "$IDENTITY_FILE" -p "$port" \
        -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes \
        "${AGENT_USER}@127.0.0.1" "$remote_check" 2>&1)"; then
    break
  fi
  sleep 0.5
done
printf '%s\n' "$verify_out" >&2
grep -qx "$AGENT_USER" <<<"$verify_out" || die "SSH session did not authenticate as '$AGENT_USER'. Output above."
grep -q '^ORCA_SSH_OK$' <<<"$verify_out" || die "SSH connected but couldn't write to ${CONTAINER_PROJECT_ROOT} (the bind-mount ACL grant likely failed). Output above."
grep -q '^ORCA_GIT_OK$' <<<"$verify_out" || die "SSH connected but git doesn't see ${CONTAINER_PROJECT_ROOT} as a repo inside the container (the linked-worktree git-common-dir mount likely failed). Output above."

jq -n \
  --arg root "$CONTAINER_PROJECT_ROOT" \
  --arg host "127.0.0.1" \
  --argjson port "$port" \
  --arg user "$AGENT_USER" \
  --arg idf "$IDENTITY_FILE" \
  --arg label "$name" \
  --arg ctx "$docker_context" \
  --arg hostRoot "$host_project_root" \
  --arg gitCommon "$git_common_dir" \
  '{
    schemaVersion: 1,
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
      dockerContext: $ctx,
      hostProjectRoot: $hostRoot,
      gitCommonDir: $gitCommon
    }
  }'

trap - EXIT
