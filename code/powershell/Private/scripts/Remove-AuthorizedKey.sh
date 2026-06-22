#!/bin/bash
# Remove-AuthorizedKey.sh
# Remove a public key from a target user's authorized_keys (backup + atomic write).
# Matches by base64 blob or by SHA256 fingerprint. Refuses to leave zero keys
# unless forced (lockout guard).
#
# Variables replaced by PowerShell:
#   __TARGET_USER__ : account
#   __MATCH_MODE__  : "blob" | "fingerprint"
#   __MATCH_VALUE__ : the public key blob (base64) OR the fingerprint (SHA256:...)
#   __USE_SUDO__    : "1"/"0"
#   __FORCE__       : "1"/"0" allow removing the last remaining key

set -e

TARGET_USER="__TARGET_USER__"
MATCH_MODE="__MATCH_MODE__"
MATCH_VALUE="__MATCH_VALUE__"
USE_SUDO="__USE_SUDO__"
FORCE="__FORCE__"

if [ "$USE_SUDO" = "1" ]; then SUDO="sudo"; else SUDO=""; fi

HOME_DIR=$($SUDO getent passwd "$TARGET_USER" | cut -d: -f6)
AUTH="$HOME_DIR/.ssh/authorized_keys"

if ! $SUDO test -f "$AUTH"; then
    echo "AUTHKEY:no-file"
    exit 0
fi

TS=$(date +%Y%m%d%H%M%S)
$SUDO cp -p "$AUTH" "$AUTH.bak.$TS"

WORK="/tmp/ak.$$.work"
NEW="/tmp/ak.$$.new"
$SUDO cat "$AUTH" > "$WORK"      # current user owns WORK (content via sudo)
: > "$NEW"

removed=0
while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then printf '%s\n' "$line" >> "$NEW"; continue; fi
    case "$line" in \#*) printf '%s\n' "$line" >> "$NEW"; continue;; esac
    keep=1
    if [ "$MATCH_MODE" = "blob" ]; then
        blob=$(printf '%s' "$line" | awk '{print $2}')
        [ "$blob" = "$MATCH_VALUE" ] && keep=0
    else
        fp=$(printf '%s' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
        [ "$fp" = "$MATCH_VALUE" ] && keep=0
    fi
    if [ "$keep" = "1" ]; then printf '%s\n' "$line" >> "$NEW"; else removed=$((removed+1)); fi
done < "$WORK"

remaining=$(grep -cvE '^[[:space:]]*($|#)' "$NEW" || true)
if [ "$remaining" = "0" ] && [ "$FORCE" != "1" ]; then
    echo "ERROR: removal would leave 0 authorized keys for '$TARGET_USER' (use -Force to override)" >&2
    rm -f "$WORK" "$NEW"
    exit 2
fi

$SUDO cp "$NEW" "$AUTH.new.$$"
$SUDO chmod 600 "$AUTH.new.$$"
$SUDO chown "$TARGET_USER":"$TARGET_USER" "$AUTH.new.$$"
$SUDO mv "$AUTH.new.$$" "$AUTH"      # atomic replace
rm -f "$WORK" "$NEW"

echo "REMOVED:$removed"
echo "AUTHKEY:ok"
