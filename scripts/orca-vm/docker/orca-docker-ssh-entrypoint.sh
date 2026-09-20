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

exec /usr/sbin/sshd -D -e
