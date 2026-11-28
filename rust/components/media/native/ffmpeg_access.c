#include "ffmpeg_access.h"

unsigned wa_stream_count(AVFormatContext *context) {
    if (!context || !context->streams) return 0;
    return context->nb_streams;
}

/* The codec parameters of one stream, or NULL when the stream or its parameters are absent. */
static AVCodecParameters *parameters(AVFormatContext *context, unsigned index) {
    if (!context || !context->streams || index >= context->nb_streams) return NULL;
    AVStream *stream = context->streams[index];
    return stream ? stream->codecpar : NULL;
}

int wa_stream_kind(AVFormatContext *context, unsigned index) {
    AVCodecParameters *params = parameters(context, index);
    if (!params) return WA_MEDIA_KIND_OTHER;
    switch (params->codec_type) {
        case AVMEDIA_TYPE_VIDEO: return WA_MEDIA_KIND_VIDEO;
        case AVMEDIA_TYPE_AUDIO: return WA_MEDIA_KIND_AUDIO;
        case AVMEDIA_TYPE_SUBTITLE: return WA_MEDIA_KIND_SUBTITLE;
        default: return WA_MEDIA_KIND_OTHER;
    }
}

const char *wa_stream_codec(AVFormatContext *context, unsigned index) {
    AVCodecParameters *params = parameters(context, index);
    return params ? avcodec_get_name(params->codec_id) : NULL;
}

int wa_stream_width(AVFormatContext *context, unsigned index) {
    AVCodecParameters *params = parameters(context, index);
    return params ? params->width : 0;
}

int wa_stream_height(AVFormatContext *context, unsigned index) {
    AVCodecParameters *params = parameters(context, index);
    return params ? params->height : 0;
}

const char *wa_format_name(AVFormatContext *context) {
    if (!context || !context->iformat) return NULL;
    return context->iformat->name;
}

long long wa_duration_us(AVFormatContext *context) {
    return context ? context->duration : 0;
}
