// SPDX-License-Identifier: AGPL-3.0-only

#include "RemotePlayBridge.h"

#include <chiaki/common.h>
#include <chiaki/controller.h>
#include <chiaki/discovery.h>
#include <chiaki/log.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/orientation.h>
#include <chiaki/regist.h>
#include <chiaki/session.h>

#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

// MARK: Common

static pthread_once_t vrp_once = PTHREAD_ONCE_INIT;
static ChiakiErrorCode vrp_init_result = CHIAKI_ERR_UNKNOWN;

static void vrp_init_impl(void) {
    vrp_init_result = chiaki_lib_init();
}

static ChiakiErrorCode vrp_init(void) {
    pthread_once(&vrp_once, vrp_init_impl);
    return vrp_init_result;
}

static void vrp_log_silent(ChiakiLogLevel level, const char *msg, void *user) {
    (void)level; (void)msg; (void)user;
}

static void vrp_copy(char *dst, size_t dst_size, const char *src) {
    if (dst_size == 0) return;
    if (!src) { dst[0] = '\0'; return; }
    strlcpy(dst, src, dst_size);
}

const char *vrp_error_string(int32_t code) {
    return chiaki_error_string((ChiakiErrorCode)code);
}

bool vrp_quit_is_error(int32_t reason) {
    return chiaki_quit_reason_is_error((ChiakiQuitReason)reason);
}

// MARK: Console discovery

typedef struct {
    VRPDiscoveryCallback callback;
    void *user;
} VRPDiscoveryContext;

static void vrp_discovery_cb(ChiakiDiscoveryHost *host, void *user) {
    VRPDiscoveryContext *context = user;
    if (!context->callback || !host->host_addr) return;
    VRPHost out;
    memset(&out, 0, sizeof(out));
    vrp_copy(out.address, sizeof(out.address), host->host_addr);
    vrp_copy(out.name, sizeof(out.name), host->host_name);
    vrp_copy(out.host_id, sizeof(out.host_id), host->host_id);
    vrp_copy(out.host_type, sizeof(out.host_type), host->host_type);
    vrp_copy(out.running_app, sizeof(out.running_app), host->running_app_name);
    out.state = host->state == CHIAKI_DISCOVERY_HOST_STATE_READY ? 1
        : host->state == CHIAKI_DISCOVERY_HOST_STATE_STANDBY ? 2 : 0;
    out.ps5 = chiaki_discovery_host_is_ps5(host);
    context->callback(&out, context->user);
}

static void vrp_discovery_send(ChiakiDiscovery *discovery, struct in_addr address) {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_addr = address;

    ChiakiDiscoveryPacket packet;
    memset(&packet, 0, sizeof(packet));
    packet.cmd = CHIAKI_DISCOVERY_CMD_SRCH;

    packet.protocol_version = CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS5;
    addr.sin_port = htons(CHIAKI_DISCOVERY_PORT_PS5);
    chiaki_discovery_send(discovery, &packet, (struct sockaddr *)&addr, sizeof(addr));

    packet.protocol_version = CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS4;
    addr.sin_port = htons(CHIAKI_DISCOVERY_PORT_PS4);
    chiaki_discovery_send(discovery, &packet, (struct sockaddr *)&addr, sizeof(addr));
}

