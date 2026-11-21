// SPDX-License-Identifier: AGPL-3.0-only
//
// Thin C bridge over the chiaki-ng library (PS Remote Play protocol). Swift sees only this header —
// chiaki's large structs and unions stay on the C side.

#ifndef VEYRA_RP_H
#define VEYRA_RP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: Console discovery

typedef struct VRPHost {
    char address[64];
    char name[64];
    char host_id[32];
    char host_type[16];
    char running_app[64];
    /// 0 = unknown, 1 = on, 2 = rest mode
    int32_t state;
    bool ps5;
} VRPHost;

typedef void (*VRPDiscoveryCallback)(const VRPHost *host, void *user);

/// Looks for consoles on the local network for `duration_ms` (blocks the thread). `target` is the console's IP address
/// or NULL — then the query goes to the broadcast addresses of all interfaces.
/// The same console may be reported multiple times. Returns 0 or a chiaki error code.
int32_t vrp_discover(const char *target, int32_t duration_ms, VRPDiscoveryCallback callback, void *user);

/// Wakes the console from rest mode. `regist_key` is the 16 bytes from pairing.
int32_t vrp_wakeup(const char *host, const char *regist_key);

// MARK: Pairing

typedef struct VRPRegistration {
    char nickname[32];
    uint8_t mac[6];
    char regist_key[16];
    uint8_t rp_key[16];
    uint32_t rp_key_type;
} VRPRegistration;

/// Pairs the Mac with a PS5 (blocks the thread). `pin` is the eight-digit PIN from the console screen.
/// Returns: 0 = success, 1 = rejected by the console, 2 = timed out, other = start error.
int32_t vrp_register(const char *host, const uint8_t *account_id, uint32_t pin, int32_t timeout_ms, VRPRegistration *out);

// MARK: Session

enum {
    VRP_BUTTON_CROSS = 1 << 0,
    VRP_BUTTON_CIRCLE = 1 << 1,
    VRP_BUTTON_SQUARE = 1 << 2,
    VRP_BUTTON_TRIANGLE = 1 << 3,
    VRP_BUTTON_DPAD_LEFT = 1 << 4,
    VRP_BUTTON_DPAD_RIGHT = 1 << 5,
    VRP_BUTTON_DPAD_UP = 1 << 6,
    VRP_BUTTON_DPAD_DOWN = 1 << 7,
    VRP_BUTTON_L1 = 1 << 8,
    VRP_BUTTON_R1 = 1 << 9,
    VRP_BUTTON_L3 = 1 << 10,
    VRP_BUTTON_R3 = 1 << 11,
    VRP_BUTTON_OPTIONS = 1 << 12,
    VRP_BUTTON_SHARE = 1 << 13,
    VRP_BUTTON_TOUCHPAD = 1 << 14,
    VRP_BUTTON_PS = 1 << 15,
};

typedef struct VRPTouch {
    bool active;
    /// Normalized position 0…1, origin at the touchpad's top-left corner.
    float x;
    float y;
} VRPTouch;

typedef struct VRPController {
    uint32_t buttons;
    uint8_t l2;
    uint8_t r2;
    int16_t left_x;
    int16_t left_y;
    int16_t right_x;
    int16_t right_y;
    VRPTouch touch[2];
    /// Motion sensors in the SDL convention (the one chiaki-ng uses): X right, Y up, Z toward
    /// the player; gyro in rad/s, accelerometer in g. `motion` = the controller provides motion data.
    bool motion;
    float gyro[3];
    float accel[3];
    uint32_t motion_timestamp_us;
} VRPController;

enum {
    VRP_EVENT_CONNECTED = 0,
    /// code = 1 when the previous PIN was wrong
    VRP_EVENT_LOGIN_PIN = 1,
    /// code = reason (ChiakiQuitReason), text = description; code_is_error in `vrp_quit_is_error`
    VRP_EVENT_QUIT = 2,
    /// code = (left << 8) | right, strength 0…255
    VRP_EVENT_RUMBLE = 3,
    /// text = console name
    VRP_EVENT_NICKNAME = 4,
    /// code = (red << 16) | (green << 8) | blue — controller light bar color
    VRP_EVENT_LED_COLOR = 5,
    /// code = player number (1…4)
    VRP_EVENT_PLAYER_INDEX = 6,
};

enum {
    VRP_CODEC_H264 = 0,
    VRP_CODEC_H265 = 1,
};

typedef struct VRPCallbacks {
    void *user;
    /// Annex B video sample: first the header (SPS/PPS/VPS), then subsequent frames. Called from a chiaki thread.
    /// Returning `false` reports a corrupted frame to the console (the console will send a keyframe).
    bool (*video)(const uint8_t *data, size_t size, int32_t frames_lost, bool recovered, void *user);
    /// Interleaved 16-bit PCM; `frames` is the number of samples per channel.
    void (*audio)(const int16_t *samples, size_t frames, uint32_t channels, uint32_t rate, void *user);
    void (*event)(int32_t type, int32_t code, const char *text, void *user);
    /// DualSense haptics (DualSense mode only): average vibration strength of the left and right side
    /// in a 10 ms packet, 0…1.
    void (*haptics)(float left, float right, void *user);
    /// Adaptive trigger effects: effect type and 10 parameter bytes (DualSense controller format).
    void (*trigger_effects)(uint8_t type_left, const uint8_t *left, uint8_t type_right, const uint8_t *right, void *user);
    /// level: 1 = error, 2 = warning, 4 = info
    void (*log)(int32_t level, const char *message, void *user);
} VRPCallbacks;

typedef struct VRPConfig {
    const char *host;
    char regist_key[16];
    uint8_t rp_key[16];
    uint8_t account_id[8];
    /// 1080, 720, 540 or 360
    int32_t height;
    /// 30 or 60
    int32_t fps;
    /// 0 = default for the resolution
    int32_t bitrate_kbps;
    int32_t codec;
    /// The console sees a DualSense controller: it sends haptics, trigger effects and the light bar color.
    /// Off = DualShock 4 mode (simple rumble only).
    bool dualsense;
    bool verbose_log;
} VRPConfig;

typedef struct VRPSession VRPSession;

/// Creates and starts a session. Returns NULL on error (code in `error_out`).
VRPSession *vrp_session_start(const VRPConfig *config, const VRPCallbacks *callbacks, int32_t *error_out);
void vrp_session_set_controller(VRPSession *session, const VRPController *controller);
/// Account login PIN on the console (if the console asks for it).
void vrp_session_set_login_pin(VRPSession *session, const char *pin);
void vrp_session_request_keyframe(VRPSession *session);
/// Stops the session, waits for its threads and frees memory (blocking). No callbacks arrive after this call.
void vrp_session_stop(VRPSession *session);

bool vrp_quit_is_error(int32_t reason);
const char *vrp_error_string(int32_t code);

#ifdef __cplusplus
}
#endif

#endif
