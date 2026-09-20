#!/usr/bin/env bash
# Builds the base image for the local-docker-sandbox recipe. Run this
# by hand (it is not wired into orca.yaml) whenever docker/Dockerfile.base
# changes, then run docker-base-auth.sh to produce the authenticated
# image that docker-create.sh actually boots. See AGENTS.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./docker-lib.sh
source ./docker-lib.sh

docker_context="$(resolve_docker_context)"
base_image="$(env_or_state ORCA_DOCKER_BASE_IMAGE baseImage "$BASE_IMAGE_DEFAULT")"

log "Building base image '$base_image' on Docker context '$docker_context'..."
docker --context "$docker_context" build \
  --build-arg "AGENT_UID=$AGENT_UID" \
  --build-arg "AGENT_GID=$AGENT_GID" \
  -f docker/Dockerfile.base \
  -t "$base_image" \
  docker >&2

log "Smoke-checking installed tools..."
# --entrypoint overrides the image's sshd entrypoint for this one-off
# check; without it, `bash -lc '...'` would just be passed as arguments
# to orca-docker-ssh-entrypoint, which ignores them and execs sshd
# forever, hanging this script.
docker --context "$docker_context" run --rm --entrypoint bash "$base_image" -lc \
  'set -e; git --version; ssh -V; curl --version | head -1; jq --version; codex --version' >&2

state_merge "$(jq -n --arg ctx "$docker_context" --arg img "$base_image" \
  '{dockerContext: $ctx, baseImage: $img}')"
