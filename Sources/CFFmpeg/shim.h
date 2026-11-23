// FFmpeg's libavcodec and libavutil, as Media's codecs use them, with what
// their headers give as macros, which Swift doesn't import, as functions.

#ifndef CFFMPEG_SHIM_H
#define CFFMPEG_SHIM_H

#include <errno.h>
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>

/// AVERROR(EAGAIN): a codec wants input before it gives output, or the
/// other way around.
static inline int cffmpeg_error_again(void) { return AVERROR(EAGAIN); }

/// AVERROR_EOF: a codec has nothing more to give.
static inline int cffmpeg_error_eof(void) { return AVERROR_EOF; }

/// AV_NOPTS_VALUE: no timestamp.
static inline int64_t cffmpeg_no_timestamp(void) { return AV_NOPTS_VALUE; }

/// AV_INPUT_BUFFER_PADDING_SIZE: the zeroed bytes a codec's input needs
/// after its data.
static inline int cffmpeg_input_padding(void) { return AV_INPUT_BUFFER_PADDING_SIZE; }

static inline int cffmpeg_frame_is_key(const AVFrame *frame) { return (frame->flags & AV_FRAME_FLAG_KEY) != 0; }

static inline void cffmpeg_frame_set_key(AVFrame *frame, int key) {
    if (key) {
        frame->flags |= AV_FRAME_FLAG_KEY;
        frame->pict_type = AV_PICTURE_TYPE_I;
    } else {
        frame->flags &= ~AV_FRAME_FLAG_KEY;
        frame->pict_type = AV_PICTURE_TYPE_NONE;
    }
}

static inline int cffmpeg_packet_is_key(const AVPacket *packet) { return (packet->flags & AV_PKT_FLAG_KEY) != 0; }

static inline void cffmpeg_packet_set_key(AVPacket *packet, int key) {
    if (key) {
        packet->flags |= AV_PKT_FLAG_KEY;
    } else {
        packet->flags &= ~AV_PKT_FLAG_KEY;
    }
}

/// AV_CODEC_FLAG_GLOBAL_HEADER: an encoder puts its parameter sets in
/// `extradata`, as MP4 files carry them, not in each keyframe.
static inline void cffmpeg_context_set_global_header(AVCodecContext *context) { context->flags |= AV_CODEC_FLAG_GLOBAL_HEADER; }

#endif
