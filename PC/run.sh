#!/bin/sh

FILES_TO_ENCRYPT="
roles/common/files/home/.cache/zsh/history
"

test "${ENCRYPT}" = "true" && {
  for file in $FILES_TO_ENCRYPT
  do
     # Test if the file is not already encrypted
     if ! ansible-vault view --vault-password-file ./password.sh ${file} &> /dev/null
     then
         ansible-vault encrypt "${file}" --vault-password-file ./password.sh
     fi
  done
}

test "${DEPLOY}" = "true" && ansible-playbook playbook.yml --vault-password-file password
