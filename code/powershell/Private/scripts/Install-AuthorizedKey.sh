#!/bin/bash
# Install-AuthorizedKey.sh
# Append a public key to a target user's authorized_keys (idempotent), fixing perms.
#
# Variables replaced by PowerShell:
#   __TARGET_USER__ : account that will own the key (e.g. svc-fotos)
#   __PUBKEY__      : full public key line ("ssh-ed25519 AAAA... comment")
#   __USE_SUDO__    : "1" to operate on another user's home via sudo, else "0"

set -e

TARGET_USER="__TARGET_USER__"
PUBKEY="__PUBKEY__"
USE_SUDO="__USE_SUDO__"

if [ "$USE_SUDO" = "1" ]; then SUDO="sudo"; else SUDO=""; fi

HOME_DIR=$($SUDO getent passwd "$TARGET_USER" | cut -d: -f6)
if [ -z "$HOME_DIR" ]; then
    echo "ERROR: cannot resolve home directory for user '$TARGET_USER'" >&2
    exit 1
fi

SSH_DIR="$HOME_DIR/.ssh"
AUTH="$SSH_DIR/authorized_keys"

$SUDO mkdir -p "$SSH_DIR"
$SUDO touch "$AUTH"

# Idempotent: only append if the key blob is not already authorized.
BLOB=$(printf '%s' "$PUBKEY" | awk '{print $2}')
if $SUDO grep -qF "$BLOB" "$AUTH"; then
    echo "AUTHKEY:already-present"
else
    printf '%s\n' "$PUBKEY" | $SUDO tee -a "$AUTH" >/dev/null
    echo "AUTHKEY:added"
fi

$SUDO chmod 700 "$SSH_DIR"
$SUDO chmod 600 "$AUTH"
$SUDO chown -R "$TARGET_USER":"$TARGET_USER" "$SSH_DIR"
echo "AUTHKEY:ok"
