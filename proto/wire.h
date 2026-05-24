#ifndef WIRE_H
#define WIRE_H

#include <stdint.h>

/* All fields little-endian. */

#define WIRE_MAGIC   0x3156584Au  /* 'J','X','V','1' */
#define WIRE_VERSION 1u
#define WIRE_OP_INVOKE 1u

/*
 * Request layout (variable length, written field-by-field):
 *
 *   uint32_t magic
 *   uint16_t version
 *   uint32_t req_id
 *   uint8_t  op
 *   uint8_t  flags
 *   uint16_t lib_len   + char lib[lib_len]
 *   uint16_t sym_len   + char sym[sym_len]
 *   uint16_t sig_len   + char sig[sig_len]
 *   uint32_t arg_len   + uint8_t args[arg_len]
 *
 * Reply layout:
 *   uint32_t req_id
 *   uint8_t  status    (0 = ok)
 *   uint8_t  retdesc   ('V' = void, 's' = string blob)
 *   uint32_t ret_len   + uint8_t ret[ret_len]
 */

/* Fixed-size header portions used for parsing. */
typedef struct {
    uint32_t magic;
    uint32_t req_id;
    uint8_t  op;
    uint8_t  flags;
} __attribute__((packed)) wire_req_hdr_t;

typedef struct {
    uint32_t req_id;
    uint8_t  status;
    uint8_t  retdesc;
    uint32_t ret_len;
} __attribute__((packed)) wire_reply_hdr_t;

/* Helpers ----------------------------------------------------------------- */

#include <stddef.h>
#include <errno.h>
#include <unistd.h>

/* Read exactly n bytes; returns 0 on success, -1 on EOF/error. */
static inline int read_exact(int fd, void *buf, size_t n) {
    uint8_t *p = (uint8_t *)buf;
    while (n > 0) {
        ssize_t r = read(fd, p, n);
        if (r <= 0) return -1;
        p += r; n -= (size_t)r;
    }
    return 0;
}

/* Write exactly n bytes; returns 0 on success, -1 on error. */
static inline int write_exact(int fd, const void *buf, size_t n) {
    const uint8_t *p = (const uint8_t *)buf;
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w <= 0) return -1;
        p += w; n -= (size_t)w;
    }
    return 0;
}

/* Read a uint16_t length-prefixed blob into *out (malloc'd). Caller frees. */
#include <stdlib.h>
#include <string.h>
static inline int read_lenstr16(int fd, char **out, uint16_t *lenout) {
    uint16_t len;
    if (read_exact(fd, &len, 2) < 0) return -1;
    char *buf = (char *)malloc(len + 1);
    if (!buf) return -1;
    if (len > 0 && read_exact(fd, buf, len) < 0) { free(buf); return -1; }
    buf[len] = '\0';
    *out = buf;
    if (lenout) *lenout = len;
    return 0;
}

/* Write a uint16_t length-prefixed string (no NUL transmitted). */
static inline int write_lenstr16(int fd, const char *s) {
    uint16_t len = (uint16_t)strlen(s);
    if (write_exact(fd, &len, 2) < 0) return -1;
    if (len > 0 && write_exact(fd, s, len) < 0) return -1;
    return 0;
}

#endif /* WIRE_H */
