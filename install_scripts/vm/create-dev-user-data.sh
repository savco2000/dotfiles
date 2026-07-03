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
USERNAME=$(pass show host | grep "^username:" | cut -d' ' -f2-)

# 2. Generate the configuration file with variables injected directly
# (Unquoted EOF allows Bash to inject variables directly without needing sed)
cat << EOF > "$OUTPUT_FILE"
#cloud-config
users:
  - name: $USERNAME
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL # Explicitly grant $USERNAME passwordless sudo
    lock_passwd: true # 🔒 Locks password authentication entirely
    ssh_authorized_keys:
      - $SSH_PUB_KEY

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

runcmd:
  # 1. Adding the user to the docker group safely after package installation
  - usermod -aG docker $USERNAME
  
  # 2. Configuring Git identity for $USERNAME
  - [ sudo, -u, $USERNAME, git, config, --global, user.name, "$GIT_NAME" ]
  - [ sudo, -u, $USERNAME, git, config, --global, user.email, "$GIT_EMAIL" ]
  - [ sudo, -u, $USERNAME, git, config, --global, init.defaultBranch, main ]

  # 3. Enable Byobu auto-launch on login for $USERNAME
  - [ sudo, -u, $USERNAME, byobu-enable ]

  # 4. Pre-seed GitHub SSH keys to prevent interactive authenticity prompts for $USERNAME
  - [ sudo, -u, $USERNAME, bash, -c, 'ssh-keyscan github.com >> ~/.ssh/known_hosts' ]

  # 5. Automatically clone core repositories into the user's home directory
  - [ sudo, -u, $USERNAME, bash, -c, 'cd /home/$USERNAME && git clone git@github.com:savco2000/private-cloud-runbook.git' ]
  - [ sudo, -u, $USERNAME, bash, -c, 'cd /home/$USERNAME && git clone git@github.com:savco2000/tabiri-website.git' ]
EOF

echo "✨ VM user-data file successfully generated at $OUTPUT_FILE"