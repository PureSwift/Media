// FFmpeg's libavformat, as Media's files use it, with what its headers
// give as macros, which Swift doesn't import, as functions.

#ifndef CFFMPEG_FORMAT_SHIM_H
#define CFFMPEG_FORMAT_SHIM_H

#include <errno.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>

static inline int cffmpeg_format_error_again(void) { return AVERROR(EAGAIN); }

static inline int cffmpeg_format_error_eof(void) { return AVERROR_EOF; }

static inline int64_t cffmpeg_format_no_timestamp(void) { return AV_NOPTS_VALUE; }

static inline int cffmpeg_format_packet_is_key(const AVPacket *packet) { return (packet->flags & AV_PKT_FLAG_KEY) != 0; }

static inline int cffmpeg_format_packet_is_discarded(const AVPacket *packet) { return (packet->flags & AV_PKT_FLAG_DISCARD) != 0; }

static inline void cffmpeg_format_packet_set_key(AVPacket *packet, int key) {
    if (key) {
        packet->flags |= AV_PKT_FLAG_KEY;
    } else {
        packet->flags &= ~AV_PKT_FLAG_KEY;
    }
}

/// AVSEEK_FLAG_BACKWARD: seek to the keyframe at or before the time.
static inline int cffmpeg_format_seek_backward(void) { return AVSEEK_FLAG_BACKWARD; }

/// AVFMT_NOFILE: the container writes no file of its own.
static inline int cffmpeg_format_needs_file(const AVOutputFormat *format) { return (format->flags & AVFMT_NOFILE) == 0; }

/// AVFMT_GLOBALHEADER: the container keeps codecs' parameter sets in its
/// header.
static inline int cffmpeg_format_wants_global_header(const AVOutputFormat *format) { return (format->flags & AVFMT_GLOBALHEADER) != 0; }

/// AVIO_FLAG_WRITE.
static inline int cffmpeg_format_write_flag(void) { return AVIO_FLAG_WRITE; }

#endif
