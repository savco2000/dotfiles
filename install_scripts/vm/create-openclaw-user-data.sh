#!/bin/bash
# Enable strict error handling: fail fast on errors or unset variables
set -euo pipefail

# Dynamically set the output path to the exact directory where this script resides
OUTPUT_FILE="$(dirname "$0")/openclaw-user-data.yaml"

# 1. Dynamically pull identity and SSH keys from the password manager
# Fetch git secrets once to halve the GPG decryption overhead
GIT_SECRETS=$(pass show github/personal)
GIT_NAME=$(echo "$GIT_SECRETS" | grep "^username:" | cut -d' ' -f2-)
GIT_EMAIL=$(echo "$GIT_SECRETS" | grep "^email:" | cut -d' ' -f2)

SSH_PUB_KEY=$(pass show ssh/public-key | tr -d '\n')
USERNAME=$(pass show host | grep "^username:" | cut -d' ' -f2-)

# 2. Generate the configuration file with variables injected
# (Unquoted EOF allows Bash to inject variables directly without needing sed)
cat << EOF > "$OUTPUT_FILE"
#cloud-config
users:
  - name: $USERNAME
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL # Explicitly grant $USERNAME passwordless sudo access:
    lock_passwd: true # 🔒 Locks password authentication entirely
    ssh_authorized_keys:
      - $SSH_PUB_KEY

packages:
  - docker.io
  - docker-buildx
  - nodejs
  - npm
  - git
  - curl
  - jq
  - tcpdump
  - auditd
  - byobu

runcmd:
  # 1. Safely attach $USERNAME to docker now that the package is installed
  - [ usermod, -aG, docker, $USERNAME ]
  
  # 2. System-wide global installation of the OpenClaw CLI
  - [ npm, install, -g, openclaw@latest ]
  
  # 3. Provision the workspace securely using $USERNAME's explicit context
  - [ sudo, -u, $USERNAME, mkdir, -p, /home/$USERNAME/claw-workspace ]

  # 4. Configuring Git identity for $USERNAME
  - [ sudo, -u, $USERNAME, git, config, --global, user.name, "$GIT_NAME" ]
  - [ sudo, -u, $USERNAME, git, config, --global, user.email, "$GIT_EMAIL" ]
  - [ sudo, -u, $USERNAME, git, config, --global, init.defaultBranch, main ]

  # 5. Enable Byobu auto-launch on login for $USERNAME
  - [ sudo, -u, $USERNAME, byobu-enable ]

  # 6. Pre-seed GitHub SSH keys to prevent interactive authenticity prompts for $USERNAME
  - [ sudo, -u, $USERNAME, bash, -c, 'ssh-keyscan github.com >> ~/.ssh/known_hosts' ]
EOF

echo "✨ OpenClaw user-data file successfully generated at $OUTPUT_FILE"