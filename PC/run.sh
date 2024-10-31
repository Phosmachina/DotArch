#!/bin/sh

FILES_TO_ENCRYPT="
roles/common/files/etc/.cifscredentials
roles/common/files/home/.cache/zsh/history
roles/common/files/home/.config/Bitwarden CLI/.pass
"

test "${ENCRYPT}" = "true" && {
    while read -r file; do

        test -f "$file" || continue

        # Test if the file is not already encrypted
        ansible-vault view --vault-password-file password.sh "$file" &>/dev/null || {
            ansible-vault encrypt "$file" --vault-password-file password.sh
        }

    done <<<"$FILES_TO_ENCRYPT"
}

test "${DEPLOY}" = "true" && ansible-playbook playbook.yml --vault-password-file password.sh
