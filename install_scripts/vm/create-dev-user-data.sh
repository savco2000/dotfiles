#!/bin/bash
# Make executable: create-dev-user-data.sh
# Usage: ./create-dev-user-data.sh

# Enable strict error handling: fail fast on errors or unset variables
set -euo pipefail

# Dynamically set the output path to the exact directory where this script resides
OUTPUT_FILE="$(dirname "$0")/dev-user-data.yaml"

# 1. Dynamically pull identity and SSH keys from the password manager
# Fetch git secrets once to halve the GPG decryption overhead
GIT_SECRETS=$(pass show github/personal)
GIT_NAME=$(echo "$GIT_SECRETS" | grep "^username:" | cut -d' ' -f2-)
GIT_EMAIL=$(echo "$GIT_SECRETS" | grep "^email:" | cut -d' ' -f2)

SSH_PUB_KEY=$(pass show ssh/public-key | tr -d '\n')
SSH_PRIV_KEY=$(pass show ssh/private-key)
USERNAME=$(pass show host | grep "^username:" | cut -d' ' -f2-)

yaml_escape() {
  local value=${1-}
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "$value"
}

indent_lines() {
  local prefix=$1
  local content=$2
  printf '%s\n' "$content" | sed "s/^/${prefix}/"
}

REPO_LIST='private-cloud-runbook dotfiles tabiri-website tabiri-website-static stacktriage brand-collateral the-black-box'
REPO_LOOP_SNIPPET=$(cat <<EOF
for repo in $REPO_LIST; do
  target=/home/${USERNAME}/\$repo
  if [ -d "\$target/.git" ]; then
    :
  else
    echo "Cloning \$repo"
    sudo -u ${USERNAME} env HOME=/home/${USERNAME} GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/home/${USERNAME}/.ssh/known_hosts' git clone "git@github.com:savco2000/\$repo.git" "\$target"
  fi
  # Normalise any pre-existing HTTPS origin so pushes never fall back to a credential helper
  if [ -d "\$target/.git" ]; then
    sudo -u ${USERNAME} env HOME=/home/${USERNAME} git -C "\$target" remote set-url origin "git@github.com:savco2000/\$repo.git"
  fi
done
EOF
)

# systemd user unit keeping an ssh-agent alive for the lifetime of the VM, so that
# VS Code Remote-SSH and Dev Containers always inherit a populated SSH_AUTH_SOCK.
SSH_AGENT_UNIT=$(cat <<'EOF'
[Unit]
Description=SSH authentication agent for %u
Documentation=man:ssh-agent(1)

[Service]
Type=simple
Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket
ExecStartPre=-/bin/rm -f %t/ssh-agent.socket
ExecStart=/usr/bin/ssh-agent -D -a %t/ssh-agent.socket
ExecStartPost=-/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do [ -S %t/ssh-agent.socket ] && break; sleep 0.5; done; SSH_AUTH_SOCK=%t/ssh-agent.socket exec /usr/bin/ssh-add %h/.ssh/id_ed25519'
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
)

# Point shells at the managed agent, but never clobber a working forwarded agent.
SSH_AGENT_PROFILE=$(cat <<'EOF'
# Managed by create-dev-user-data.sh - keep an ssh-agent reachable in every shell.
_managed_agent_sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ssh-agent.socket"
if [ -z "${SSH_AUTH_SOCK:-}" ] || ! ssh-add -l >/dev/null 2>&1; then
    if [ -S "$_managed_agent_sock" ]; then
        SSH_AUTH_SOCK="$_managed_agent_sock"
        export SSH_AUTH_SOCK
    fi
fi
unset _managed_agent_sock
EOF
)

build_shell_block() {
  cat <<EOF
    install -d -o ${USERNAME} -g ${USERNAME} -m 0755 /home/${USERNAME} /home/${USERNAME}/.ssh
    if [ -d /etc/skel ]; then cp -a /etc/skel/. /home/${USERNAME}/; fi
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}
    chmod 700 /home/${USERNAME}/.ssh
    cat > /home/${USERNAME}/.ssh/id_ed25519 <<'KEY_EOF'
$(indent_lines '    ' "$SSH_PRIV_KEY")
    KEY_EOF
    chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh/id_ed25519
    chmod 600 /home/${USERNAME}/.ssh/id_ed25519
    cat > /home/${USERNAME}/.ssh/id_ed25519.pub <<'KEY_EOF'
$(indent_lines '    ' "$SSH_PUB_KEY")
    KEY_EOF
    chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh/id_ed25519.pub
    chmod 644 /home/${USERNAME}/.ssh/id_ed25519.pub
    printf '%s\\n' '${SSH_PUB_KEY}' > /home/${USERNAME}/.ssh/authorized_keys
    chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh/authorized_keys
    chmod 600 /home/${USERNAME}/.ssh/authorized_keys
    touch /home/${USERNAME}/.ssh/known_hosts
    chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh/known_hosts
    chmod 600 /home/${USERNAME}/.ssh/known_hosts
    ssh-keyscan github.com >> /home/${USERNAME}/.ssh/known_hosts
    cat > /home/${USERNAME}/.ssh/config <<'SSHCFG'
    Host github.com
      HostName github.com
      User git
      IdentityFile /home/${USERNAME}/.ssh/id_ed25519
      IdentitiesOnly yes
      StrictHostKeyChecking yes
      AddKeysToAgent yes
    SSHCFG
    chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh/config
    chmod 600 /home/${USERNAME}/.ssh/config
    install -d -o ${USERNAME} -g ${USERNAME} -m 0755 /home/${USERNAME}/.config/systemd/user/default.target.wants
    cat > /home/${USERNAME}/.config/systemd/user/ssh-agent.service <<'UNIT_EOF'
