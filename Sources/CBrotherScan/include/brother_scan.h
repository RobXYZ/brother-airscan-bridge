// Brother network scan protocol (TCP 54921) as spoken by the ADS-1100W.
// Reverse engineered from Brother's ICA driver 3.5.0 and verified against a live device.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BS_DEFAULT_PORT 54921

typedef enum {
    BS_OK = 0,
    BS_ERR_CONNECT,     // could not reach the scanner
    BS_ERR_IO,          // socket error / timeout mid-conversation
    BS_ERR_PROTOCOL,    // scanner said something we don't understand
    BS_ERR_NO_PAPER,    // feeder empty
    BS_ERR_JAM,         // paper jam / feed problem
    BS_ERR_COVER_OPEN,
    BS_ERR_BUSY,        // scanner in use by someone else
    BS_ERR_CANCELLED,   // scan stopped (by us or at the device)
    BS_ERR_DEVICE,      // any other device-reported failure
} bs_status;

typedef enum {
    BS_MODE_COLOR = 0,  // 24-bit colour, delivered as JPEG
    BS_MODE_GRAY,       // 8-bit grey, delivered as raw rows
    BS_MODE_BW,         // 1-bit black & white, delivered as packed rows (1 = black)
} bs_mode;

typedef struct {
    bs_mode mode;
    int     dpi;        // 100, 150, 200, 300, 400, 600
    bool    duplex;
    // Scan window in pixels at `dpi`. Zero width/height means "full width" / "A4 length".
    int     left, top, width, height;
} bs_params;

// What the scanner agreed to after negotiation.
typedef struct {
    int dpi_x, dpi_y;
    int width;          // pixels per row the scanner will deliver; may exceed the request slightly
    int height;         // rows requested (the page may turn out shorter)
    int max_width;      // widest row available at this resolution
} bs_scan_info;

typedef enum {
    BS_EV_DATA = 0,     // a chunk of page data
    BS_EV_PAGE_END,     // current page complete, another may follow
    BS_EV_JOB_END,      // no more pages
} bs_event_type;

typedef enum {
    BS_DATA_JPEG = 0,   // chunk is a slice of a JPEG byte stream
    BS_DATA_GRAY8,      // chunk is a slice of 8-bit grey rows, `width` bytes each
    BS_DATA_BW1,        // slice of packed rows, `width`/8 bytes each, MSB first, 1 = black
} bs_data_kind;

typedef struct {
    bs_event_type  type;
    int            page;    // 1-based page counter as reported by the scanner
    bs_data_kind   kind;    // valid for BS_EV_DATA
    const uint8_t *data;    // valid until the next bs_next() call
    size_t         len;
} bs_event;

typedef struct bs_session bs_session;

// Connects and reads the scanner's greeting. `host` is a name or dotted address.
// On BS_ERR_CONNECT, errno holds the reason.
bs_status bs_open(const char *host, int port, bs_session **out);
void      bs_close(bs_session *s);

// Asks whether a document is in the feeder: BS_OK if so, BS_ERR_NO_PAPER if not.
bs_status bs_document_loaded(bs_session *s);

// Negotiates the scan window and starts feeding paper.
bs_status bs_start(bs_session *s, const bs_params *params, bs_scan_info *info);

// Pulls the next event. Returns BS_OK with *ev filled in, or an error that ends the job.
bs_status bs_next(bs_session *s, bs_event *ev);

// Asks the scanner to abandon the current job; keep calling bs_next() until it returns
// BS_ERR_CANCELLED. The scanner stops sending pages but still runs the rest of the stack
// through the feeder, which takes a few seconds per sheet. Safe to call from another thread.
void      bs_cancel(bs_session *s);

const char *bs_status_string(bs_status st);

// If set, protocol traffic is described on this stream (FILE *), for debugging.
void bs_set_trace(bs_session *s, void *file);

#ifdef __cplusplus
}
#endif
