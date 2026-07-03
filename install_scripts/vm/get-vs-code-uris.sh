#!/bin/bash
# Target extraction tool for fresh host builds
# Make executable: chmod +x get-vs-code-uris.sh
# Usage: sudo ./get-vs-code-uris.sh

DB_PATH="$HOME/.config/Code/User/globalStorage/state.vscdb"

if [ ! -f "$DB_PATH" ]; then
    echo "❌ Error: VS Code storage database not found at $DB_PATH"
    exit 1
fi

echo "=========================================================="
echo "🎯 TARGET DEVCONTAINER URIS EXTRACTED FROM CACHE"
echo "=========================================================="
echo ""

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

    # Render a clean, scannable layout
    echo "📂 PROJECT: $FOLDER_NAME"
    echo "🔑 Hex Key String:"
    echo "$HEX_STRING"
    echo ""
    echo "📋 Ready-to-use Shell Alias (Copy-Paste into ~/.bashrc or ~/.zshrc):"
    echo "alias dev-${FOLDER_NAME,,}='code --folder-uri \"vscode-remote://dev-container+${HEX_STRING}@ssh-remote+dev-vm/workspaces/${FOLDER_NAME}\"'"
    echo "----------------------------------------------------------"
done