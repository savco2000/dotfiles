#!/bin/bash
# Make executable: chmod +x deploy-vm.sh
# Usage: sudo ./deploy-vm.sh <config.yaml | vm-name> [-m memory_mib] [-c vcpus] [-s disk_gib] [-d] [-f]
# Default: 4096 MiB RAM, 4 vCPUs, 40 GiB Disk (Linked Clone)

# --- 1. Dynamic Variables & Defaults ---
TARGET=$1
if [ -z "$TARGET" ]; then
    echo "❌ Error: No target specified."
    echo "Usage: $0 <user-data.yaml | vm-name> [-m memory] [-c vcpus] [-s size_gb] [-d] [-f]"
    exit 1
fi

# Smart Input Parsing: Determine if target is a file or a VM name
if [[ "$TARGET" =~ \.(yaml|yml)$ ]]; then
    # Input is a file path
    USER_DATA="$TARGET"
    FILENAME=$(basename "$TARGET")
    PREFIX=$(echo "$FILENAME" | sed -E 's/-user-data\.(yaml|yml)$//')
    VM_NAME="${PREFIX}-vm"
else
    # Input is a string (VM name or prefix)
    if [[ "$TARGET" == *-vm ]]; then
        VM_NAME="$TARGET"
        PREFIX="${TARGET%-vm}"
    else
        PREFIX="$TARGET"
        VM_NAME="${PREFIX}-vm"
    fi
    # Guess the local user-data path in case they are creating rather than destroying
    USER_DATA="./${PREFIX}-user-data.yaml"
fi

MEM=4096
CPUS=4
DISK=40

shift

# --- 2. Flag Handling ---
while getopts "dfm:c:s:" opt; do
  case $opt in
    d)
      echo "🔥 Self-Destruct Initiated for $VM_NAME..."
      sudo virsh destroy "$VM_NAME" 2>/dev/null
      sudo virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null
      sudo rm -f "/var/lib/libvirt/images/$VM_NAME-meta-data" "/var/lib/libvirt/images/$VM_NAME-seed.iso"
      echo "✨ Environment cleared."
      exit 0
      ;;
    f)
      echo "♻️ Force flag detected. Removing local base image..."
      sudo rm -f "/var/lib/libvirt/images/resolute-base.img"
      ;;
    m) MEM=$OPTARG ;;
    c) CPUS=$OPTARG ;;
    s) DISK=$OPTARG ;;
    \?) exit 1 ;;
  esac
done

# --- 3. Internal Paths ---
LIBVIRT_DIR="/var/lib/libvirt/images"
BASE_IMG="$LIBVIRT_DIR/resolute-base.img"
VM_DISK="$LIBVIRT_DIR/$VM_NAME.qcow2"
META_DATA="$LIBVIRT_DIR/$VM_NAME-meta-data"
SEED_ISO="$LIBVIRT_DIR/$VM_NAME-seed.iso"
BASE_IMG_URL="https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64v3.img"
SHA_URL="https://cloud-images.ubuntu.com/resolute/current/SHA256SUMS"

# --- 4. Pre-Flight Checks ---
if [ ! -f "$USER_DATA" ]; then
    echo "❌ Error: Configuration file '$USER_DATA' not found."
    exit 1
fi

if [ "$EUID" -ne 0 ]; then 
  echo "Please run as root (sudo) for deployment"
  exit
fi

# Detect the real user who invoked sudo and discover their real home directory
REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# --- 5. Synchronize & Verify Base Image ---
if [ ! -f "$BASE_IMG" ]; then
    echo "📡 Downloading Ubuntu Cloud Image..."
    wget -c --no-verbose -P "$LIBVIRT_DIR" "$BASE_IMG_URL"
    mv "$LIBVIRT_DIR/resolute-server-cloudimg-amd64v3.img" "$BASE_IMG" 2>/dev/null
fi

echo "🛡️ Verifying integrity..."
curl -s "$SHA_URL" | grep "resolute-server-cloudimg-amd64v3.img" > /tmp/sha256
sed -i "s/resolute-server-cloudimg-amd64v3.img/resolute-base.img/" /tmp/sha256
(cd "$LIBVIRT_DIR" && sha256sum --check --status /tmp/sha256) || { echo "❌ Checksum failed!"; exit 1; }

# --- 6. Provision & Seed ---
echo "🧹 Cleaning up existing $VM_NAME resources..."
sudo virsh destroy "$VM_NAME" 2>/dev/null
sudo virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null

echo "🌱 Generating Cloud-Init seed..."
cat <<EOF > "$META_DATA"
instance-id: $VM_NAME-$(date +%s)
local-hostname: $VM_NAME
EOF
cloud-localds "$SEED_ISO" "$USER_DATA" "$META_DATA"

echo "💾 Creating linked clone: $VM_DISK (${DISK}GB)..."
sudo qemu-img create -f qcow2 -b "$BASE_IMG" -F qcow2 "$VM_DISK" "${DISK}G"

# --- 7. Launch ---
echo "🚀 Launching $VM_NAME ($MEM MiB RAM, $CPUS vCPUs)..."
virt-install \
  --name "$VM_NAME" \
  --osinfo ubuntu-lts-latest \
  --cpu host-model \
  --memory "$MEM" \
  --vcpus "$CPUS" \
  --import \
  --disk path="$VM_DISK" \
  --disk path="$SEED_ISO",device=cdrom \
  --network network=default \
  --graphics none \
  --noautoconsole

# --- 8. Post-Flight: Monitor the Black Box ---
echo "⏳ Waiting for VM to claim an IP..."
MAX_RETRIES=30
COUNT=0
while [ -z "${VM_IP:-}" ] && [ $COUNT -lt $MAX_RETRIES ]; do
    VM_IP=$(virsh domifaddr "$VM_NAME" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" || true)
    sleep 2
    ((COUNT++))
done

if [ -z "${VM_IP:-}" ]; then
    echo "⚠️ IP detection timed out. Check manually with 'virsh domifaddr $VM_NAME'."
    exit 1
fi

echo "🚀 $VM_NAME is live at $VM_IP. Waiting for configuration to finish..."

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 devuser@$VM_IP "cloud-init status --wait"

# --- 9. Automated SSH Configuration ---
echo "⚙️  Wiring up SSH configuration for $VM_NAME..."

# Ensure the modular directory exists in the true invoking user's home folder
mkdir -p "$REAL_HOME/.ssh/conf.d"

# Create or overwrite the VM's specific config file path dynamically
cat << EOF > "$REAL_HOME/.ssh/conf.d/$VM_NAME"
Host $VM_NAME
  HostName $VM_IP
  User devuser
  IdentityFile ~/.ssh/id_ed25519
  ForwardAgent yes
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOF

# Ensure permissions and system ownership are handed back to the normal user context
chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.ssh/conf.d"
chmod 700 "$REAL_HOME/.ssh/conf.d"
chmod 600 "$REAL_HOME/.ssh/conf.d/$VM_NAME"

echo "------------------------------------------------"
echo "✅ $VM_NAME is FULLY PROVISIONED and ready!"
echo "------------------------------------------------"
echo "Please wait a couple of minutes before connecting by typing:"
echo "ssh $VM_NAME"
echo "as the installation may still be completing."
echo "------------------------------------------------"