int32_t vrp_discover(const char *target, int32_t duration_ms, VRPDiscoveryCallback callback, void *user) {
    ChiakiErrorCode err = vrp_init();
    if (err != CHIAKI_ERR_SUCCESS) return err;

    ChiakiLog log;
    chiaki_log_init(&log, CHIAKI_LOG_ERROR, vrp_log_silent, NULL);

    ChiakiDiscovery discovery;
    err = chiaki_discovery_init(&discovery, &log, AF_INET);
    if (err != CHIAKI_ERR_SUCCESS) return err;

    VRPDiscoveryContext context = { callback, user };
    ChiakiDiscoveryThread thread;
    err = chiaki_discovery_thread_start(&thread, &discovery, vrp_discovery_cb, &context);
    if (err != CHIAKI_ERR_SUCCESS) {
        chiaki_discovery_fini(&discovery);
        return err;
    }

    // Targets: the given address or the broadcast addresses of active interfaces.
    struct in_addr targets[16];
    int target_count = 0;
    if (target && target[0]) {
        struct addrinfo hints, *result = NULL;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_DGRAM;
        if (getaddrinfo(target, NULL, &hints, &result) == 0 && result) {
            targets[target_count++] = ((struct sockaddr_in *)result->ai_addr)->sin_addr;
        }
        if (result) freeaddrinfo(result);
    } else {
        targets[target_count++].s_addr = htonl(INADDR_BROADCAST);
        struct ifaddrs *interfaces = NULL;
        if (getifaddrs(&interfaces) == 0) {
            for (struct ifaddrs *i = interfaces; i && target_count < 16; i = i->ifa_next) {
                if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET) continue;
                if (!(i->ifa_flags & IFF_UP) || (i->ifa_flags & IFF_LOOPBACK) || !(i->ifa_flags & IFF_BROADCAST)) continue;
                if (!i->ifa_broadaddr) continue;
                targets[target_count++] = ((struct sockaddr_in *)i->ifa_broadaddr)->sin_addr;
            }
            freeifaddrs(interfaces);
        }
    }

    int elapsed = 0;
    while (elapsed < duration_ms && target_count > 0) {
        for (int i = 0; i < target_count; i++) {
            vrp_discovery_send(&discovery, targets[i]);
        }
        int step = duration_ms - elapsed < 500 ? duration_ms - elapsed : 500;
        usleep((useconds_t)step * 1000);
        elapsed += step;
    }

    chiaki_discovery_thread_stop(&thread);
    chiaki_discovery_fini(&discovery);
    return target_count > 0 ? CHIAKI_ERR_SUCCESS : CHIAKI_ERR_HOST_UNREACH;
}

int32_t vrp_wakeup(const char *host, const char *regist_key) {
    ChiakiErrorCode err = vrp_init();
    if (err != CHIAKI_ERR_SUCCESS) return err;
    // The registration key is zero-padded hex text; the console expects it as a number.
    char text[17];
    memcpy(text, regist_key, 16);
    text[16] = '\0';
    uint64_t credential = strtoull(text, NULL, 16);
    ChiakiLog log;
    chiaki_log_init(&log, CHIAKI_LOG_ERROR, vrp_log_silent, NULL);
    return chiaki_discovery_wakeup(&log, NULL, host, credential, true);
}

// MARK: Pairing

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    bool finished;
    bool success;
    VRPRegistration result;
} VRPRegistContext;

static void vrp_regist_cb(ChiakiRegistEvent *event, void *user) {
    VRPRegistContext *context = user;
    pthread_mutex_lock(&context->mutex);
    if (event->type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS && event->registered_host) {
        ChiakiRegisteredHost *host = event->registered_host;
        context->success = true;
        vrp_copy(context->result.nickname, sizeof(context->result.nickname), host->server_nickname);
        memcpy(context->result.mac, host->server_mac, sizeof(context->result.mac));
        memcpy(context->result.regist_key, host->rp_regist_key, sizeof(context->result.regist_key));
        memcpy(context->result.rp_key, host->rp_key, sizeof(context->result.rp_key));
        context->result.rp_key_type = host->rp_key_type;
    }
    context->finished = true;
    pthread_cond_signal(&context->cond);
    pthread_mutex_unlock(&context->mutex);
}

int32_t vrp_register(const char *host, const uint8_t *account_id, uint32_t pin, int32_t timeout_ms, VRPRegistration *out) {
    ChiakiErrorCode err = vrp_init();
    if (err != CHIAKI_ERR_SUCCESS) return 100 + err;

    ChiakiLog log;
    chiaki_log_init(&log, CHIAKI_LOG_ERROR, vrp_log_silent, NULL);

    ChiakiRegistInfo info;
    memset(&info, 0, sizeof(info));
    info.target = CHIAKI_TARGET_PS5_1;
    info.host = host;
    info.broadcast = false;
    info.psn_online_id = NULL;
    memcpy(info.psn_account_id, account_id, CHIAKI_PSN_ACCOUNT_ID_SIZE);
    info.pin = pin;

    VRPRegistContext context;
    memset(&context, 0, sizeof(context));
    pthread_mutex_init(&context.mutex, NULL);
    pthread_cond_init(&context.cond, NULL);

    ChiakiRegist regist;
    err = chiaki_regist_start(&regist, &log, &info, vrp_regist_cb, &context);
    if (err != CHIAKI_ERR_SUCCESS) {
        pthread_mutex_destroy(&context.mutex);
        pthread_cond_destroy(&context.cond);
        return 100 + err;
    }

    struct timeval now;
    gettimeofday(&now, NULL);
    struct timespec deadline;
    deadline.tv_sec = now.tv_sec + timeout_ms / 1000;
    deadline.tv_nsec = (now.tv_usec + (timeout_ms % 1000) * 1000L) * 1000L;
    deadline.tv_sec += deadline.tv_nsec / 1000000000L;
    deadline.tv_nsec %= 1000000000L;

    bool timed_out = false;
    pthread_mutex_lock(&context.mutex);
    while (!context.finished) {
        if (pthread_cond_timedwait(&context.cond, &context.mutex, &deadline) == ETIMEDOUT) {
            timed_out = !context.finished;
            break;
        }
    }
    pthread_mutex_unlock(&context.mutex);

    if (timed_out) chiaki_regist_stop(&regist);
    chiaki_regist_fini(&regist); // waits for the registration thread

    int32_t result = 1;
    pthread_mutex_lock(&context.mutex);
    if (context.success) {
        if (out) *out = context.result;
        result = 0;
    } else if (timed_out) {
        result = 2;
    }
    pthread_mutex_unlock(&context.mutex);
    // Keys must not be left on the stack.
    memset(&context.result, 0, sizeof(context.result));
    pthread_mutex_destroy(&context.mutex);
    pthread_cond_destroy(&context.cond);
    return result;
}

