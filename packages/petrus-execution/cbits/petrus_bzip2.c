/* One bzip2 stream decompressor over libbz2, as CPython's _bz2
 * BZ2Decompressor drives it (BZ2_bzDecompressInit(s, 0, 0)), for
 * Petrus.Motus.Execution.Archive.Stream.  Each step reports exactly what it
 * consumed and produced, so the bytes a truncated stream decodes to are
 * kept (the bzlib package drops its partly filled output buffer when the
 * input ends early). */
#include <bzlib.h>
#include <stdlib.h>

#include "petrus_execution.h"

void *petrus_bz2_open(void)
{
    bz_stream *stream = calloc(1, sizeof *stream);
    if (stream == NULL)
        return NULL;
    if (BZ2_bzDecompressInit(stream, 0, 0) != BZ_OK) {
        free(stream);
        return NULL;
    }
    return stream;
}

void petrus_bz2_close(void *stream)
{
    BZ2_bzDecompressEnd(stream);
    free(stream);
}

/* BZ2_bzDecompress over in[0..in_len) into out[0..out_len): BZ_OK,
 * BZ_STREAM_END or a negative error, with the bytes used and produced. */
int petrus_bz2_step(void *opaque, const char *in, unsigned int in_len, char *out, unsigned int out_len,
                    unsigned int *used, unsigned int *produced)
{
    bz_stream *stream = opaque;
    int result;
    stream->next_in = (char *) in;
    stream->avail_in = in_len;
    stream->next_out = out;
    stream->avail_out = out_len;
    result = BZ2_bzDecompress(stream);
    *used = in_len - stream->avail_in;
    *produced = out_len - stream->avail_out;
    return result;
}
