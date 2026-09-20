#!/usr/bin/env bash
set -euo pipefail

# Fresh, container-unique host keys on first start. Never reuse or bake
# these into an image layer -- see AGENTS.md.
if ! compgen -G "/etc/ssh/ssh_host_*_key" > /dev/null; then
  ssh-keygen -A >&2
fi

mkdir -p /home/agent/.ssh
if [ -n "${ORCA_SSH_PUBLIC_KEY:-}" ]; then
  printf '%s\n' "$ORCA_SSH_PUBLIC_KEY" > /home/agent/.ssh/authorized_keys
else
  echo "orca-docker-ssh-entrypoint: ORCA_SSH_PUBLIC_KEY not set; no key authorized, SSH login will fail." >&2
  : > /home/agent/.ssh/authorized_keys
fi
chmod 600 /home/agent/.ssh/authorized_keys
chown -R agent:agent /home/agent/.ssh

# Bind-mounted paths keep their host-side numeric owner, which under
# rootless Docker's uid mapping isn't the same number agent (container
# uid 1000) sees itself as (see AGENTS.md's "Linked worktrees" note) --
# git's dubious-ownership check then refuses to touch them. This
# container never mounts anything it wasn't deliberately given by
# docker-create.sh, so trusting every mounted path for the agent user is
# scoped to this one ephemeral, single-tenant sandbox, not a blanket
# host-wide exception.
printf '[safe]\n\tdirectory = *\n' > /home/agent/.gitconfig
chown agent:agent /home/agent/.gitconfig

exec /usr/sbin/sshd -D -e
