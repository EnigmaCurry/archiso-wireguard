#!/usr/bin/env bash
# Create any missing files under secrets/ from config-templates/.
# Existing files are never touched.
#
# secrets/ is where you keep the configuration for your sticks on this
# machine; provision.sh copies it onto a stick's config partition. You
# can skip it entirely and edit the files on the stick directly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS="${ROOT}/secrets"
TEMPLATES="${ROOT}/config-templates"

mkdir -p "${SECRETS}"
chmod 700 "${SECRETS}"

# README.txt only makes sense on the stick itself.
while IFS= read -r src; do
    rel=${src#"${TEMPLATES}"/}
    dest="${SECRETS}/${rel}"
    if [[ -e ${dest} ]]; then
        echo "exists:  secrets/${rel}"
        continue
    fi
    mkdir -p "$(dirname "${dest}")"
    (umask 077 && cat "${src}" >"${dest}")
    echo "created: secrets/${rel}  (edit it)"
done < <(find "${TEMPLATES}" -type f ! -name README.txt | sort)

chmod 700 "${SECRETS}"/*/ 2>/dev/null || true
