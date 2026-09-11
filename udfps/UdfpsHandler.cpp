/*
 * Copyright (C) 2022-2025 The LineageOS Project
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#define LOG_TAG "UdfpsHandler.xiaomi_sm8450"

#include <aidl/android/hardware/biometrics/fingerprint/BnFingerprint.h>
#include <android-base/logging.h>
#include <android-base/properties.h>
#include <android-base/unique_fd.h>

#include <poll.h>
#include <sys/ioctl.h>
#include <atomic>
#include <fstream>
#include <thread>

#include <display/drm/mi_disp.h>
#include <linux/xiaomi_touch.h>

#include "UdfpsHandler.h"

#define COMMAND_NIT 10
#define TARGET_BRIGHTNESS_OFF 0
#define TARGET_BRIGHTNESS_1000NIT 1
#define TARGET_BRIGHTNESS_110NIT 6

#define LOW_BRIGHTNESS_THRESHHOLD 100

#define COMMAND_FOD_PRESS_STATUS 1
#define COMMAND_FOD_PRESS_X 2
#define COMMAND_FOD_PRESS_Y 3
#define PARAM_FOD_PRESSED 1
#define PARAM_FOD_RELEASED 0

#define DISP_FEATURE_PATH "/dev/mi_display/disp_feature"
#define TOUCH_DEV_PATH "/dev/xiaomi-touch"

using ::aidl::android::hardware::biometrics::fingerprint::AcquiredInfo;

namespace {

static std::shared_ptr<disp_event_resp> parseDispEvent(int fd) {
    disp_event header;
    ssize_t headerSize = read(fd, &header, sizeof(header));
    if (headerSize < sizeof(header)) {
        LOG(ERROR) << "unexpected display event header size: " << headerSize;
        return nullptr;
    }

    std::shared_ptr<disp_event_resp> response(static_cast<disp_event_resp*>(malloc(header.length)),
                                              free);
    if (!response) {
        LOG(ERROR) << "failed to allocate memory for display event response";
        return nullptr;
    }
    response->base = header;

    int dataLength = response->base.length - sizeof(response->base);
    if (dataLength < 0) {
        LOG(ERROR) << "invalid data length: " << response->base.length;
        return nullptr;
    }

    ssize_t dataSize = read(fd, &response->data, dataLength);
    if (dataSize < dataLength) {
        LOG(ERROR) << "unexpected display event data size: " << dataSize;
        return nullptr;
    }

    return response;
}

struct disp_base displayBasePrimary = {
        .flag = 0,
        .disp_id = MI_DISP_PRIMARY,
};

}  // anonymous namespace

class XiaomiSm8450UdfpsHandler : public UdfpsHandler {
  public:
    void init(fingerprint_device_t* device) {
        mDevice = device;
        disp_fd_ = android::base::unique_fd(open(DISP_FEATURE_PATH, O_RDWR));
        touch_fd_ = android::base::unique_fd(open(TOUCH_DEV_PATH, O_RDWR));

        // Thread to listen for fod ui changes
        std::thread([this]() {
            android::base::unique_fd fd(open(DISP_FEATURE_PATH, O_RDWR));
            if (fd < 0) {
                LOG(ERROR) << "failed to open " << DISP_FEATURE_PATH << " , err: " << fd;
                return;
            }

            // Register for FOD events
            struct disp_event_req displayEventRequest = {
                    .base = displayBasePrimary,
                    .type = MI_DISP_EVENT_FOD,
            };
            if (ioctl(fd.get(), MI_DISP_IOCTL_REGISTER_EVENT, &displayEventRequest) < 0) {
                LOG(ERROR) << "failed to register FOD event";
                return;
            }

            struct pollfd dispEventPoll = {
                    .fd = fd.get(),
                    .events = POLLIN,
                    .revents = 0,
            };

            while (true) {
                int rc = poll(&dispEventPoll, 1, -1);
                if (rc < 0) {
                    LOG(ERROR) << "failed to poll " << DISP_FEATURE_PATH << ", err: " << rc;
                    continue;
                }

                std::shared_ptr<disp_event_resp> response = parseDispEvent(fd.get());
                if (!response) {
                    continue;
                }

                if (response->base.type != MI_DISP_EVENT_FOD) {
                    LOG(ERROR) << "unexpected display event: " << response->base.type;
                    continue;
                }

                int value = response->data[0];
                LOG(DEBUG) << "received data: " << std::bitset<8>(value);

                bool localHbmUiReady = value & LOCAL_HBM_UI_READY;
                bool requestLowBrightnessCapture = value & FOD_LOW_BRIGHTNESS_CAPTURE;

                /*
                 * Screen-off unlock can race with the display wake-up path:
                 * authentication finishes and LHBM is disabled, then a stale
                 * LOCAL_HBM_UI_READY event arrives and re-arms fingerprint
                 * illumination. Keep the authentication completion state
                 * separate from the display event thread and never allow a
                 * late UI_READY event to turn the FOD spot back on.
                 *
                 * The UI_READY event also gives us a reliable point at which
                 * the display path is alive again, so retry LHBM OFF here in
                 * case the original OFF raced with panel wake/AOD exit.
                 */
                if (localHbmUiReady && mAuthCompleted.load(std::memory_order_acquire)) {
                    LOG(WARNING) << "suppressing stale LOCAL_HBM_UI_READY after authentication";

                    mDevice->extCmd(mDevice, COMMAND_NIT, TARGET_BRIGHTNESS_OFF);
                    setLocalHbm(fd.get(), LHBM_TARGET_BRIGHTNESS_OFF_FINGER_UP);
                    continue;
                }

                mDevice->extCmd(mDevice, COMMAND_NIT,
                                localHbmUiReady
                                        ? (requestLowBrightnessCapture ? TARGET_BRIGHTNESS_110NIT
                                                                       : TARGET_BRIGHTNESS_1000NIT)
                                        : TARGET_BRIGHTNESS_OFF);
            }
        }).detach();
    }

    void onFingerDown(uint32_t x, uint32_t y, float /*minor*/, float /*major*/) {
        LOG(DEBUG) << __func__ << "x: " << x << ", y: " << y;

        // A real new pointer-down starts a fresh UDFPS illumination cycle.
        mAuthCompleted.store(false, std::memory_order_release);

        mDevice->extCmd(mDevice, COMMAND_FOD_PRESS_X, x);
        mDevice->extCmd(mDevice, COMMAND_FOD_PRESS_Y, y);
        mDevice->extCmd(mDevice, COMMAND_FOD_PRESS_STATUS, PARAM_FOD_PRESSED);

        // Update fod_finger_state node in case hwmodule polls it
        struct touch_mode_request touchRequest = {
                .mode = TOUCH_MODE_FOD_FINGER_STATE,
                .value = 1,
        };
        if (ioctl(touch_fd_.get(), TOUCH_IOC_SET_CUR_VALUE, &touchRequest) < 0) {
            PLOG(ERROR) << "failed to set TOUCH_MODE_FOD_FINGER_STATE=1";
        }

        // Request HBM
        setLocalHbm(disp_fd_.get(), LHBM_TARGET_BRIGHTNESS_WHITE_1000NIT);
    }

    void onFingerUp() {
        LOG(DEBUG) << __func__;

        mDevice->extCmd(mDevice, COMMAND_FOD_PRESS_X, 0);
        mDevice->extCmd(mDevice, COMMAND_FOD_PRESS_Y, 0);
        mDevice->extCmd(mDevice, COMMAND_FOD_PRESS_STATUS, PARAM_FOD_RELEASED);

        /*
         * Reset vendor-side illumination immediately instead of waiting for a
         * later LOCAL_HBM_UI_NONE event. This keeps the fingerprint HAL and the
         * panel LHBM state in sync when unlock completes during panel wake.
         */
        mDevice->extCmd(mDevice, COMMAND_NIT, TARGET_BRIGHTNESS_OFF);

        // Disable HBM
        setLocalHbm(disp_fd_.get(), LHBM_TARGET_BRIGHTNESS_OFF_FINGER_UP);

        // Update fod_finger_state node in case hwmodule polls it
        struct touch_mode_request touchRequest = {
                .mode = TOUCH_MODE_FOD_FINGER_STATE,
                .value = 0,
        };
        if (ioctl(touch_fd_.get(), TOUCH_IOC_SET_CUR_VALUE, &touchRequest) < 0) {
            PLOG(ERROR) << "failed to set TOUCH_MODE_FOD_FINGER_STATE=0";
        }
    }

    void onAcquired(int32_t result, int32_t vendorCode) {
        LOG(DEBUG) << __func__ << " result: " << result << " vendorCode: " << vendorCode;
        switch (static_cast<AcquiredInfo>(result)) {
            case AcquiredInfo::GOOD:
            case AcquiredInfo::PARTIAL:
            case AcquiredInfo::INSUFFICIENT:
            case AcquiredInfo::SENSOR_DIRTY:
            case AcquiredInfo::TOO_SLOW:
            case AcquiredInfo::TOO_FAST:
            case AcquiredInfo::TOO_DARK:
            case AcquiredInfo::TOO_BRIGHT:
            case AcquiredInfo::IMMOBILE:
            case AcquiredInfo::LIFT_TOO_SOON:
                onFingerUp();
                break;
            default:
                break;
        }
    }

    void onAuthenticationSucceeded() {
        /*
         * Publish completion before cleanup. The FOD event thread runs
         * concurrently and must not be able to re-enable illumination between
         * authentication success and the LHBM/NIT OFF sequence.
         */
        mAuthCompleted.store(true, std::memory_order_release);
        onFingerUp();
    }

    void onAuthenticationFailed() {
        /*
         * This authentication attempt is over as well. A subsequent genuine
         * onFingerDown() clears the guard and starts a new attempt normally.
         */
        mAuthCompleted.store(true, std::memory_order_release);
        onFingerUp();
    }

  private:
    fingerprint_device_t* mDevice;
    android::base::unique_fd disp_fd_;
    android::base::unique_fd touch_fd_;

    // Written by fingerprint callbacks and read by the display-event thread.
    std::atomic_bool mAuthCompleted{false};

    void setLocalHbm(int fd, uint32_t value) {
        struct disp_local_hbm_req displayLhbmRequest = {
                .base = displayBasePrimary,
                .local_hbm_value = value,
        };

        if (ioctl(fd, MI_DISP_IOCTL_SET_LOCAL_HBM, &displayLhbmRequest) < 0) {
            PLOG(ERROR) << "MI_DISP_IOCTL_SET_LOCAL_HBM failed, value=" << value;
        }
    }
};

static UdfpsHandler* create() {
    return new XiaomiSm8450UdfpsHandler();
}

static void destroy(UdfpsHandler* handler) {
    delete handler;
}

extern "C" UdfpsHandlerFactory UDFPS_HANDLER_FACTORY = {
        .create = create,
        .destroy = destroy,
};
