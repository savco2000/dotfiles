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

REPO_LIST='private-cloud-runbook dotfiles tabiri-website stacktriage brand-collateral the-black-box'
REPO_LOOP_SNIPPET=$(cat <<EOF
for repo in $REPO_LIST; do
  target=/home/${USERNAME}/\$repo
  if [ -d "\$target/.git" ]; then
    :
  else
    echo "Cloning \$repo"
    sudo -u ${USERNAME} env HOME=/home/${USERNAME} GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/home/${USERNAME}/.ssh/known_hosts' git clone "git@github.com:savco2000/\$repo.git" "\$target"
  fi
done
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
    SSHCFG
    chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh/config
    chmod 600 /home/${USERNAME}/.ssh/config
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
    shell: /bin/bash
EOF
}

build_packages_block() {
  cat <<EOF
packages:
  - npm
  - docker.io
  - docker-buildx
  - git
  - postgresql-client
  - curl
  - jq
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
  - usermod -aG docker ${USERNAME}

  - |
$(build_shell_block)

  - [ sudo, -u, ${USERNAME}, env, HOME=/home/${USERNAME}, git, config, --global, user.name, "$(yaml_escape "$GIT_NAME")" ]
  - [ sudo, -u, ${USERNAME}, env, HOME=/home/${USERNAME}, git, config, --global, user.email, "$(yaml_escape "$GIT_EMAIL")" ]
  - [ sudo, -u, ${USERNAME}, env, HOME=/home/${USERNAME}, git, config, --global, init.defaultBranch, main ]

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