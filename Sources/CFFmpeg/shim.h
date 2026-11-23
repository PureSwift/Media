// FFmpeg's libavcodec and libavutil, as Media's codecs use them, with what
// their headers give as macros, which Swift doesn't import, as functions.

#ifndef CFFMPEG_SHIM_H
#define CFFMPEG_SHIM_H

#include <errno.h>
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_drm.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libavutil/samplefmt.h>

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

/// The first sample format an audio encoder takes; AV_SAMPLE_FMT_NONE when
/// it doesn't say.
static inline enum AVSampleFormat cffmpeg_encoder_sample_format(const AVCodec *codec, const AVCodecContext *context) {
#if LIBAVCODEC_VERSION_INT >= AV_VERSION_INT(61, 13, 100)
    const void *formats = NULL;
    int count = 0;
    if (avcodec_get_supported_config(context, codec, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0, &formats, &count) < 0 || !formats || count == 0) {
        return AV_SAMPLE_FMT_NONE;
    }
    return ((const enum AVSampleFormat *)formats)[0];
#else
    (void)context;
    return codec->sample_fmts ? codec->sample_fmts[0] : AV_SAMPLE_FMT_NONE;
/// Picks VA-API's pixel format when a decoder offers it, for hardware
/// decoding, and libavcodec's own choice when not.
static inline enum AVPixelFormat cffmpeg_prefer_vaapi(AVCodecContext *context, const enum AVPixelFormat *formats) {
    for (const enum AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE; format++) {
        if (*format == AV_PIX_FMT_VAAPI) return *format;
    }
    return avcodec_default_get_format(context, formats);
}

static inline void cffmpeg_context_prefer_vaapi(AVCodecContext *context) { context->get_format = cffmpeg_prefer_vaapi; }

/// Whether a decoder decodes on a VA-API device.
static inline int cffmpeg_codec_has_vaapi(const AVCodec *codec) {
    for (int index = 0;; index++) {
        const AVCodecHWConfig *config = avcodec_get_hw_config(codec, index);
        if (!config) return 0;
        if ((config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) && config->device_type == AV_HWDEVICE_TYPE_VAAPI) return 1;
    }
}

static inline int cffmpeg_hwframe_map_read(void) { return AV_HWFRAME_MAP_READ; }

// A frame mapped to DRM PRIME: its layers and their planes, as dma-bufs.

static inline const AVDRMFrameDescriptor *cffmpeg_drm_descriptor(const AVFrame *frame) {
    return (const AVDRMFrameDescriptor *)frame->data[0];
}

static inline int cffmpeg_drm_layer_count(const AVDRMFrameDescriptor *descriptor) { return descriptor->nb_layers; }

static inline uint32_t cffmpeg_drm_layer_format(const AVDRMFrameDescriptor *descriptor, int layer) {
    return descriptor->layers[layer].format;
}

static inline int cffmpeg_drm_plane_count(const AVDRMFrameDescriptor *descriptor, int layer) {
    return descriptor->layers[layer].nb_planes;
}

static inline int cffmpeg_drm_plane_fd(const AVDRMFrameDescriptor *descriptor, int layer, int plane) {
    return descriptor->objects[descriptor->layers[layer].planes[plane].object_index].fd;
}

static inline int64_t cffmpeg_drm_plane_offset(const AVDRMFrameDescriptor *descriptor, int layer, int plane) {
    return descriptor->layers[layer].planes[plane].offset;
}

static inline int64_t cffmpeg_drm_plane_pitch(const AVDRMFrameDescriptor *descriptor, int layer, int plane) {
    return descriptor->layers[layer].planes[plane].pitch;
}

static inline uint64_t cffmpeg_drm_modifier(const AVDRMFrameDescriptor *descriptor) {
    return descriptor->objects[0].format_modifier;
}

#endif
}

/// AV_CODEC_CAP_SMALL_LAST_FRAME: an audio encoder takes a last frame
/// shorter than the others.
static inline int cffmpeg_codec_takes_small_last_frame(const AVCodec *codec) {
    return (codec->capabilities & AV_CODEC_CAP_SMALL_LAST_FRAME) != 0;
}

/// AV_CODEC_CAP_VARIABLE_FRAME_SIZE: an audio encoder takes frames of any
/// size.
static inline int cffmpeg_codec_takes_any_frame_size(const AVCodec *codec) {
    return (codec->capabilities & AV_CODEC_CAP_VARIABLE_FRAME_SIZE) != 0;
}

/// Picks VA-API's pixel format when a decoder offers it, for hardware
/// decoding, and libavcodec's own choice when not.
static inline enum AVPixelFormat cffmpeg_prefer_vaapi(AVCodecContext *context, const enum AVPixelFormat *formats) {
    for (const enum AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE; format++) {
        if (*format == AV_PIX_FMT_VAAPI) return *format;
    }
    return avcodec_default_get_format(context, formats);
}

static inline void cffmpeg_context_prefer_vaapi(AVCodecContext *context) { context->get_format = cffmpeg_prefer_vaapi; }

/// Whether a decoder decodes on a VA-API device.
static inline int cffmpeg_codec_has_vaapi(const AVCodec *codec) {
    for (int index = 0;; index++) {
        const AVCodecHWConfig *config = avcodec_get_hw_config(codec, index);
        if (!config) return 0;
        if ((config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) && config->device_type == AV_HWDEVICE_TYPE_VAAPI) return 1;
    }
}

static inline int cffmpeg_hwframe_map_read(void) { return AV_HWFRAME_MAP_READ; }

// A frame mapped to DRM PRIME: its layers and their planes, as dma-bufs.

static inline const AVDRMFrameDescriptor *cffmpeg_drm_descriptor(const AVFrame *frame) {
    return (const AVDRMFrameDescriptor *)frame->data[0];
}

static inline int cffmpeg_drm_layer_count(const AVDRMFrameDescriptor *descriptor) { return descriptor->nb_layers; }

static inline uint32_t cffmpeg_drm_layer_format(const AVDRMFrameDescriptor *descriptor, int layer) {
    return descriptor->layers[layer].format;
}

static inline int cffmpeg_drm_plane_count(const AVDRMFrameDescriptor *descriptor, int layer) {
    return descriptor->layers[layer].nb_planes;
}

static inline int cffmpeg_drm_plane_fd(const AVDRMFrameDescriptor *descriptor, int layer, int plane) {
    return descriptor->objects[descriptor->layers[layer].planes[plane].object_index].fd;
}

static inline int64_t cffmpeg_drm_plane_offset(const AVDRMFrameDescriptor *descriptor, int layer, int plane) {
    return descriptor->layers[layer].planes[plane].offset;
}

static inline int64_t cffmpeg_drm_plane_pitch(const AVDRMFrameDescriptor *descriptor, int layer, int plane) {
    return descriptor->layers[layer].planes[plane].pitch;
}

static inline uint64_t cffmpeg_drm_modifier(const AVDRMFrameDescriptor *descriptor) {
    return descriptor->objects[0].format_modifier;
}

#endif
