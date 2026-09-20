#!/usr/bin/env bash
# Shared helpers for the local-docker-sandbox recipe scripts.
# Sourced by every script in this directory; never executed directly.

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Fixed by design (see AGENTS.md). AGENT_UID/AGENT_GID must match the
# useradd call in docker/Dockerfile.base.
RECIPE_ID="local-docker-sandbox"
AGENT_USER="agent"
AGENT_UID=1000
AGENT_GID=1000
CONTAINER_PROJECT_ROOT="/workspace"
BASE_IMAGE_DEFAULT="orca-local-docker-sandbox-base:latest"
AUTH_IMAGE_DEFAULT="orca-local-docker-sandbox-auth:latest"
CONTAINER_MEMORY="8g"
CONTAINER_CPUS="4"
CONTAINER_PIDS_LIMIT="512"

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${ORCA_DOCKER_STATE_FILE:-$_lib_dir/docker-state.json}"

# Deliberately not under $_lib_dir (i.e. not inside the repo worktree),
# so it can never end up inside anything docker-create.sh manages on the
# container side. Hashing $_lib_dir keeps the location stable per
# worktree without needing one inside it.
_keys_root="${XDG_STATE_HOME:-$HOME/.local/state}/orca-local-docker-sandbox"
_lib_dir_hash="$(printf '%s' "$_lib_dir" | sha256sum | cut -c1-16)"
KEYS_DIR="${ORCA_DOCKER_KEYS_DIR:-$_keys_root/$_lib_dir_hash}"
IDENTITY_FILE="$KEYS_DIR/orca_docker_ssh"

state_init() {
  [ -f "$STATE_FILE" ] || printf '{}\n' > "$STATE_FILE"
}

state_get() {
  state_init
  jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE"
}

# Merges a JSON object ($1, a JSON string) into the state file and
# prints the resulting state to stdout -- scripts that end with this
# satisfy the "print only the state JSON to stdout" contract.
state_merge() {
  state_init
  local tmp
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  jq -s '.[0] * .[1]' "$STATE_FILE" <(printf '%s' "$1") > "$tmp"
  mv "$tmp" "$STATE_FILE"
  cat "$STATE_FILE"
}

# env_or_state NAME state_key [default]
# Resolves env -> state -> default, in that order.
env_or_state() {
  local env_name="$1" state_key="$2" default_value="${3:-}"
  local env_val="${!env_name:-}"
  if [ -n "$env_val" ]; then
    printf '%s' "$env_val"
    return 0
  fi
  local state_val
  state_val="$(state_get "$state_key")"
  if [ -n "$state_val" ]; then
    printf '%s' "$state_val"
    return 0
  fi
  printf '%s' "$default_value"
}

# Resolves the local rootless Docker context, verifying it is actually
# rootless rather than trusting its name. Prints the context name.
resolve_docker_context() {
  local ctx
  ctx="$(env_or_state DOCKER_CONTEXT_NAME dockerContext "")"

  if [ -z "$ctx" ]; then
    local candidate
    for candidate in $(docker context ls --format '{{.Name}}' 2>/dev/null); do
      if docker --context "$candidate" info --format '{{json .SecurityOptions}}' 2>/dev/null \
          | grep -q '"name=rootless"'; then
        ctx="$candidate"
        break
      fi
    done
  fi

  [ -n "$ctx" ] || die "No rootless Docker context found. Set DOCKER_CONTEXT_NAME, or set one up with dockerd-rootless-setuptool.sh install."

  docker --context "$ctx" info --format '{{json .SecurityOptions}}' 2>/dev/null \
      | grep -q '"name=rootless"' \
      || die "Docker context '$ctx' is not rootless. This recipe requires the host's rootless Docker context."

  printf '%s' "$ctx"
}

ensure_identity_key() {
  if [ ! -f "$IDENTITY_FILE" ]; then
    mkdir -p "$KEYS_DIR"
    chmod 700 "$KEYS_DIR"
    ssh-keygen -t ed25519 -N "" -C "orca-local-docker-sandbox" -f "$IDENTITY_FILE" >&2
  fi
  chmod 600 "$IDENTITY_FILE"
}

sanitize_name_component() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-'
}

# Updates ~/.ssh/known_hosts for [host]:port, replacing any stale entry
# for that exact endpoint. Never disables host-key checking.
record_known_host() {
  local host="$1" port="$2" key_line="$3"
  local ssh_dir="$HOME/.ssh"
  local known_hosts="$ssh_dir/known_hosts"
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  touch "$known_hosts"
  chmod 600 "$known_hosts"
  ssh-keygen -R "[$host]:$port" -f "$known_hosts" >/dev/null 2>&1 || true
  printf '%s\n' "$key_line" >> "$known_hosts"
}

# Best-effort removal of a known_hosts entry, only if it currently
# matches the given key data -- so destroy never evicts a different
# workspace's still-valid entry for a reused port.
forget_known_host_if_matches() {
  local host="$1" port="$2" expected_key_data="$3"
  local known_hosts="$HOME/.ssh/known_hosts"
  [ -f "$known_hosts" ] || return 0
  if ssh-keygen -F "[$host]:$port" -f "$known_hosts" 2>/dev/null | grep -qF "$expected_key_data"; then
    ssh-keygen -R "[$host]:$port" -f "$known_hosts" >/dev/null 2>&1 || true
  fi
}
