#!/usr/bin/env bash
# `resume` for the local-docker-sandbox recipe. Orca passes lifecycle
# JSON on stdin and expects a fresh recipe-result JSON object back on
# stdout, since the published SSH port can change across a stop/start.
# See AGENTS.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./docker-lib.sh
source ./docker-lib.sh

payload="$(cat)"
resource_id="$(jq -r '.recipeResult.userData.resourceId // empty' <<<"$payload")"
docker_context="$(jq -r '.recipeResult.userData.dockerContext // empty' <<<"$payload")"
host_project_root="$(jq -r '.recipeResult.userData.hostProjectRoot // empty' <<<"$payload")"
git_common_dir="$(jq -r '.recipeResult.userData.gitCommonDir // empty' <<<"$payload")"
[ -n "$resource_id" ] || die "No resourceId in lifecycle payload."
[ -n "$docker_context" ] || docker_context="$(resolve_docker_context)"

log "Starting '$resource_id'..."
docker --context "$docker_context" start "$resource_id" >&2

ensure_identity_key

port="$(docker --context "$docker_context" port "$resource_id" 22/tcp | tail -1 | sed -E 's/.*:([0-9]+)$/\1/')"
[ -n "$port" ] || die "Could not read the published SSH port for '$resource_id' after resume."

host_key_line=""
for _ in $(seq 1 40); do
  host_key_line="$(docker --context "$docker_context" exec "$resource_id" cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null || true)"
  [ -n "$host_key_line" ] && break
  sleep 0.25
done
[ -n "$host_key_line" ] || die "Container '$resource_id' has no SSH host key after resume."

key_type="$(awk '{print $1}' <<<"$host_key_line")"
key_data="$(awk '{print $2}' <<<"$host_key_line")"
record_known_host "127.0.0.1" "$port" "[127.0.0.1]:${port} ${key_type} ${key_data}"

jq -n \
  --arg root "$CONTAINER_PROJECT_ROOT" \
  --arg host "127.0.0.1" \
  --argjson port "$port" \
  --arg user "$AGENT_USER" \
  --arg idf "$IDENTITY_FILE" \
  --arg label "$resource_id" \
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
