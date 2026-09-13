#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

# Production AVB profile for mondrian. Private keys must remain outside the
# Android source tree and are never stored in this repository.
ifeq ($(TARGET_BUILD_VARIANT),eng)
$(error mondrian production AVB does not support eng builds because AOSP disables hashtree verification for eng)
endif

ifneq ($(findstring --flags,$(BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS)),)
$(error mondrian production AVB refuses preconfigured vbmeta --flags arguments)
endif
ifneq ($(findstring --set_hashtree_disabled_flag,$(BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS)),)
$(error mondrian production AVB refuses disabled hashtree verification)
endif
ifneq ($(findstring --flags,$(BOARD_AVB_MAKE_VBMETA_SYSTEM_IMAGE_ARGS)),)
$(error mondrian production AVB refuses preconfigured vbmeta_system --flags arguments)
endif
ifneq ($(findstring --set_hashtree_disabled_flag,$(BOARD_AVB_MAKE_VBMETA_SYSTEM_IMAGE_ARGS)),)
$(error mondrian production AVB refuses disabled vbmeta_system hashtree verification)
endif

ifeq ($(origin MONDRIAN_AVB_KEY_DIR),undefined)
ifeq ($(strip $(HOME)),)
$(error HOME is not set; export MONDRIAN_AVB_KEY_DIR=/absolute/path/to/mondrian-avb-keys)
endif
MONDRIAN_AVB_KEY_DIR := $(HOME)/.android-certs/mondrian-avb
endif

MONDRIAN_AVB_KEY_DIR := $(strip $(MONDRIAN_AVB_KEY_DIR))
ifeq ($(MONDRIAN_AVB_KEY_DIR),)
$(error MONDRIAN_AVB_KEY_DIR must not be empty)
endif
ifeq ($(filter /%,$(MONDRIAN_AVB_KEY_DIR)),)
$(error MONDRIAN_AVB_KEY_DIR must be an absolute path outside the Android source tree)
endif
ifneq ($(words $(MONDRIAN_AVB_KEY_DIR)),1)
$(error MONDRIAN_AVB_KEY_DIR must not contain whitespace)
endif

MONDRIAN_AVB_ROOT_KEY := $(MONDRIAN_AVB_KEY_DIR)/vbmeta.pem
MONDRIAN_AVB_SYSTEM_KEY := $(MONDRIAN_AVB_KEY_DIR)/vbmeta_system.pem
MONDRIAN_AVB_RECOVERY_KEY := $(MONDRIAN_AVB_KEY_DIR)/recovery.pem

ifeq ($(wildcard $(MONDRIAN_AVB_ROOT_KEY)),)
$(error Missing $(MONDRIAN_AVB_ROOT_KEY); run device/xiaomi/sm8450-common/security/avb/generate-keys.sh)
endif
ifeq ($(wildcard $(MONDRIAN_AVB_SYSTEM_KEY)),)
$(error Missing $(MONDRIAN_AVB_SYSTEM_KEY); run device/xiaomi/sm8450-common/security/avb/generate-keys.sh)
endif
ifeq ($(wildcard $(MONDRIAN_AVB_RECOVERY_KEY)),)
$(error Missing $(MONDRIAN_AVB_RECOVERY_KEY); run device/xiaomi/sm8450-common/security/avb/generate-keys.sh)
endif

MONDRIAN_AVB_ROLLBACK_INDEX := $(shell date -d 'TZ="GMT" $(VENDOR_SECURITY_PATCH)' +%s 2>/dev/null)
ifeq ($(strip $(MONDRIAN_AVB_ROLLBACK_INDEX)),)
$(error Unable to derive AVB rollback index from VENDOR_SECURITY_PATCH=$(VENDOR_SECURITY_PATCH))
endif

# Expose the conventional custom-AVB variables for ROM build systems that
# inspect them in addition to the standard BOARD_AVB_* variables.
WITH_AVB := true
AVB_CUSTOM_ALGORITHM := SHA256_RSA2048
AVB_CUSTOM_KEY_PATH := $(MONDRIAN_AVB_ROOT_KEY)

BOARD_AVB_ENABLE := true
BOARD_AVB_ALGORITHM := SHA256_RSA2048
BOARD_AVB_KEY_PATH := $(MONDRIAN_AVB_ROOT_KEY)
BOARD_AVB_ROLLBACK_INDEX := $(MONDRIAN_AVB_ROLLBACK_INDEX)

# Keep subordinate trust domains separate. The rollback-index locations match
# the existing sm8450-common layout: root vbmeta uses location 0, recovery uses
# location 1, and vbmeta_system uses location 2.
BOARD_AVB_RECOVERY_KEY_PATH := $(MONDRIAN_AVB_RECOVERY_KEY)
BOARD_AVB_RECOVERY_ALGORITHM := SHA256_RSA2048
BOARD_AVB_RECOVERY_ROLLBACK_INDEX := $(MONDRIAN_AVB_ROLLBACK_INDEX)
BOARD_AVB_RECOVERY_ROLLBACK_INDEX_LOCATION := 1

BOARD_AVB_VBMETA_SYSTEM := system system_ext product
BOARD_AVB_VBMETA_SYSTEM_KEY_PATH := $(MONDRIAN_AVB_SYSTEM_KEY)
BOARD_AVB_VBMETA_SYSTEM_ALGORITHM := SHA256_RSA2048
BOARD_AVB_VBMETA_SYSTEM_ROLLBACK_INDEX := $(MONDRIAN_AVB_ROLLBACK_INDEX)
BOARD_AVB_VBMETA_SYSTEM_ROLLBACK_INDEX_LOCATION := 2

MONDRIAN_SECURE_AVB_CONFIGURED := true
