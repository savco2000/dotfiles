#!/bin/bash
# Enable strict error handling: fail fast on errors or unset variables
set -euo pipefail

# Define a single source of truth for the output paths
OUTPUT_FILE="$(dirname "$0")/user-data"
META_DATA_FILE="$(dirname "$OUTPUT_FILE")/meta-data"

mkdir -p "$(dirname "$OUTPUT_FILE")"
touch "$META_DATA_FILE" # Ensure the empty meta-data file exists

# --- 1. Optional Password Rotation ---
echo "------------------------------------------------"
read -p "🔄 Do you want to rotate the host password before generating? (y/N): " ROTATE_PWD
if [[ "$ROTATE_PWD" =~ ^[Yy]$ ]]; then
    read -s -p "   Enter new plaintext password: " RAW_PWD
    echo ""
    read -s -p "   Confirm new plaintext password: " RAW_PWD_CONFIRM
    echo ""
    
    if [ "$RAW_PWD" != "$RAW_PWD_CONFIRM" ]; then
        echo "❌ Passwords do not match! Exiting script."
        exit 1
    fi
    
    echo "⚙️  Hashing password and updating 'host' entry in pass..."
    NEW_HASH=$(echo "$RAW_PWD" | mkpasswd -m sha-512 -s)
    
    # Pull the existing record, replace line 1 (plaintext), and replace the hashed-password line
    EXISTING_SECRETS=$(pass show host)
    UPDATED_SECRETS=$(echo "$EXISTING_SECRETS" | sed "1s|.*|$RAW_PWD|" | sed "s|^hashed-password:.*|hashed-password: $NEW_HASH|")
    
    # Pipe it back into pass (-f forces overwrite without prompting)
    echo "$UPDATED_SECRETS" | pass insert -f -m host > /dev/null
    
    echo "✅ Password successfully rotated and saved to your vault!"
fi

# --- 2. Optional SSH Key Rotation ---
echo "------------------------------------------------"
read -p "🔑 Do you want to rotate the SSH key pair? (y/N): " ROTATE_SSH
if [[ "$ROTATE_SSH" =~ ^[Yy]$ ]]; then
    read -s -p "   Enter passphrase for new SSH key (leave blank for none): " SSH_PASS
    echo ""
    
    echo "⚙️  Generating new ed25519 SSH key pair..."
    # Create a secure temporary directory that only your user can access
    TEMP_SSH_DIR=$(mktemp -d)
    
    # Generate the key pair silently
    ssh-keygen -t ed25519 -f "$TEMP_SSH_DIR/id_ed25519" -N "$SSH_PASS" -C "devuser@ubuntu-host" -q
    
    # Read the newly generated keys
    NEW_PUB_KEY=$(cat "$TEMP_SSH_DIR/id_ed25519.pub")
    NEW_PRIV_KEY=$(cat "$TEMP_SSH_DIR/id_ed25519")
    
    echo "⚙️  Updating SSH keys in pass..."
    # Inject the keys into the password manager using the multiline (-m) flag
    echo "$NEW_PUB_KEY" | pass insert -f -m ssh/public-key > /dev/null
    echo "$NEW_PRIV_KEY" | pass insert -f -m ssh/private-key > /dev/null
    
    # Securely remove the temporary directory and its contents
    rm -rf "$TEMP_SSH_DIR"
    echo "✅ SSH keys successfully rotated and saved to your vault!"
    
    echo "⚠️  NOTE: Because you rotated your key, you MUST upload your new public key to GitHub!"
fi
echo "------------------------------------------------"

# --- 3. Stage Local SSH Environment ---
echo "⚙️  Staging local SSH keys for immediate use..."
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# Extract keys directly into the standard OpenSSH paths
pass show ssh/private-key > "$HOME/.ssh/id_ed25519"
pass show ssh/public-key > "$HOME/.ssh/id_ed25519.pub"

# Lock down permissions to prevent "Bad owner or permissions" errors
chmod 600 "$HOME/.ssh/id_ed25519"
chmod 644 "$HOME/.ssh/id_ed25519.pub"
echo "✅ SSH keys are staged and ready in ~/.ssh/"
echo "------------------------------------------------"

# --- 4. Dynamically pull identity and SSH keys ---
# Fetch the host secrets exactly once to save GPG decryption overhead
HOST_SECRETS=$(pass show host)
GIT_SECRETS=$(pass show github/personal)

