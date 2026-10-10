/*
 * JSON.stringify string escaping for well-formed UTF-8 (no lone
 * surrogates, so only ASCII bytes are ever escaped). Used by
 * Petrus.Viewer.Json.escapeUtf8: one pass sizes the output, one pass writes
 * it, eight bytes at a time.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define ONES 0x0101010101010101ULL
#define HIGHS 0x8080808080808080ULL

static inline int needs_escape(uint8_t w)
{
    return w < 0x20 || w == 0x22 || w == 0x5c;
}

/* Bytes the escaped form adds: 1 for \" \\ \b \t \n \f \r, 5 for \u00XX.
 * Branch-free per byte, in blocks with a 32-bit accumulator, so that the
 * compiler can vectorize it. */
size_t petrus_json_escape_extra(const uint8_t *src, size_t len)
{
    size_t extra = 0;
    size_t i = 0;
    while (i < len) {
        size_t end = len - i > 65536 ? i + 65536 : len;
        uint32_t acc = 0;
        for (; i < end; i++) {
            uint8_t w = src[i];
            uint32_t ctl = w < 0x20;
            uint32_t short_ctl = (w == 0x08) | (w == 0x09) | (w == 0x0a) | (w == 0x0c) | (w == 0x0d);
            uint32_t quote = (w == 0x22) | (w == 0x5c);
            acc += ctl * 5 - short_ctl * 4 + quote;
        }
        extra += acc;
    }
    return extra;
}

/* Flags (in the high bit of each byte) bytes below 0x20, quotes, and
 * backslashes. Bytes above the lowest flagged one may be flagged falsely
 * (borrows), but the lowest flagged byte is always a real one. */
static inline uint64_t special_bytes(uint64_t x)
{
    uint64_t lt = (x - ONES * 0x20) & ~x & HIGHS;
    uint64_t q = x ^ (ONES * 0x22);
    uint64_t b = x ^ (ONES * 0x5c);
    return lt | ((q - ONES) & ~q & HIGHS) | ((b - ONES) & ~b & HIGHS);
}

/* the letter after the backslash, or 0 for \u00XX (a table, not a switch:
 * quotes and newlines alternate unpredictably in JSON text) */
static const uint8_t short_escape[256] = {
    [0x08] = 'b', [0x09] = 't', [0x0a] = 'n', [0x0c] = 'f', [0x0d] = 'r',
    [0x22] = '"', [0x5c] = '\\',
};

static inline uint8_t *escape_byte(uint8_t w, uint8_t *dst)
{
    static const char hex[] = "0123456789abcdef";
    uint8_t c = short_escape[w];
    dst[0] = '\\';
    if (c) {
        dst[1] = c;
        return dst + 2;
    }
    dst[1] = 'u';
    dst[2] = '0';
    dst[3] = '0';
    dst[4] = (uint8_t)hex[w >> 4];
    dst[5] = (uint8_t)hex[w & 15];
    return dst + 6;
}

/* Write the escaped form of src into dst, which holds exactly
 * dst_len = len + petrus_json_escape_extra(src, len) bytes. Eight bytes at
 * a time: a word without special bytes is stored whole; otherwise the word
 * is stored whole too when it fits (only its bytes before the special one
 * count; later writes overwrite the rest), then the special byte is
 * escaped. */
void petrus_json_escape_write(const uint8_t *src, size_t len, uint8_t *dst, size_t dst_len)
{
    uint8_t *dst_end = dst + dst_len;
    size_t i = 0;
    while (i + 8 <= len) {
        uint64_t x;
        memcpy(&x, src + i, 8);
        uint64_t m = special_bytes(x);
        if (dst + 8 <= dst_end)
            memcpy(dst, &x, 8);
        else
            memcpy(dst, &x, m ? ((size_t)__builtin_ctzll(m) >> 3) : 8);
        if (!m) {
            dst += 8;
            i += 8;
            continue;
        }
        size_t k = (size_t)__builtin_ctzll(m) >> 3;
        dst += k;
        i += k;
        dst = escape_byte(src[i], dst);
        i++;
    }
    for (; i < len; i++) {
        uint8_t w = src[i];
        if (needs_escape(w))
            dst = escape_byte(w, dst);
        else
            *dst++ = w;
    }
}
