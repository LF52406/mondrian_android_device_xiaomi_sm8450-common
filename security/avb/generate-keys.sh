#!/usr/bin/env bash
# Copyright (C) 2026 The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl is required to generate AVB keys." >&2
    exit 1
fi

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [absolute-key-directory]" >&2
    exit 2
fi

if [[ $# -eq 1 ]]; then
    key_dir="$1"
else
    if [[ -z "${HOME:-}" ]]; then
        echo "HOME is not set; pass an absolute key directory explicitly." >&2
        exit 2
    fi
    key_dir="$HOME/.android-certs/mondrian-avb"
fi

case "$key_dir" in
    /*) ;;
    *)
        echo "Key directory must be an absolute path outside the Android source tree." >&2
        exit 2
        ;;
esac

if [[ "$key_dir" =~ [[:space:]] ]]; then
    echo "Key directory must not contain whitespace." >&2
    exit 2
fi

mkdir -p -- "$key_dir"
chmod 700 -- "$key_dir"

keys=(vbmeta.pem vbmeta_system.pem recovery.pem)
for key in "${keys[@]}"; do
    if [[ -e "$key_dir/$key" ]]; then
        echo "Refusing to overwrite existing key: $key_dir/$key" >&2
        exit 1
    fi
done

tmp_dir="$(mktemp -d "$key_dir/.generate-avb-keys.XXXXXX")"
trap 'rm -rf -- "$tmp_dir"' EXIT
umask 077

for key in "${keys[@]}"; do
    openssl genpkey -algorithm RSA \
        -pkeyopt rsa_keygen_bits:2048 \
        -out "$tmp_dir/$key" >/dev/null 2>&1
    openssl pkey -in "$tmp_dir/$key" -check -noout >/dev/null 2>&1
    chmod 600 -- "$tmp_dir/$key"
done

for key in "${keys[@]}"; do
    mv -- "$tmp_dir/$key" "$key_dir/$key"
done

printf 'Created mondrian production AVB keys in %s\n' "$key_dir"
printf 'Keep this directory private and backed up. Do not commit these PEM files.\n'
printf 'Builds use SHA256_RSA2048 with independent root, vbmeta_system, and recovery keys.\n'
printf 'To use another location later: export MONDRIAN_AVB_KEY_DIR=%q\n' "$key_dir"
