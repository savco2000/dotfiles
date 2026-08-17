#!/bin/bash
# Target extraction tool for fresh host builds
# Make executable: chmod +x get-vs-code-uris.sh
# Usage: sudo ./get-vs-code-uris.sh

DB_PATH="$HOME/.config/Code/User/globalStorage/state.vscdb"

if [ ! -f "$DB_PATH" ]; then
    echo "❌ Error: VS Code storage database not found at $DB_PATH"
    exit 1
fi

cat <<'EOF'
# --- START DEV-VM ---
alias dev-start='virsh start dev-vm'

# --- GRACEFUL ENVIRONMENT TEARDOWN ---
_dev_stop() {
    echo "🛑 Initiating graceful tear-down of your remote development stack..."

    # 1. Identify and gracefully close local VS Code windows matching your remote VM
    if command -v wmctrl &> /dev/null; then
        echo "🪟 Closing local VS Code DevContainer windows..."

        # Scan active desktop windows for your devcontainer strings and close them cleanly
        wmctrl -l | grep -E "Dev Container|@.*dev-vm" | awk '{print $1}' | while read -r win_id; do
            wmctrl -i -c "$win_id"
        done
        sleep 1
    fi

    # 2. Check if the VM is running, and shut it down cleanly
    if virsh domstate dev-vm 2>/dev/null | grep -q "running"; then
        echo "🔌 Sending ACPI shutdown signal to dev-vm..."
        virsh shutdown dev-vm

        # 3. Wait loop until the KVM domain has fully turned off
        echo -n "⏳ Waiting for VM to safely power down"
        while virsh domstate dev-vm 2>/dev/null | grep -q "running"; do
            printf "."
            sleep 1
        done
        echo -e "\n🔒 dev-vm has successfully shut down. Environment cold and secure."
    else
        echo "ℹ️ dev-vm is already powered off."
    fi
}
alias dev-stop=_dev_stop

EOF

# Extract unique instances containing the dev-container hex signature
strings "$DB_PATH" | grep -E -o "dev-container\+[0-9a-fA-F]+@ssh-remote\+dev-vm" | sort -u | while read -r line; do
    
    # Isolate just the raw Hex string payload
    HEX_STRING=$(echo "$line" | sed -E 's/dev-container\+([0-9a-fA-F]+)@.*/\1/')
    
    # Decode the hex data natively to catch the repository directory name
    FOLDER_NAME=$(python3 -c "import json; d=bytes.fromhex('$HEX_STRING').decode('utf-8'); print(json.loads(d).get('hostPath','').split('/')[-1])" 2>/dev/null)
    
    # Fallback to placeholder if parsing drops out
    if [ -z "$FOLDER_NAME" ]; then
        FOLDER_NAME="your-project"
    fi

    # Render a copy-ready shell function and alias
    FUNCTION_NAME="_dev_${FOLDER_NAME,,}"
    ALIAS_NAME="dev-${FOLDER_NAME,,}"

    echo "# --- ${FOLDER_NAME^^} CONTAINER ENGINE ---"
    echo "${FUNCTION_NAME}() {"
    echo '    if ! virsh domstate dev-vm 2>/dev/null | grep -q "running"; then'
    echo '        echo "🔌 dev-vm is powered off. Booting KVM domain..."'
    echo '        virsh start dev-vm'
    echo '    fi'
    echo ''
    echo '    echo -n "⏳ Waiting for network and SSH to wake up"'
    echo '    until ssh -o ConnectTimeout=1 -o BatchMode=yes dev-vm true 2>/dev/null; do'
    echo '        printf "."'
    echo '        sleep 1'
    echo '    done'
    echo "    echo -e \"\\n🚀 VM is awake! Launching ${FOLDER_NAME^} DevContainer...\""
    echo ''
    echo "    code --folder-uri \"vscode-remote://dev-container+${HEX_STRING}@ssh-remote+dev-vm/workspaces/${FOLDER_NAME}\""
    echo '}'
    echo "alias ${ALIAS_NAME}=${FUNCTION_NAME}"
    echo ''
done