#!/bin/bash
# Enable strict error handling: fail fast on errors or unset variables
set -euo pipefail

chmod 700 $HOME/.ssh

# Extract keys directly into the standard OpenSSH paths
mv $HOME/Lifeboat/id_ed25519* $HOME/.ssh/

# Lock down permissions to prevent "Bad owner or permissions" errors
chmod 600 $HOME/.ssh/id_ed25519
chmod 644 $HOME/.ssh/id_ed25519.pub

# Explicitly bind your terminal window to the GPG subsystem
export GPG_TTY=$(tty)

# Execute the import command while forcing loopback mode
gpg --pinentry-mode loopback --import $HOME/Lifeboat/private_key.asc

# Restore your key trust mappings
gpg --import-ownertrust $HOME/Lifeboat/ownertrust.txt

# Scan and save the GitHub SSH key
ssh-keyscan github.com >> ~/.ssh/known_hosts

# Clone the Password Store
git clone git@github.com:savco2000/the-black-box.git $HOME/.password-store

#CLone dotfiles repository
git clone git@github.com:savco2000/dotfiles.git $HOME/dotfiles

rm -r $HOME/Lifeboat