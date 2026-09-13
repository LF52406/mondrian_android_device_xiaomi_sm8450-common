# Mondrian production AVB profile

This directory contains the build-time Verified Boot profile used by the
`mondrian` device tree. It strengthens the ROM's AVB chain; it does not spoof
or modify the physical bootloader lock state.

## Security model

When `MONDRIAN_SECURE_AVB := true` is set before including
`device/xiaomi/sm8450-common/BoardConfigCommon.mk`, the development AVB
configuration is replaced with a fail-closed production profile:

- top-level `vbmeta` is signed with a private device-maintainer key;
- `vbmeta_system` and `recovery` use independent private keys;
- the top-level development `--flags 3` setting is not added, so verification
  and hashtree enforcement remain enabled;
- rollback indexes are derived from `VENDOR_SECURITY_PATCH`;
- existing rollback-index locations are preserved: root = 0, recovery = 1,
  `vbmeta_system` = 2;
- the build fails immediately if any required private key is missing;\n- `eng` builds and preconfigured AVB disable flags are rejected.

The implementation uses standard AOSP `BOARD_AVB_*` variables only. There is
no framework patch, daemon, system service, property spoofing, or runtime cost.

## Private keys

Keys are intentionally never stored in the source tree. The default private
key directory is:

```
$HOME/.android-certs/mondrian-avb
```

Generate a new set once on the build server:

```bash
bash device/xiaomi/sm8450-common/security/avb/generate-keys.sh
```

To use another location:

```bash
bash device/xiaomi/sm8450-common/security/avb/generate-keys.sh /absolute/private/path
export MONDRIAN_AVB_KEY_DIR=/absolute/private/path
```

The directory contains:

```
vbmeta.pem
vbmeta_system.pem
recovery.pem
```

All three keys are independent RSA-2048 private keys and the build uses
`SHA256_RSA2048`, matching the existing sm8450-common AVB algorithm while
removing the public AOSP test key.

Back these files up securely. Losing or replacing them changes the signing
identity of future builds. Never upload them to Git, a ROM zip, build logs, or
public file storage.

## Build

After the keys exist, build the ROM normally. The device tree enables the
profile before `BoardConfigCommon.mk` is parsed, so the same AVB configuration
is used by any Android 17 ROM that consumes these paired device trees and does
not replace their board configuration later.

## Post-build verification

After a successful build run:

```bash
bash device/xiaomi/sm8450-common/security/avb/verify-built-images.sh
```

The verifier checks the actual generated images, not only Make variables. It
requires:

- `vbmeta.img` signed by `vbmeta.pem`;
- `vbmeta_system.img` signed by `vbmeta_system.pem`;
- `recovery.img` signed by `recovery.pem`;
- `Flags: 0` in both vbmeta images;
- the expected chain-partition keys and rollback-index locations.

This final audit catches a ROM build system that might override AVB arguments
after the device BoardConfig has been parsed.

## Bootloader warning

A production-signed AVB chain does not make an unlocked bootloader report
itself as locked and does not make hardware-backed attestation return
`deviceLocked=true`. Do not relock a Xiaomi bootloader solely because these
images are signed. Relocking is safe only if the device bootloader is known to
support provisioning and booting a custom AVB root of trust for this exact
device and key.
