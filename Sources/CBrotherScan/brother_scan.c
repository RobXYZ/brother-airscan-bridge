#include "brother_scan.h"

#include <errno.h>
#include <netdb.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

// Every command is ESC + letter + '\n', then "KEY=value\n" lines, then 0x80.
#define CMD_END 0x80

// Stream records start with a type byte.
//   < 0x80        image data: record header, LE u16 length, payload
//                 0x64 / 0x60 = JPEG bytes; 0x42 family = one PackBits-compressed row;
//                 anything else = uncompressed rows
//   0x80          end of job (bare byte)
//   0x82          end of page (record header, no payload)
//   0x83          job terminated (bare byte)
//   0x86          cancel acknowledged (bare byte)
//   0x87          page geometry info (record header, LE u16 length, payload)
//   anything else a bare device status byte
#define REC_JOB_END      0x80
#define REC_PAGE_END     0x82
#define REC_TERMINATED   0x83
#define REC_CANCELLED    0x86
#define REC_PAGE_INFO    0x87
#define REC_DATA_JPEG_1  0x60
#define REC_DATA_JPEG    0x64
#define REC_IS_PACKED(t) (((t) & ~0x1c) == 0x42)

// Largest row we will unpack: far more than the widest scan at 1 bit or 8 bits per pixel.
#define MAX_ROW_BYTES    (64 * 1024)

// Reply to the "is a document loaded" query when the answer is yes.
#define ST_READY         0x80

#define CONNECT_TIMEOUT_S 8
#define REPLY_TIMEOUT_S   10
#define SCAN_TIMEOUT_S    60

struct bs_session {
    int      fd;
    FILE    *trace;
    bs_mode  mode;
    uint8_t  in[16384];
    size_t   in_pos, in_len;
    uint8_t *payload;
    size_t   payload_cap;
    uint8_t *row;               // one unpacked row, MAX_ROW_BYTES long, allocated on first use
    volatile int cancel_requested;
};

static void trace(bs_session *s, const char *fmt, ...) {
    if (!s->trace) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(s->trace, fmt, ap);
    va_end(ap);
    fputc('\n', s->trace);
    fflush(s->trace);
}

