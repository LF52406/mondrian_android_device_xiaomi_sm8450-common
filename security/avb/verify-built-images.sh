#!/usr/bin/env bash
# Copyright (C) 2026 The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

rom_root="${1:-${ANDROID_BUILD_TOP:-$PWD}}"
out_dir="${OUT_DIR:-$rom_root/out}"
if [[ "$out_dir" != /* ]]; then
    out_dir="$rom_root/$out_dir"
fi

if [[ -n "${ANDROID_PRODUCT_OUT:-}" ]]; then
    product_out="$ANDROID_PRODUCT_OUT"
    if [[ "$product_out" != /* ]]; then
        product_out="$rom_root/$product_out"
    fi
else
    product_out="$out_dir/target/product/mondrian"
fi

if [[ -n "${MONDRIAN_AVB_KEY_DIR:-}" ]]; then
    key_dir="$MONDRIAN_AVB_KEY_DIR"
elif [[ -n "${HOME:-}" ]]; then
    key_dir="$HOME/.android-certs/mondrian-avb"
else
    echo "HOME is not set; export MONDRIAN_AVB_KEY_DIR=/absolute/path/to/mondrian-avb-keys." >&2
    exit 2
fi

if [[ "$key_dir" != /* ]]; then
    echo "MONDRIAN_AVB_KEY_DIR must resolve to an absolute path." >&2
    exit 2
fi

for key in vbmeta.pem vbmeta_system.pem recovery.pem; do
    if [[ ! -f "$key_dir/$key" ]]; then
        echo "Missing key: $key_dir/$key" >&2
        exit 1
    fi
done

for image in vbmeta.img vbmeta_system.img recovery.img; do
    if [[ ! -f "$product_out/$image" ]]; then
        echo "Missing built image: $product_out/$image" >&2
        exit 1
    fi
done

if command -v avbtool >/dev/null 2>&1; then
    avbtool_cmd=(avbtool)
elif [[ -x "$out_dir/soong/host/linux-x86/bin/avbtool" ]]; then
    avbtool_cmd=("$out_dir/soong/host/linux-x86/bin/avbtool")
elif [[ -x "$out_dir/host/linux-x86/bin/avbtool" ]]; then
    avbtool_cmd=("$out_dir/host/linux-x86/bin/avbtool")
elif [[ -f "$rom_root/external/avb/avbtool.py" ]]; then
    avbtool_cmd=(python3 "$rom_root/external/avb/avbtool.py")
else
    echo "Unable to locate avbtool. Build it first or add it to PATH." >&2
    exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

"${avbtool_cmd[@]}" extract_public_key \
    --key "$key_dir/vbmeta_system.pem" \
    --output "$tmp_dir/vbmeta_system.avbpubkey"
"${avbtool_cmd[@]}" extract_public_key \
    --key "$key_dir/recovery.pem" \
    --output "$tmp_dir/recovery.avbpubkey"

vbmeta_info="$("${avbtool_cmd[@]}" info_image --image "$product_out/vbmeta.img")"
if ! grep -Eq '^[[:space:]]*Algorithm:[[:space:]]*SHA256_RSA2048([[:space:]]|$)' <<<"$vbmeta_info"; then
    echo "vbmeta.img is not signed with SHA256_RSA2048." >&2
    exit 1
fi
if ! grep -Eq '^[[:space:]]*Flags:[[:space:]]*0([[:space:]]|$)' <<<"$vbmeta_info"; then
    echo "vbmeta.img does not have secure AVB flags (expected Flags: 0)." >&2
    exit 1
fi

system_info="$("${avbtool_cmd[@]}" info_image --image "$product_out/vbmeta_system.img")"
if ! grep -Eq '^[[:space:]]*Algorithm:[[:space:]]*SHA256_RSA2048([[:space:]]|$)' <<<"$system_info"; then
    echo "vbmeta_system.img is not signed with SHA256_RSA2048." >&2
    exit 1
fi
if ! grep -Eq '^[[:space:]]*Flags:[[:space:]]*0([[:space:]]|$)' <<<"$system_info"; then
    echo "vbmeta_system.img does not have secure AVB flags (expected Flags: 0)." >&2
    exit 1
fi

"${avbtool_cmd[@]}" verify_image \
    --image "$product_out/vbmeta.img" \
    --key "$key_dir/vbmeta.pem" \
    --expected_chain_partition "vbmeta_system:2:$tmp_dir/vbmeta_system.avbpubkey" \
    --expected_chain_partition "recovery:1:$tmp_dir/recovery.avbpubkey"

"${avbtool_cmd[@]}" verify_image \
    --image "$product_out/vbmeta_system.img" \
    --key "$key_dir/vbmeta_system.pem"

"${avbtool_cmd[@]}" verify_image \
    --image "$product_out/recovery.img" \
    --key "$key_dir/recovery.pem"

printf 'PASS: mondrian AVB images use the configured production keys and vbmeta Flags: 0.\n'
