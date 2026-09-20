#!/usr/bin/env bash
# `suspend` for the local-docker-sandbox recipe. Orca passes lifecycle
# JSON on stdin; see AGENTS.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./docker-lib.sh
source ./docker-lib.sh

payload="$(cat)"
resource_id="$(jq -r '.recipeResult.userData.resourceId // empty' <<<"$payload")"
docker_context="$(jq -r '.recipeResult.userData.dockerContext // empty' <<<"$payload")"
[ -n "$resource_id" ] || die "No resourceId in lifecycle payload."
[ -n "$docker_context" ] || docker_context="$(resolve_docker_context)"

log "Stopping '$resource_id'..."
docker --context "$docker_context" stop "$resource_id" >&2
