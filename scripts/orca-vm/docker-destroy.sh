#!/usr/bin/env bash
# `destroy` for the local-docker-sandbox recipe. Orca passes lifecycle
# JSON on stdin; must actually remove the container (ephemeral-per-
# workspace requirement). May run after the workspace's own worktree is
# already gone, so it relies only on the stdin payload, never on cwd.
# See AGENTS.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./docker-lib.sh
source ./docker-lib.sh

payload="$(cat)"
resource_id="$(jq -r '.recipeResult.userData.resourceId // empty' <<<"$payload")"
docker_context="$(jq -r '.recipeResult.userData.dockerContext // empty' <<<"$payload")"
[ -n "$resource_id" ] || die "No resourceId in lifecycle payload."
[ -n "$docker_context" ] || docker_context="$(resolve_docker_context)"

if docker --context "$docker_context" inspect "$resource_id" >/dev/null 2>&1; then
  port="$(docker --context "$docker_context" port "$resource_id" 22/tcp 2>/dev/null | tail -1 | sed -E 's/.*:([0-9]+)$/\1/' || true)"
  if [ -n "$port" ]; then
    key_data="$(docker --context "$docker_context" exec "$resource_id" \
      sh -c "awk '{print \$2}' /etc/ssh/ssh_host_ed25519_key.pub" 2>/dev/null || true)"
    if [ -n "$key_data" ]; then
      log "Removing known_hosts entry for [127.0.0.1]:$port if it still matches '$resource_id'..."
      forget_known_host_if_matches "127.0.0.1" "$port" "$key_data"
    fi
  fi
else
  log "'$resource_id' is already gone; skipping known_hosts cleanup."
fi

log "Removing '$resource_id'..."
docker --context "$docker_context" rm -f "$resource_id" >&2
