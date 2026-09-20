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

export HOME=/home/agent

# This is a single-tenant, ephemeral, purpose-built sandbox -- every path
# under agent's control here was deliberately put there by docker-create.sh,
# never a stranger's repo agent happened to cd into. Scoped to that, not a
# blanket host-wide exception.
git config --global --add safe.directory '*'

# provisioned-root: populate /workspace from the project's own repo, but
# only on first boot. Never on a later start (resume) -- that would
# blow away whatever the agent has done in the meantime.
if [ ! -d /workspace/.git ]; then
  echo "orca-docker-ssh-entrypoint: provisioning /workspace from \$ORCA_REPO_URL..." >&2
  : "${ORCA_REPO_URL:?ORCA_REPO_URL not set}"
  : "${ORCA_REPO_REF:?ORCA_REPO_REF not set}"
  : "${ORCA_REPO_REF_HEAD:?ORCA_REPO_REF_HEAD not set}"
  : "${ORCA_REPO_BRANCH:?ORCA_REPO_BRANCH not set}"

  if [ -n "${GH_TOKEN:-}" ]; then
    printf 'https://x-access-token:%s@github.com\n' "$GH_TOKEN" > /home/agent/.git-credentials
    chmod 600 /home/agent/.git-credentials
    git config --global credential.helper store
  else
    echo "orca-docker-ssh-entrypoint: GH_TOKEN not set; only a public repo's read access will work." >&2
  fi
  git config --global user.email "agent@orca-secure-sandbox.local"
  git config --global user.name "Orca Sandbox Agent"

  mkdir -p /workspace
  cd /workspace
  git init -q
  git fetch "$ORCA_REPO_URL" "$ORCA_REPO_REF"
  git cat-file -e "${ORCA_REPO_REF_HEAD}^{commit}"
  git checkout -B "$ORCA_REPO_BRANCH" "$ORCA_REPO_REF_HEAD"
  git remote add origin "$ORCA_REPO_URL" 2>/dev/null || git remote set-url origin "$ORCA_REPO_URL"

  chown -R agent:agent /workspace
  [ -f /home/agent/.gitconfig ] && chown agent:agent /home/agent/.gitconfig
  [ -f /home/agent/.git-credentials ] && chown agent:agent /home/agent/.git-credentials
fi

exec /usr/sbin/sshd -D -e