$(indent_lines '    ' "$SSH_AGENT_UNIT")
    UNIT_EOF
    ln -sf ../ssh-agent.service /home/${USERNAME}/.config/systemd/user/default.target.wants/ssh-agent.service
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config
    cat > /etc/profile.d/10-ssh-agent.sh <<'PROFILE_EOF'
$(indent_lines '    ' "$SSH_AGENT_PROFILE")
    PROFILE_EOF
    chmod 644 /etc/profile.d/10-ssh-agent.sh
    grep -q '10-ssh-agent.sh' /home/${USERNAME}/.bashrc 2>/dev/null || printf '%s\n' '. /etc/profile.d/10-ssh-agent.sh' >> /home/${USERNAME}/.bashrc
    chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.bashrc
    loginctl enable-linger ${USERNAME} || true
    install -d -o ${USERNAME} -g ${USERNAME} -m 0755 /home/${USERNAME}/repos
$(indent_lines '    ' "$REPO_LOOP_SNIPPET")
EOF
}

build_users_block() {
  cat <<EOF
users:
  - name: ${USERNAME}
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL # Explicitly grant ${USERNAME} passwordless sudo
    lock_passwd: true # 🔒 Locks password authentication entirely
    ssh_authorized_keys:
      - ${SSH_PUB_KEY}
    home: /home/${USERNAME}
EOF
}

build_packages_block() {
  cat <<EOF
packages:
  - nodejs
  - npm
  - build-essential
  - python3
  - python3-pip
  - python3-venv
  - docker.io
  - docker-buildx
  - git
  - git-lfs
  - gh
  - openssh-client
  - postgresql-client
  - ca-certificates
  - curl
  - wget
  - jq
  - ripgrep
  - fd-find
  - shellcheck
  - unzip
  - zip
  - rsync
  - sqlite3
  - tree
  - nano
  - htop
  - ncdu
  - byobu
  - xsel
EOF
}

build_write_files_block() {
  cat <<EOF
write_files:
  - path: /home/${USERNAME}/.ssh/id_ed25519
    owner: ${USERNAME}:${USERNAME}
    permissions: '0600'
    content: |
$(indent_lines '      ' "$SSH_PRIV_KEY")
  - path: /home/${USERNAME}/.ssh/id_ed25519.pub
    owner: ${USERNAME}:${USERNAME}
    permissions: '0644'
    content: |
$(indent_lines '      ' "$SSH_PUB_KEY")
EOF
}

build_runcmd_block() {
  cat <<EOF
runcmd:
  - |
    if [ ! -f /swapfile ]; then
        fallocate -l 4G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    elif ! swapon --show=NAME --noheadings | grep -qx '/swapfile'; then
        swapon /swapfile
    fi

  - usermod -aG docker ${USERNAME}

  - [ npm, install, -g, --ignore-scripts, '@earendil-works/pi-coding-agent' ]
  - [ ln, -sf, /usr/bin/fdfind, /usr/local/bin/fd ]
  - [ sudo, -u, ${USERNAME}, env, HOME=/home/${USERNAME}, pi, install, 'npm:planning-with-files' ]

  - |
$(build_shell_block)

  - [ sudo, -u, ${USERNAME}, env, HOME=/home/${USERNAME}, git, config, --global, user.name, "$(yaml_escape "$GIT_NAME")" ]
  - [ sudo, -u, ${USERNAME}, env, HOME=/home/${USERNAME}, git, config, --global, user.email, "$(yaml_escape "$GIT_EMAIL")" ]
  - [ sudo, -u, ${USERNAME}, env, HOME=/home/${USERNAME}, git, config, --global, init.defaultBranch, main ]

  # Force every GitHub interaction over SSH. VS Code Dev Containers copies this
  # global config into the container, so HTTPS remotes can never fall back to an
  # interactive credential helper that has no terminal to prompt on.
  - [ sudo, -u, ${USERNAME}, env, HOME=/home/${USERNAME}, git, config, --global, 'url.git@github.com:.insteadOf', 'https://github.com/' ]
  - [ sudo, -u, ${USERNAME}, env, HOME=/home/${USERNAME}, git, config, --global, --add, 'url.git@github.com:.insteadOf', 'git://github.com/' ]

  - [ sudo, -u, ${USERNAME}, env, HOME=/home/${USERNAME}, byobu-enable ]

  - [ sudo, -u, ${USERNAME}, env, HOME=/home/${USERNAME}, bash, -c, 'set -x; echo "SSH key files:"; ls -l /home/${USERNAME}/.ssh; echo "SSH public key:"; cat /home/${USERNAME}/.ssh/id_ed25519.pub; echo "SSH fingerprint:"; ssh-keygen -lf /home/${USERNAME}/.ssh/id_ed25519.pub; cd /home/${USERNAME} && for repo in private-cloud-runbook dotfiles tabiri-website stacktriage brand-collateral the-black-box; do target=/home/${USERNAME}/\$repo; if [ -d "\$target/.git" ]; then :; else echo "Cloning \$repo"; GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/home/${USERNAME}/.ssh/known_hosts" git clone "git@github.com:savco2000/\$repo.git" "\$target"; fi; done' ]
EOF
}

write_cloud_init() {
  cat > "$OUTPUT_FILE" <<EOF
#cloud-config
$(build_users_block)

$(build_packages_block)

$(build_write_files_block)

$(build_runcmd_block)
EOF
}

write_cloud_init

echo "✨ VM user-data file successfully generated at $OUTPUT_FILE"