SSH_PUB_KEY=$(pass show ssh/public-key | tr -d '\n')
HASHED_PASSWORD=$(echo "$HOST_SECRETS" | grep "^hashed-password:" | cut -d' ' -f2)
REAL_NAME=$(echo "$HOST_SECRETS" | grep "^realname:" | cut -d' ' -f2-)
HOST_NAME=$(echo "$HOST_SECRETS" | grep "^hostname:" | cut -d' ' -f2-)
USERNAME=$(echo "$HOST_SECRETS" | grep "^username:" | cut -d' ' -f2-)
GIT_NAME=$(echo "$GIT_SECRETS" | grep "^username:" | cut -d' ' -f2-)
GIT_EMAIL=$(echo "$GIT_SECRETS" | grep "^email:" | cut -d' ' -f2)

# --- 5. Generate the configuration file with safe placeholders ---
cat << 'OUTER_EOF' > "$OUTPUT_FILE"
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard: {layout: us}
  timezone: America/New_York
  identity:
    hostname: __HOST_NAME_PLACEHOLDER__
    realname: __REAL_NAME_PLACEHOLDER__
    username: __USERNAME_PLACEHOLDER__
    password: __HASHED_PASSWORD_PLACEHOLDER__
  ssh:
    install-server: true
    authorized-keys:
      - __SSH_PUB_KEY_PLACEHOLDER__ 
  storage:
    layout:
      name: direct
      match:
        path: /dev/nvme0n1
  packages:
    - qemu-system-x86
    - qemu-utils
    - cloud-image-utils
    - libvirt-daemon-system
    - libvirt-clients
    - virt-manager
    - gimp
    - tlp
    - gnupg2
    - pass
    - stow
    - pinentry-gnome3
    - xclip
    - curl
    - jq
    - whois
    - usb-creator-gtk
    - paperkey
    - wmctrl
  snaps:
    - name: code
      classic: true
    - name: slack
      classic: true
    - name: zoom-client
  late-commands:
    - curtin in-target -- wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -O /tmp/chrome.deb
    - curtin in-target -- apt-get install -y /tmp/chrome.deb
  user-data:
    runcmd:
      # 1. Remove Firefox now that the system is live
      - snap remove --purge firefox

      # 2. SET SYSTEM-WIDE DESKTOP DEFAULTS VIA DCONF
      - |
        mkdir -p /etc/dconf/db/local.d/
        cat <<EOF > /etc/dconf/db/local.d/00-sovereign-desktop
        [org/gnome/shell]
        favorite-apps=['google-chrome.desktop', 'code_code.desktop', 'org.gnome.Ptyxis.desktop', 'slack_slack.desktop', 'zoom-client_zoom-client.desktop', 'virt-manager.desktop', 'org.gnome.Nautilus.desktop']

        [org/gnome/shell/extensions/dash-to-dock]
        show-trash=true
        trash-at-the-end=true

        [org/gnome/desktop/interface]
        color-scheme='prefer-dark'
        EOF
        
        mkdir -p /etc/dconf/profile/
        cat <<EOF > /etc/dconf/profile/user
        user-db:user
        system-db:local
        EOF
        
        dconf update

      # 3. DISABLE GNOME INITIAL SETUP (The "Welcome" Screen & Popup Fix)
      - |
        sed -i '/\[daemon\]/a InitialSetupEnable=false' /etc/gdm3/custom.conf
        for dir in /etc/skel /home/__USERNAME_PLACEHOLDER__; do
          mkdir -p "$dir/.config"
          echo "yes" > "$dir/.config/gnome-initial-setup-done"
        done
        chown -R __USERNAME_PLACEHOLDER__:__USERNAME_PLACEHOLDER__ /home/__USERNAME_PLACEHOLDER__/.config 2>/dev/null || true
        apt-get purge -y gnome-initial-setup

      # 4. Modular SSH Configuration Setup for __USERNAME_PLACEHOLDER__
      - |
        mkdir -p /home/__USERNAME_PLACEHOLDER__/.ssh/conf.d
        touch /home/__USERNAME_PLACEHOLDER__/.ssh/config
        if ! grep -q "^Include conf.d/\*" /home/__USERNAME_PLACEHOLDER__/.ssh/config; then
          printf "Include conf.d/*\n%s" "$(cat /home/__USERNAME_PLACEHOLDER__/.ssh/config)" > /home/__USERNAME_PLACEHOLDER__/.ssh/config
        fi
        chown -R __USERNAME_PLACEHOLDER__:__USERNAME_PLACEHOLDER__ /home/__USERNAME_PLACEHOLDER__/.ssh
        chmod 700 /home/__USERNAME_PLACEHOLDER__/.ssh
        chmod 600 /home/__USERNAME_PLACEHOLDER__/.ssh/config

      # 5. Install VS Code Extensions
      - sudo -u __USERNAME_PLACEHOLDER__ code --install-extension ms-vscode-remote.remote-ssh
      - sudo -u __USERNAME_PLACEHOLDER__ code --install-extension ms-vscode-remote.remote-containers

      # 6. Configure Git for __USERNAME_PLACEHOLDER__ context
      - [ sudo, -u, __USERNAME_PLACEHOLDER__, git, config, --global, user.name, "__GIT_NAME_PLACEHOLDER__" ]
      - [ sudo, -u, __USERNAME_PLACEHOLDER__, git, config, --global, user.email, "__GIT_EMAIL_PLACEHOLDER__" ]
      - [ sudo, -u, __USERNAME_PLACEHOLDER__, git, config, --global, init.defaultBranch, main ]

      # 7. PERFORMANCE OPTIMIZATIONS (Systemd Services)
      - |
        systemctl disable NetworkManager-wait-online.service
        systemctl disable fwupd-refresh.service
        systemctl disable kdump-tools.service
        systemctl disable apport.service
        systemctl disable ModemManager.service
        systemctl disable fstrim.service
        systemctl enable fstrim.timer

      # 8. SNAP REVISION MANAGEMENT
      - snap set system refresh.retain=2

      # 9. KERNEL SERIAL PROBE DISABLING
      - |
        if [ -f /etc/default/grub ]; then
          sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash 8250.nr_uarts=0"/' /etc/default/grub
          update-grub
        fi