static void set_timeout(int fd, int seconds) {
    struct timeval tv = { .tv_sec = seconds, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
}

static bool send_all(bs_session *s, const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len > 0) {
        ssize_t n = send(s->fd, p, len, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += n;
        len -= (size_t)n;
    }
    return true;
}

static bool fill(bs_session *s) {
    for (;;) {
        ssize_t n = recv(s->fd, s->in, sizeof s->in, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        s->in_pos = 0;
        s->in_len = (size_t)n;
        return true;
    }
}

static bool read_exact(bs_session *s, uint8_t *dst, size_t len) {
    while (len > 0) {
        if (s->in_pos == s->in_len && !fill(s)) return false;
        size_t take = s->in_len - s->in_pos;
        if (take > len) take = len;
        memcpy(dst, s->in + s->in_pos, take);
        s->in_pos += take;
        dst += take;
        len -= take;
    }
    return true;
}

static bool send_command(bs_session *s, char letter, const char *body) {
    char   buf[512];
    int    n = snprintf(buf, sizeof buf - 1, "\x1b%c\n%s", letter, body ? body : "");
    if (n < 0 || n >= (int)sizeof buf - 1) return false;
    trace(s, "> ESC %c %s", letter, body ? body : "");
    buf[n++] = (char)CMD_END;
    return send_all(s, buf, (size_t)n);
}

// Replies to query commands are: status byte, LE u16 length, then that many bytes.
static bs_status read_reply(bs_session *s, char *out, size_t cap) {
    uint8_t head[3];
    if (!read_exact(s, head, 3)) return BS_ERR_IO;
    size_t len = head[1] | (size_t)head[2] << 8;
    if (len >= cap) return BS_ERR_PROTOCOL;
    if (!read_exact(s, (uint8_t *)out, len)) return BS_ERR_IO;
    out[len] = 0;
    trace(s, "< status %02x \"%s\"", head[0], out);
    return head[0] == 0 ? BS_OK : BS_ERR_DEVICE;
}

// Grouping follows the messages Brother's own driver shows for each code.
static bs_status status_from_byte(uint8_t b) {
    switch (b) {
        case 0xC2: case 0xEE:
            return BS_ERR_NO_PAPER;
        case 0xC3: case 0xC8: case 0xD2: case 0xD3: case 0xEA: case 0xEF:
            return BS_ERR_JAM;
        case 0xC5: case 0xD4:
            return BS_ERR_BUSY;
        case 0xCA:
            return BS_ERR_COVER_OPEN;
        case REC_TERMINATED: case REC_CANCELLED:
            return BS_ERR_CANCELLED;
        default:
            return BS_ERR_DEVICE;
    }
}

bs_status bs_open(const char *host, int port, bs_session **out) {
    *out = NULL;
    char service[16];
    snprintf(service, sizeof service, "%d", port > 0 ? port : BS_DEFAULT_PORT);

    // Ask for IPv4 first. A scanner's .local name may also resolve over IPv6, which it doesn't
    // serve scans on, and merely asking for both makes the lookup wait seconds for the IPv6
    // answer.
    static const int families[] = { AF_INET, AF_INET6 };
    int fd = -1, why = EHOSTUNREACH;
    for (size_t f = 0; f < 2 && fd < 0; f++) {
        struct addrinfo hints = { .ai_family = families[f], .ai_socktype = SOCK_STREAM };
        struct addrinfo *res = NULL;
        if (getaddrinfo(host, service, &hints, &res) != 0) continue;
        for (struct addrinfo *ai = res; ai && fd < 0; ai = ai->ai_next) {
            fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
            if (fd < 0) continue;
            set_timeout(fd, CONNECT_TIMEOUT_S);
            if (connect(fd, ai->ai_addr, ai->ai_addrlen) != 0) {
                why = errno;
                close(fd);
                fd = -1;
            }
        }
        freeaddrinfo(res);
    }
    if (fd < 0) { errno = why; return BS_ERR_CONNECT; }

    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    set_timeout(fd, REPLY_TIMEOUT_S);

    bs_session *s = calloc(1, sizeof *s);
    if (!s) { close(fd); return BS_ERR_IO; }
    s->fd = fd;

    // Greeting is "+OK 200\r\n"; anything else ("-NG 401" etc.) means the scanner is busy.
    char greeting[16] = {0};
    size_t n = 0;
    while (n < sizeof greeting - 1) {
        if (!read_exact(s, (uint8_t *)greeting + n, 1)) { bs_close(s); return BS_ERR_IO; }
        if (greeting[n++] == '\n') break;
    }
    if (strncmp(greeting, "+OK", 3) != 0) { bs_close(s); return BS_ERR_BUSY; }

    *out = s;
    return BS_OK;
}

void bs_close(bs_session *s) {
    if (!s) return;
    if (s->fd >= 0) close(s->fd);
    free(s->payload);
    free(s->row);
    free(s);
}

void bs_set_trace(bs_session *s, void *file) { s->trace = file; }

static const char *mode_keyword(bs_mode m) {
    switch (m) {
        case BS_MODE_BW:   return "TEXT";
        case BS_MODE_GRAY: return "GRAY64";
        default:           return "CGRAY";
    }
}

bs_status bs_document_loaded(bs_session *s) {
    if (!send_all(s, "\x1b" "D\nADF\n\x80", 8)) return BS_ERR_IO;
    uint8_t ready;
    if (!read_exact(s, &ready, 1)) return BS_ERR_IO;
    trace(s, "< document check %02x", ready);
    return ready == ST_READY ? BS_OK : status_from_byte(ready);
}

bs_status bs_start(bs_session *s, const bs_params *p, bs_scan_info *info) {
    char body[256], reply[128];
    const char *mode   = mode_keyword(p->mode);
    const char *duplex = p->duplex ? "DUP" : "SIN";

    // An empty feeder then fails immediately instead of after the scanner's own ~15 s wait.
    bs_status loaded = bs_document_loaded(s);
    if (loaded != BS_OK) return loaded;

    // "I" asks what the scanner can do at this resolution. Reply:
    //   xdpi,ydpi,source,width_mm,width_px,height_mm,height_px
    snprintf(body, sizeof body, "R=%d,%d\nM=%s\nD=%s\n", p->dpi, p->dpi, mode, duplex);
    if (!send_command(s, 'I', body)) return BS_ERR_IO;
    bs_status st = read_reply(s, reply, sizeof reply);
    if (st != BS_OK) return st;

    int dx, dy, source, wmm, wpx, hmm, hpx;
    if (sscanf(reply, "%d,%d,%d,%d,%d,%d,%d", &dx, &dy, &source, &wmm, &wpx, &hmm, &hpx) != 7)
        return BS_ERR_PROTOCOL;

    int left   = p->left > 0 ? p->left : 0;
    int top    = p->top > 0 ? p->top : 0;
    int width  = p->width > 0 ? p->width : wpx;
    int height = p->height > 0 ? p->height : (int)(dy * 11.693 + 0.5);
    if (left >= wpx) left = 0;
    if (left + width > wpx) width = wpx - left;

    // Colour comes as JPEG. The scanner refuses JPEG for the other modes, so those use its
    // run-length coding instead: a tenth of the data of uncompressed rows, and lossless.
    const bool jpeg = p->mode == BS_MODE_COLOR;
    if (jpeg) {
        // The scanner's JPEG encoder corrupts the right-hand edge unless the width is a whole
        // number of 16-pixel blocks. Scan slightly wide where there is room; callers crop.
        int wide = (width + 15) & ~15;
        width = left + wide <= wpx ? wide : width & ~15;
    } else if (p->mode == BS_MODE_BW) {
        width &= ~7;   // packed rows must be whole bytes
    }
    snprintf(body, sizeof body,
             "B=50\nN=50\nM=%s\n%sR=%d,%d\nA=%d,%d,%d,%d\nD=%s\nP=0\nE=1\n",
             mode, jpeg ? "C=JPEG\nJ=MID\n" : "C=RLENGTH\n",
             dx, dy, left, top, left + width, top + height, duplex);
    if (!send_command(s, 'X', body)) return BS_ERR_IO;

    set_timeout(s->fd, SCAN_TIMEOUT_S);
    s->mode = p->mode;
    s->cancel_requested = 0;

    if (info) {
        info->dpi_x = dx;
        info->dpi_y = dy;
        info->width = width;
        info->height = height;
        info->max_width = wpx;
    }
    return BS_OK;
}

// PackBits: a control byte n, then either n+1 literal bytes (n < 128) or one byte to repeat
// 257-n times (n > 128). Returns false if the data is malformed or the row is absurdly long.
static bool unpack_row(const uint8_t *in, size_t in_len, uint8_t *out, size_t *out_len) {
    size_t i = 0, o = 0;
    while (i < in_len) {
        uint8_t n = in[i++];
        if (n < 128) {
            size_t count = (size_t)n + 1;
            if (i + count > in_len || o + count > MAX_ROW_BYTES) return false;
            memcpy(out + o, in + i, count);
            i += count;
            o += count;
        } else if (n > 128) {
            size_t count = 257 - (size_t)n;
            if (i >= in_len || o + count > MAX_ROW_BYTES) return false;
            memset(out + o, in[i++], count);
            o += count;
        }
    }
    *out_len = o;
    return true;
}

static bool read_u16(bs_session *s, size_t *out) {
    uint8_t b[2];
    if (!read_exact(s, b, 2)) return false;
    *out = b[0] | (size_t)b[1] << 8;
    return true;
}

bs_status bs_next(bs_session *s, bs_event *ev) {
    for (;;) {
        memset(ev, 0, sizeof *ev);

        uint8_t type;
        if (!read_exact(s, &type, 1))
            return s->cancel_requested ? BS_ERR_CANCELLED : BS_ERR_IO;

        if (type == REC_JOB_END) {
            trace(s, "< job end");
            ev->type = BS_EV_JOB_END;
            return BS_OK;
        }
        if (type > REC_JOB_END && type != REC_PAGE_END && type != REC_PAGE_INFO) {
            trace(s, "< status %02x", type);
            return s->cancel_requested ? BS_ERR_CANCELLED : status_from_byte(type);
        }

        // Record header: u16 page, u8 flags, then four bytes we don't need.
        uint8_t header[64];
        size_t  hlen, len = 0;
        if (!read_u16(s, &hlen)) return BS_ERR_IO;
        if (hlen < 2 || hlen > sizeof header) return BS_ERR_PROTOCOL;
        if (!read_exact(s, header, hlen)) return BS_ERR_IO;
        ev->page = header[0] | header[1] << 8;

        if (type == REC_PAGE_END) {
            trace(s, "< page %d end", ev->page);
            ev->type = BS_EV_PAGE_END;
            return BS_OK;
        }

        if (!read_u16(s, &len)) return BS_ERR_IO;
        if (len > s->payload_cap) {
            uint8_t *grown = realloc(s->payload, len);
            if (!grown) return BS_ERR_IO;
            s->payload = grown;
            s->payload_cap = len;
        }
        if (!read_exact(s, s->payload, len)) return BS_ERR_IO;
        if (type == REC_PAGE_INFO) continue;

        const bool jpeg = type == REC_DATA_JPEG || type == REC_DATA_JPEG_1;
        ev->type = BS_EV_DATA;
        ev->kind = jpeg ? BS_DATA_JPEG : s->mode == BS_MODE_BW ? BS_DATA_BW1 : BS_DATA_GRAY8;
        ev->data = s->payload;
        ev->len = len;
        if (REC_IS_PACKED(type)) {
            if (!s->row && !(s->row = malloc(MAX_ROW_BYTES))) return BS_ERR_IO;
            if (!unpack_row(s->payload, len, s->row, &ev->len)) return BS_ERR_PROTOCOL;
            ev->data = s->row;
        }
        return BS_OK;
    }
}

void bs_cancel(bs_session *s) {
    if (!s || s->fd < 0) return;
    s->cancel_requested = 1;
    static const uint8_t cancel[] = { 0x1b, 'R', '\n', CMD_END };
    send(s->fd, cancel, sizeof cancel, 0);
}

const char *bs_status_string(bs_status st) {
    switch (st) {
        case BS_OK:             return "ok";
        case BS_ERR_CONNECT:    return "could not connect to the scanner";
        case BS_ERR_IO:         return "lost contact with the scanner";
        case BS_ERR_PROTOCOL:   return "unexpected reply from the scanner";
        case BS_ERR_NO_PAPER:   return "no document in the feeder";
        case BS_ERR_JAM:        return "document jam";
        case BS_ERR_COVER_OPEN: return "scanner cover is open";
        case BS_ERR_BUSY:       return "scanner is busy";
        case BS_ERR_CANCELLED:  return "scan cancelled";
        case BS_ERR_DEVICE:     return "scanner reported an error";
    }
    return "unknown error";
}
