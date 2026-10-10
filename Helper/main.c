// tr256e-helper: root daemon that pulls H.264 off the Mileseey TR256E's bulk UVC
// endpoint and serves it to the camera extension over 127.0.0.1.
//
// The camera sends H.264 no matter which UVC format the host negotiates, so
// macOS's own UVC driver stalls after ~2s. Taking the interface away from it
// needs root, which is why this lives in a daemon instead of the extension.
//
// Protocol: for each video frame, a 4-byte big-endian length followed by the
// Annex-B access unit. Output starts at the first SPS so the decoder can start
// cleanly. The camera is only claimed while a client is connected: on macOS,
// libusb's detach captures the whole device, which also unmounts the camera's
// storage, so holding it all the time would hide the photos.

#include <arpa/inet.h>
#include <errno.h>
#include <libusb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define CAM_VID 0x1d6b
#define CAM_PID 0x1110
#define VS_IFACE 1
#define EP_IN 0x81
#define H264_FORMAT_INDEX 2
#define FRAME_INTERVAL 400000 // 100ns units -> 25 fps
#define PORT 47256

static libusb_context *ctx;
static libusb_device_handle *cam;  // claimed while a client is connected

static void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *fmt, ...) {
    char ts[32];
    time_t now = time(NULL);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&now));
    fprintf(stderr, "%s ", ts);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static int send_all(int fd, const uint8_t *p, size_t n) {
    while (n) {
        ssize_t w = send(fd, p, n, 0);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return -1;
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

static int send_frame(int fd, const uint8_t *p, size_t n) {
    uint8_t hdr[4] = {(uint8_t)(n >> 24), (uint8_t)(n >> 16), (uint8_t)(n >> 8), (uint8_t)n};
    return (send_all(fd, hdr, 4) || send_all(fd, p, n)) ? -1 : 0;
}

static int client_gone(int fd) {
    char c;
    ssize_t r = recv(fd, &c, 1, MSG_PEEK | MSG_DONTWAIT);
    return r == 0 || (r < 0 && errno != EAGAIN && errno != EWOULDBLOCK);
}

static const uint8_t *find_sps(const uint8_t *p, size_t n) {
    for (size_t i = 0; i + 4 < n; i++)
        if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 0 && p[i + 3] == 1 && (p[i + 4] & 0x1f) == 7)
            return p + i;
    return NULL;
}

static libusb_device_handle *open_camera(void) {
    static int last_err;
    libusb_device_handle *h = libusb_open_device_with_vid_pid(ctx, CAM_VID, CAM_PID);
    if (!h) return NULL;
    if (libusb_kernel_driver_active(h, VS_IFACE) == 1) {
        int r = libusb_detach_kernel_driver(h, VS_IFACE);
        if (r && r != last_err) logf_("detach: %s", libusb_strerror(r));
    }
    int r = libusb_claim_interface(h, VS_IFACE);
    if (r) {
        if (r != last_err) logf_("claim: %s", libusb_strerror(r));
        last_err = r;
        libusb_close(h);
        return NULL;
    }
    last_err = 0;
    return h;
}

static void drop_camera(void) {
    libusb_release_interface(cam, VS_IFACE);
    libusb_close(cam);
    cam = NULL;
}

// Claims the camera if it is plugged in, forgets it if it has been unplugged.
static void ensure_camera(void) {
    int config;
    if (cam && libusb_get_configuration(cam, &config) != 0) {
        logf_("camera unplugged");
        drop_camera();
    }
    if (!cam && (cam = open_camera())) logf_("camera claimed");
}

// UVC 1.0 probe/commit (26 bytes): bmHint, bFormatIndex, bFrameIndex, dwFrameInterval...
static int start_stream(libusb_device_handle *h, uint32_t *max_payload) {
    uint8_t p[26];
    int r = libusb_control_transfer(h, 0xA1, 0x81, 1 << 8, VS_IFACE, p, sizeof p, 1000);
    if (r < 0) return r;
    p[0] = 1;
    p[1] = 0;
    p[2] = H264_FORMAT_INDEX;
    p[3] = 1;
    p[4] = FRAME_INTERVAL & 0xff;
    p[5] = (FRAME_INTERVAL >> 8) & 0xff;
    p[6] = (FRAME_INTERVAL >> 16) & 0xff;
    p[7] = (FRAME_INTERVAL >> 24) & 0xff;
    if ((r = libusb_control_transfer(h, 0x21, 0x01, 1 << 8, VS_IFACE, p, sizeof p, 1000)) < 0) return r;
    if ((r = libusb_control_transfer(h, 0xA1, 0x81, 1 << 8, VS_IFACE, p, sizeof p, 1000)) < 0) return r;
    *max_payload = (uint32_t)p[22] | (uint32_t)p[23] << 8 | (uint32_t)p[24] << 16 | (uint32_t)p[25] << 24;
    if ((r = libusb_control_transfer(h, 0x21, 0x01, 2 << 8, VS_IFACE, p, sizeof p, 1000)) < 0) return r;
    return 0;
}

typedef enum { STREAM_CLIENT_GONE, STREAM_DEVICE_ERROR } stream_result;

typedef struct {
    uint8_t *data;
    size_t len, cap;
    int started;
    unsigned long frames;
} frame_buf;

static void append(frame_buf *f, const uint8_t *p, size_t n) {
    if (f->len + n > f->cap) f->data = realloc(f->data, f->cap = (f->len + n) * 2);
    memcpy(f->data + f->len, p, n);
    f->len += n;
}

// Send the assembled frame (skipping everything before the first SPS). -1 if the client is gone.
static int emit(int fd, frame_buf *f) {
    const uint8_t *start = f->data;
    if (!f->started && (start = find_sps(f->data, f->len))) f->started = 1;
    int r = 0;
    if (f->started && start) {
        r = send_frame(fd, start, f->len - (size_t)(start - f->data));
        if (++f->frames % 250 == 0) logf_("%lu frames", f->frames);
    }
    f->len = 0;
    return r;
}

static stream_result stream_to(int fd, libusb_device_handle *h) {
    uint32_t max_payload = 0;
    int r = start_stream(h, &max_payload);
    if (r) {
        logf_("probe/commit: %s", libusb_strerror(r));
        return STREAM_DEVICE_ERROR;
    }
    int bufsz = max_payload > 16384 ? (int)max_payload : 16384;
    uint8_t *buf = malloc((size_t)bufsz);
    frame_buf f = {.data = malloc(1 << 19), .cap = 1 << 19};
    int last_fid = -1, timeouts = 0;
    stream_result result = STREAM_DEVICE_ERROR;
    logf_("streaming (max payload %u)", max_payload);

    for (;;) {
        int got = 0;
        r = libusb_bulk_transfer(h, EP_IN, buf, bufsz, &got, 1000);
        if (r == LIBUSB_ERROR_TIMEOUT) {
            if (client_gone(fd)) { result = STREAM_CLIENT_GONE; break; }
            if (++timeouts == 3) {
                logf_("no data for 3s; restarting stream");
                break;
            }
            continue;
        }
        if (r) {
            logf_("bulk read: %s", libusb_strerror(r));
            break;
        }
        timeouts = 0;
        // Each bulk payload starts with a UVC header: bHeaderLength, bmHeaderInfo (FID bit 0, EOF bit 1).
        if (got < 2 || buf[0] > got) continue;
        int fid = buf[1] & 1, eof = buf[1] & 2;
        if (last_fid >= 0 && fid != last_fid && f.len && emit(fd, &f)) { result = STREAM_CLIENT_GONE; break; }
        append(&f, buf + buf[0], (size_t)(got - buf[0]));
        last_fid = fid;
        if (eof && emit(fd, &f)) { result = STREAM_CLIENT_GONE; break; }
    }
    logf_("stream stopped after %lu frames", f.frames);
    free(buf);
    free(f.data);
    return result;
}

static void serve(int fd) {
    int failures = 0;
    for (;;) {
        ensure_camera();
        if (!cam) {
            if (client_gone(fd)) return;
            usleep(500000);
            continue;
        }
        stream_result r = stream_to(fd, cam);
        libusb_clear_halt(cam, EP_IN);  // stops a bulk UVC stream
        if (r == STREAM_CLIENT_GONE || client_gone(fd)) {
            drop_camera();
            return;
        }
        // The first commit after a stop sometimes fails once; retry quickly, then reopen.
        if (++failures % 3 == 0) drop_camera();
        usleep(200000);
    }
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    setvbuf(stderr, NULL, _IOLBF, 0);
    int r = libusb_init(&ctx);
    if (r) {
        logf_("libusb_init: %s", libusb_strerror(r));
        return 1;
    }

    int ls = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons(PORT)};
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(ls, (struct sockaddr *)&addr, sizeof addr) || listen(ls, 4)) {
        logf_("bind/listen 127.0.0.1:%d: %s", PORT, strerror(errno));
        return 1;
    }
    logf_("listening on 127.0.0.1:%d", PORT);

    for (;;) {
        int fd = accept(ls, NULL, NULL);
        if (fd < 0) {
            if (errno != EINTR) logf_("accept: %s", strerror(errno));
            continue;
        }
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        logf_("client connected");
        serve(fd);
        close(fd);
        logf_("client disconnected");
    }
}