OUTER_EOF

# --- 6. Safely inject all parameters in a single disk I/O operation ---
sed -i \
  -e "s|__SSH_PUB_KEY_PLACEHOLDER__|$SSH_PUB_KEY|g" \
  -e "s|__HASHED_PASSWORD_PLACEHOLDER__|$HASHED_PASSWORD|g" \
  -e "s|__REAL_NAME_PLACEHOLDER__|$REAL_NAME|g" \
  -e "s|__HOST_NAME_PLACEHOLDER__|$HOST_NAME|g" \
  -e "s|__USERNAME_PLACEHOLDER__|$USERNAME|g" \
  -e "s|__GIT_NAME_PLACEHOLDER__|$GIT_NAME|g" \
  -e "s|__GIT_EMAIL_PLACEHOLDER__|$GIT_EMAIL|g" \
  "$OUTPUT_FILE"

echo "✨ user-data and meta-data files successfully generated at $(dirname "$OUTPUT_FILE")/"

# --- 7. Export GPG Private Key & Ownertrust ---
echo "------------------------------------------------"
read -p "🔐 Do you want to export your GPG private key and ownertrust for backup? (y/N): " EXPORT_GPG
if [[ "$EXPORT_GPG" =~ ^[Yy]$ ]]; then
    echo "⚙️  Exporting GPG keys for $GIT_EMAIL..."
    PRIVATE_KEY_FILE="$(dirname "$OUTPUT_FILE")/private_key.asc"
    OWNERTRUST_FILE="$(dirname "$OUTPUT_FILE")/ownertrust.txt"
    
    # We use the $GIT_EMAIL dynamically pulled from pass to identify the correct GPG key
    gpg --armor --export-secret-keys "$GIT_EMAIL" > "$PRIVATE_KEY_FILE"
    gpg --export-ownertrust > "$OWNERTRUST_FILE"
    
    # Secure the exported private key permissions so SSH/Linux doesn't complain later
    chmod 600 "$PRIVATE_KEY_FILE"
    
    echo "✅ GPG private key saved to: $PRIVATE_KEY_FILE"
    echo "✅ GPG ownertrust saved to: $OWNERTRUST_FILE"
fi
echo "------------------------------------------------"