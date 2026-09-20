#!/usr/bin/env bash
# Shared helpers for the local-docker-sandbox recipe scripts.
# Sourced by every script in this directory; never executed directly.

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Fixed by design (see AGENTS.md). AGENT_UID/AGENT_GID must match the
# useradd call in docker/Dockerfile.base -- both sides assume the same
# numeric id when computing the rootless-Docker ACL grant below.
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

# Deliberately NOT under $_lib_dir (i.e. not inside the repo worktree):
# docker-create.sh bind-mounts and recursively ACL-grants the whole
# worktree to the container's agent user, including a *default* ACL
# entry that any new file created under it inherits. A key generated
# inside that tree picks up that grant and OpenSSH then refuses to load
# it ("bad permissions") -- this bit us for real the first time this
# recipe was live-tested. Hashing $_lib_dir keeps the location stable
# per worktree without needing one inside it.
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

# Maps a numeric id declared inside a container to the id it is
# actually stored as on the host filesystem under rootless Docker's
# mapping (container id 0 == the invoking host user 1:1; any other id
# lands in that user's /etc/subuid or /etc/subgid range). See AGENTS.md
# for why this is needed to let the non-root agent user write into a
# bind-mounted, host-owned directory.
# map_file: /etc/subuid or /etc/subgid
mapped_host_id() {
  local container_id="$1" map_file="$2"
  local base range
  read -r base range < <(awk -F: -v u="$(id -un)" '$1==u{print $2, $3}' "$map_file")
  [ -n "$base" ] || die "No $(id -un) entry in $map_file. Rootless Docker needs a subuid/subgid range for this user."
  [ "$container_id" -ge 1 ] || die "mapped_host_id needs a non-zero container id (0 maps 1:1 to the real host user, not through $map_file)."
  [ "$container_id" -le "$range" ] || die "container id $container_id is outside the mapped range in $map_file (base=$base range=$range)."
  printf '%s' "$((base + container_id - 1))"
}

# Grants (mode=grant, default) or revokes (mode=revoke) the container
# agent user's rwx access to a bind-mount source directory via POSIX
# ACL, without changing its ownership. Idempotent; safe to call
# repeatedly.
grant_agent_acl() {
  local dir="$1" mode="${2:-grant}"
  local mapped_uid
  mapped_uid="$(mapped_host_id "$AGENT_UID" /etc/subuid)"
  command -v setfacl >/dev/null 2>&1 || die "setfacl not found on host (Debian/Ubuntu package 'acl'); required to grant the container's non-root agent user access to $dir without changing its ownership."
  if [ "$mode" = "revoke" ]; then
    setfacl -R -x "u:$mapped_uid" "$dir" 2>/dev/null || true
    setfacl -R -x "d:u:$mapped_uid" "$dir" 2>/dev/null || true
  else
    setfacl -R -m "u:$mapped_uid:rwx" -m "d:u:$mapped_uid:rwx" "$dir"
  fi
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
