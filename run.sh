#!/bin/sh

set -euo pipefail

FILES_TO_ENCRYPT="
roles/system/files/etc/wireguard/Peer_FC_L-ANTLIA.conf
roles/system/files/etc/wireguard/Peer_LP_L-CENTAURUS.conf
"
#roles/common/files/etc/.cifscredentials
#roles/common/files/home/.cache/zsh/history
#roles/common/files/home/.config/Bitwarden CLI/.pass

ENCRYPT=false
DEPLOY=false

# Parse CLI arguments
while [ $# -gt 0 ]; do
    case "$1" in
    --encrypt)
        ENCRYPT=true
        ;;
    --deploy)
        DEPLOY=true
        ;;
    --all)
        ENCRYPT=true
        DEPLOY=true
        ;;
    *)
        echo "Usage: $0 [--encrypt] [--deploy] [--all]"
        exit 1
        ;;
    esac
    shift
done

if [ ! -f "password.sh" ] || [ ! -x "password.sh" ]; then
    echo "Error: password.sh file missing or not executable"
    exit 1
fi

# Encrypt step
if [ "$ENCRYPT" = true ]; then
    while read -r file; do
        [ -f "$file" ] || continue

        # Test if the file is not already encrypted
        ansible-vault view --vault-password-file password.sh "$file" &>/dev/null || {
            ansible-vault encrypt "$file" --vault-password-file password.sh
        }
    done <<<"$FILES_TO_ENCRYPT"
fi

# Deploy step
if [ "$DEPLOY" = true ]; then
    ansible-playbook playbook.yml --vault-password-file password.sh
fi