// MARK: Session

struct VRPSession {
    ChiakiSession session;
    ChiakiLog log;
    ChiakiOpusDecoder opus;
    VRPCallbacks callbacks;
    ChiakiControllerState controller;
    /// Controller orientation computed from the gyroscope and accelerometer (chiaki's Madgwick filter).
    ChiakiOrientationTracker orientation;
    ChiakiAccelNewZero accel_zero;
    int8_t touch_ids[2];
    pthread_mutex_t controller_mutex;
    uint32_t audio_channels;
    uint32_t audio_rate;
    char *host;
};

static void vrp_session_log(ChiakiLogLevel level, const char *msg, void *user) {
    VRPSession *session = user;
    if (session->callbacks.log) session->callbacks.log((int32_t)level, msg, session->callbacks.user);
}

/// chiaki's network receive thread (video and audio arrive from it) gets the highest interactive
/// priority — on a loaded Mac it doesn't wait for a core and doesn't drop packets.
static void vrp_raise_thread_priority(void) {
    static __thread bool raised = false;
    if (raised) return;
    raised = true;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
}

static bool vrp_session_video(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user) {
    VRPSession *session = user;
    vrp_raise_thread_priority();
    if (!session->callbacks.video) return true;
    return session->callbacks.video(buf, buf_size, frames_lost, frame_recovered, session->callbacks.user);
}

static void vrp_session_audio_settings(uint32_t channels, uint32_t rate, void *user) {
    VRPSession *session = user;
    session->audio_channels = channels;
    session->audio_rate = rate;
}

static void vrp_session_audio_frame(int16_t *buf, size_t samples_count, void *user) {
    VRPSession *session = user;
    vrp_raise_thread_priority();
    if (session->callbacks.audio && session->audio_channels > 0) {
        session->callbacks.audio(buf, samples_count, session->audio_channels, session->audio_rate, session->callbacks.user);
    }
}

static void vrp_session_event(ChiakiEvent *event, void *user) {
    VRPSession *session = user;
    if (!session->callbacks.event) return;
    void *u = session->callbacks.user;
    switch (event->type) {
        case CHIAKI_EVENT_CONNECTED:
            session->callbacks.event(VRP_EVENT_CONNECTED, 0, NULL, u);
            break;
        case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
            session->callbacks.event(VRP_EVENT_LOGIN_PIN, event->login_pin_request.pin_incorrect ? 1 : 0, NULL, u);
            break;
        case CHIAKI_EVENT_QUIT:
            session->callbacks.event(VRP_EVENT_QUIT, (int32_t)event->quit.reason,
                event->quit.reason_str ? event->quit.reason_str : chiaki_quit_reason_string(event->quit.reason), u);
            break;
        case CHIAKI_EVENT_RUMBLE:
            session->callbacks.event(VRP_EVENT_RUMBLE, ((int32_t)event->rumble.left << 8) | event->rumble.right, NULL, u);
            break;
        case CHIAKI_EVENT_LED_COLOR:
            session->callbacks.event(VRP_EVENT_LED_COLOR,
                ((int32_t)event->led_state[0] << 16) | ((int32_t)event->led_state[1] << 8) | event->led_state[2], NULL, u);
            break;
        case CHIAKI_EVENT_PLAYER_INDEX:
            session->callbacks.event(VRP_EVENT_PLAYER_INDEX, event->player_index, NULL, u);
            break;
        case CHIAKI_EVENT_TRIGGER_EFFECTS:
            if (session->callbacks.trigger_effects) {
                session->callbacks.trigger_effects(event->trigger_effects.type_left, event->trigger_effects.left,
                    event->trigger_effects.type_right, event->trigger_effects.right, u);
            }
            break;
        case CHIAKI_EVENT_NICKNAME_RECEIVED: {
            char name[sizeof(event->server_nickname) + 1];
            memcpy(name, event->server_nickname, sizeof(event->server_nickname));
            name[sizeof(event->server_nickname)] = '\0';
            session->callbacks.event(VRP_EVENT_NICKNAME, 0, name, u);
            break;
        }
        default:
            break;
    }
}

