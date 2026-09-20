#!/usr/bin/env bash
# Produces the authenticated image docker-create.sh boots per workspace:
# starts a throwaway container from the base image, has YOU log Codex in
# interactively inside it, verifies the login, then commits the result.
#
# Run this yourself, directly in your own terminal (not through an
# agent's non-interactive shell) -- step 2 needs a real TTY. In Claude
# Code you can also run it in-session with the bang prefix: `! ./scripts/orca-vm/docker-base-auth.sh`.
#
# Codex authenticates *inside* the container. Nothing here reads or
# copies host Codex credentials (e.g. ~/.codex) into the image. See
# AGENTS.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./docker-lib.sh
source ./docker-lib.sh

docker_context="$(resolve_docker_context)"
base_image="$(env_or_state ORCA_DOCKER_BASE_IMAGE baseImage "$BASE_IMAGE_DEFAULT")"
auth_image="$(env_or_state ORCA_DOCKER_AUTH_IMAGE authImage "$AUTH_IMAGE_DEFAULT")"
auth_name="orca-local-docker-sandbox-auth-$$"

docker --context "$docker_context" image inspect "$base_image" >/dev/null 2>&1 \
  || die "Base image '$base_image' not found on context '$docker_context'. Run docker-base-snapshot.sh first."

cleanup() {
  docker --context "$docker_context" rm -f "$auth_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Starting a throwaway container '$auth_name' from '$base_image'..."
docker --context "$docker_context" run -d --name "$auth_name" \
  --security-opt no-new-privileges \
  --pids-limit "$CONTAINER_PIDS_LIMIT" \
  "$base_image" >&2

log ""
log "Follow the device-auth URL and code Codex prints below, then complete the"
log "login in your browser. This runs as the non-root 'agent' user inside the container."
log ""
docker --context "$docker_context" exec -it --user agent -w "/home/$AGENT_USER" "$auth_name" \
  codex login --device-auth

log "Verifying login..."
status_output="$(docker --context "$docker_context" exec --user agent "$auth_name" codex login status 2>&1)" \
  && status_exit=0 || status_exit=$?
printf '%s\n' "$status_output" >&2
if [ "$status_exit" -ne 0 ] || ! grep -Eq 'Logged in using ChatGPT|Logged in via device' <<<"$status_output"; then
  die "Codex does not report as logged in (exit=$status_exit); refusing to snapshot an unauthenticated image. Re-run this script and complete the login."
fi

log "Committing authenticated image '$auth_image'..."
# --change is a safety net, not strictly needed here (the container's
# PID1 was never replaced by an interactive shell -- only `exec`'d into
# for the login), matching references/docker-ssh.md's guidance for
# anyone who later adapts this to an interactive-shell auth flow.
docker --context "$docker_context" commit \
  --change='ENTRYPOINT ["/usr/local/bin/orca-docker-ssh-entrypoint"]' \
  "$auth_name" "$auth_image" >&2

state_merge "$(jq -n --arg ctx "$docker_context" --arg base "$base_image" --arg auth "$auth_image" \
  '{dockerContext: $ctx, baseImage: $base, authImage: $auth}')"
