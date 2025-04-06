#!/bin/bash

# Script to create a new user with SSH access and zsh as default shell
# Usage: ./create_ssh_user.sh [username] [ssh public key file] [usergroup]

set -e

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Process arguments
USERNAME=${1:-}
SSH_KEY_FILE=${2:-}
USERGROUP=${3:-}

# Check if zsh is installed
if ! command -v zsh &> /dev/null; then
    echo "Warning: zsh is not installed. Will use bash as default shell." >&2
    DEFAULT_SHELL=$(which bash)
else
    DEFAULT_SHELL=$(which zsh)
fi

# Prompt for username if not provided
if [ -z "$USERNAME" ]; then
    read -p "Enter username: " USERNAME
fi

# Validate username
if [[ ! "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "Invalid username format. Use only lowercase letters, numbers, underscores, and hyphens." >&2
    exit 1
fi

# Check if user already exists
if id "$USERNAME" &>/dev/null; then
    echo "User '$USERNAME' already exists. Aborting." >&2
    exit 1
fi

# Prompt for SSH key if not provided
if [ -z "$SSH_KEY_FILE" ]; then
    read -p "Enter path to SSH public key file: " SSH_KEY_FILE
fi

# Validate SSH key file exists
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "SSH key file not found: $SSH_KEY_FILE" >&2
    exit 1
fi

# Validate SSH key format
if ! grep -q "^ssh-.*" "$SSH_KEY_FILE"; then
    echo "Invalid SSH public key format in $SSH_KEY_FILE" >&2
    exit 1
fi

# Prompt for usergroup if not provided
if [ -z "$USERGROUP" ]; then
    read -p "Enter usergroup (leave empty to create a new group matching username): " USERGROUP
fi

echo "=== Creating new user with SSH access ==="
echo "Shell: $DEFAULT_SHELL"
echo "Username: $USERNAME"
echo "SSH Key: $SSH_KEY_FILE"
echo "Usergroup: ${USERGROUP:-$USERNAME (new)}"
echo

# Create user group if it doesn't exist
if [ -n "$USERGROUP" ]; then
    echo "Checking if group '$USERGROUP' exists..."
    if ! getent group "$USERGROUP" > /dev/null; then
        echo "Creating group '$USERGROUP'..."
        groupadd "$USERGROUP"
    else
        echo "Group '$USERGROUP' already exists."
    fi
    # Create user with specified group
    echo "Creating user '$USERNAME' with group '$USERGROUP'..."
    useradd -m -g "$USERGROUP" -s "$DEFAULT_SHELL" "$USERNAME"
else
    # Create user with default group
    echo "Creating user '$USERNAME' with matching group..."
    useradd -m -U -s "$DEFAULT_SHELL" "$USERNAME"
    USERGROUP="$USERNAME"
fi

# Create SSH directory with proper permissions
echo "Setting up SSH directory..."
USER_HOME=$(eval echo ~$USERNAME)
SSH_DIR="$USER_HOME/.ssh"
mkdir -p "$SSH_DIR"
chown "$USERNAME:$USERGROUP" "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Add SSH key to authorized_keys
echo "Adding SSH key to authorized_keys..."
cat "$SSH_KEY_FILE" > "$SSH_DIR/authorized_keys"
chown "$USERNAME:$USERGROUP" "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"

# Create datalake folder
echo "Creating datalake folder..."
DATALAKE_DIR="/srv/${USERGROUP}-data/${USERNAME}"
mkdir -p "$DATALAKE_DIR"
chown "$USERNAME:$USERGROUP" "$DATALAKE_DIR"
# Allow user, group, and sudo access
chmod 770 "$DATALAKE_DIR"
# Give access to sudo group as well
if getent group sudo > /dev/null; then
    setfacl -m g:sudo:rwx "$DATALAKE_DIR" 2>/dev/null || {
        echo "Warning: setfacl not available, adding sudo group as an owner instead"
        chown "$USERNAME:$USERGROUP" "$DATALAKE_DIR"
        chmod 775 "$DATALAKE_DIR"
    }
fi

# Add DATA_LAKE env variable to .api_keys file
echo "Setting up DATA_LAKE environment variable..."
API_KEYS_FILE="$USER_HOME/.api_keys"
if [ -f "$API_KEYS_FILE" ]; then
    # Check if DATA_LAKE is already defined
    if grep -q "export DATA_LAKE=" "$API_KEYS_FILE"; then
        # Update existing DATA_LAKE
        sed -i "s|export DATA_LAKE=.*|export DATA_LAKE=\"$DATALAKE_DIR\"|" "$API_KEYS_FILE"
    else
        # Append to existing file
        echo "" >> "$API_KEYS_FILE"
        echo "# Datalake directory" >> "$API_KEYS_FILE"
        echo "export DATA_LAKE=\"$DATALAKE_DIR\"" >> "$API_KEYS_FILE"
    fi
else
    # Create new file
    echo "# Datalake directory" > "$API_KEYS_FILE"
    echo "export DATA_LAKE=\"$DATALAKE_DIR\"" >> "$API_KEYS_FILE"
fi
chown "$USERNAME:$USERGROUP" "$API_KEYS_FILE"
chmod 600 "$API_KEYS_FILE"

# Ensure SSH service is running
echo "Ensuring SSH service is active..."
if command -v systemctl &> /dev/null; then
    systemctl is-active --quiet sshd || systemctl start sshd
    systemctl is-enabled --quiet sshd || systemctl enable sshd
elif command -v service &> /dev/null; then
    service ssh status &> /dev/null || service ssh start
else
    echo "Warning: Could not verify SSH service status - please check manually" >&2
fi

# Verify sshd_config has appropriate settings
echo "Checking SSH server configuration..."
SSHD_CONFIG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ]; then
    # Ensure PasswordAuthentication is set appropriately (optional)
    if grep -q "^#PasswordAuthentication" "$SSHD_CONFIG"; then
        echo "Enabling public key authentication in SSH config..."
        sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' "$SSHD_CONFIG"
        sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' "$SSHD_CONFIG"
        echo "SSH configuration updated. Restarting SSH service..."
        
        if command -v systemctl &> /dev/null; then
            systemctl restart sshd
        elif command -v service &> /dev/null; then
            service ssh restart
        fi
    fi
else
    echo "Warning: SSH config file not found at $SSHD_CONFIG" >&2
fi

echo
echo "=== User creation complete ==="
echo "Username: $USERNAME"
echo "Home directory: $USER_HOME"
echo "SSH key installed: $SSH_KEY_FILE"
echo "Usergroup: $USERGROUP"
echo "Default shell: $DEFAULT_SHELL"
echo "Datalake directory: $DATALAKE_DIR"
echo
echo "The user should now be able to connect via SSH using the provided key."

# Prompt for password setting
read -p "Do you want to set a password for the user? (y/n): " SET_PASSWORD
if [[ "$SET_PASSWORD" =~ ^[Yy] ]]; then
    echo "Setting password for $USERNAME..."
    passwd "$USERNAME"
else
    echo "No password set. User will authenticate with SSH key only."
    echo "You can set a password later with: passwd $USERNAME"
fi