/// DualSense haptics arrive as 16-bit stereo PCM (3 kHz, 10 ms packets). We compute the mean
/// absolute amplitude of each side — the same way chiaki-ng converts haptics to rumble.
static void vrp_session_haptics_frame(uint8_t *buf, size_t buf_size, void *user) {
    VRPSession *session = user;
    vrp_raise_thread_priority();
    if (!session->callbacks.haptics || buf_size < 4 || buf_size % 4 != 0) return;
    size_t frames = buf_size / 4;
    uint64_t sum_left = 0, sum_right = 0;
    for (size_t i = 0; i < frames; i++) {
        int16_t left, right;
        memcpy(&left, buf + i * 4, 2);
        memcpy(&right, buf + i * 4 + 2, 2);
        sum_left += (uint64_t)(left < 0 ? -(int32_t)left : left);
        sum_right += (uint64_t)(right < 0 ? -(int32_t)right : right);
    }
    session->callbacks.haptics((float)sum_left / (float)frames / 32768.0f,
                               (float)sum_right / (float)frames / 32768.0f, session->callbacks.user);
}

VRPSession *vrp_session_start(const VRPConfig *config, const VRPCallbacks *callbacks, int32_t *error_out) {
    ChiakiErrorCode err = vrp_init();
    if (err != CHIAKI_ERR_SUCCESS) {
        if (error_out) *error_out = err;
        return NULL;
    }

    VRPSession *session = calloc(1, sizeof(VRPSession));
    if (!session) {
        if (error_out) *error_out = CHIAKI_ERR_MEMORY;
        return NULL;
    }
    session->callbacks = *callbacks;
    session->host = strdup(config->host);
    session->touch_ids[0] = -1;
    session->touch_ids[1] = -1;
    pthread_mutex_init(&session->controller_mutex, NULL);
    chiaki_controller_state_set_idle(&session->controller);
    chiaki_orientation_tracker_init(&session->orientation);
    chiaki_accel_new_zero_set_inactive(&session->accel_zero, false);

    // Verbose levels may contain session data, so by default only errors and warnings pass through.
    uint32_t mask = CHIAKI_LOG_ERROR | CHIAKI_LOG_WARNING;
    if (config->verbose_log) mask |= CHIAKI_LOG_INFO;
    chiaki_log_init(&session->log, mask, vrp_session_log, session);

    ChiakiConnectInfo info;
    memset(&info, 0, sizeof(info));
    info.ps5 = true;
    info.host = session->host;
    memcpy(info.regist_key, config->regist_key, sizeof(info.regist_key));
    memcpy(info.morning, config->rp_key, sizeof(info.morning));
    memcpy(info.psn_account_id, config->account_id, sizeof(info.psn_account_id));

    ChiakiVideoResolutionPreset resolution = CHIAKI_VIDEO_RESOLUTION_PRESET_1080p;
    if (config->height <= 360) resolution = CHIAKI_VIDEO_RESOLUTION_PRESET_360p;
    else if (config->height <= 540) resolution = CHIAKI_VIDEO_RESOLUTION_PRESET_540p;
    else if (config->height <= 720) resolution = CHIAKI_VIDEO_RESOLUTION_PRESET_720p;
    chiaki_connect_video_profile_preset(&info.video_profile, resolution,
        config->fps <= 30 ? CHIAKI_VIDEO_FPS_PRESET_30 : CHIAKI_VIDEO_FPS_PRESET_60);
    if (config->bitrate_kbps > 0) info.video_profile.bitrate = (unsigned int)config->bitrate_kbps;
    info.video_profile.codec = config->codec == VRP_CODEC_H265 ? CHIAKI_CODEC_H265 : CHIAKI_CODEC_H264;
    info.video_profile_auto_downgrade = true;
    info.enable_keyboard = false;
    info.enable_dualsense = config->dualsense;
    info.auto_regist = false;
    info.packet_loss_max = 0.05;
    // As chiaki-ng does by default: after packet loss the frame references an older reference frame
    // and the picture keeps going. Requesting a keyframe would freeze the picture for 100–300 ms.
    info.enable_idr_on_fec_failure = false;

    err = chiaki_session_init(&session->session, &info, &session->log);
    memset(&info, 0, sizeof(info));
    if (err != CHIAKI_ERR_SUCCESS) {
        if (error_out) *error_out = err;
        pthread_mutex_destroy(&session->controller_mutex);
        free(session->host);
        free(session);
        return NULL;
    }

    chiaki_opus_decoder_init(&session->opus, &session->log);
    chiaki_opus_decoder_set_cb(&session->opus, vrp_session_audio_settings, vrp_session_audio_frame, session);
    ChiakiAudioSink sink;
    chiaki_opus_decoder_get_sink(&session->opus, &sink);
    chiaki_session_set_audio_sink(&session->session, &sink);
    if (config->dualsense) {
        ChiakiAudioSink haptics;
        memset(&haptics, 0, sizeof(haptics));
        haptics.user = session;
        haptics.frame_cb = vrp_session_haptics_frame;
        chiaki_session_set_haptics_sink(&session->session, &haptics);
    }
    chiaki_session_set_video_sample_cb(&session->session, vrp_session_video, session);
    chiaki_session_set_event_cb(&session->session, vrp_session_event, session);

    err = chiaki_session_start(&session->session);
    if (err != CHIAKI_ERR_SUCCESS) {
        if (error_out) *error_out = err;
        chiaki_session_fini(&session->session);
        chiaki_opus_decoder_fini(&session->opus);
        pthread_mutex_destroy(&session->controller_mutex);
        free(session->host);
        free(session);
        return NULL;
    }
    if (error_out) *error_out = CHIAKI_ERR_SUCCESS;
    return session;
}

static uint16_t vrp_touch_coordinate(float value, float max) {
    if (value < 0) value = 0;
    if (value > 1) value = 1;
    return (uint16_t)(value * max);
}

void vrp_session_set_controller(VRPSession *session, const VRPController *controller) {
    if (!session || !controller) return;
    pthread_mutex_lock(&session->controller_mutex);
    ChiakiControllerState *state = &session->controller;
    state->buttons = controller->buttons;
    state->l2_state = controller->l2;
    state->r2_state = controller->r2;
    state->left_x = controller->left_x;
    state->left_y = controller->left_y;
    state->right_x = controller->right_x;
    state->right_y = controller->right_y;
    for (int i = 0; i < 2; i++) {
        // The DualSense touchpad in the PS5 protocol has a range of 1919 × 1079.
        uint16_t x = vrp_touch_coordinate(controller->touch[i].x, 1919.0f);
        uint16_t y = vrp_touch_coordinate(controller->touch[i].y, 1079.0f);
        if (controller->touch[i].active) {
            if (session->touch_ids[i] < 0) {
                session->touch_ids[i] = chiaki_controller_state_start_touch(state, x, y);
            } else {
                chiaki_controller_state_set_touch_pos(state, (uint8_t)session->touch_ids[i], x, y);
            }
        } else if (session->touch_ids[i] >= 0) {
            chiaki_controller_state_stop_touch(state, (uint8_t)session->touch_ids[i]);
            session->touch_ids[i] = -1;
        }
    }
    if (controller->motion) {
        // Readings are already in SDL axes and without zero offset — as in chiaki-ng after a gyro event.
        chiaki_orientation_tracker_update(&session->orientation,
                                          controller->gyro[0], controller->gyro[1], controller->gyro[2],
                                          controller->accel[0], controller->accel[1], controller->accel[2],
                                          &session->accel_zero, true, controller->motion_timestamp_us);
        chiaki_orientation_tracker_apply_to_controller_state(&session->orientation, state);
    }
    chiaki_session_set_controller_state(&session->session, state);
    pthread_mutex_unlock(&session->controller_mutex);
}

void vrp_session_set_login_pin(VRPSession *session, const char *pin) {
    if (!session || !pin) return;
    chiaki_session_set_login_pin(&session->session, (const uint8_t *)pin, strlen(pin));
}

void vrp_session_request_keyframe(VRPSession *session) {
    if (session) chiaki_session_request_idr(&session->session);
}

void vrp_session_stop(VRPSession *session) {
    if (!session) return;
    chiaki_session_stop(&session->session);
    chiaki_session_join(&session->session);
    chiaki_session_fini(&session->session);
    chiaki_opus_decoder_fini(&session->opus);
    pthread_mutex_destroy(&session->controller_mutex);
    free(session->host);
    memset(session, 0, sizeof(*session));
    free(session);
}
