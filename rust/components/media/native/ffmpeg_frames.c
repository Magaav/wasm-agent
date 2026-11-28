/* Stills out of a video: seek, decode, scale, encode PPM, write.
 *
 * WHY PPM AND NOT JPEG. The measurement (docs/missions/reports/media-is-a-component.md) proved ffmpeg's own
 * mjpeg encoder traps on wasm - `out of bounds memory access` inside ff_mpv_encode_picture, reproduced on one
 * synthetic frame with no decoder involved - and libjpeg-turbo's error handling needs setjmp/longjmp, which
 * wasi-sdk emits only with an engine that implements exception handling. PPM has neither problem and costs
 * nothing to decode later; JPEG would be smaller on the wire and is the open question, not a decision taken
 * here by accident.
 *
 * WHY IN C AND NOT IN RUST: this loop is avcodec's - send a packet, receive frames, compare timestamps,
 * convert, encode - and every one of those calls takes a struct this component deliberately does not mirror
 * (see ffi.rs). The C compiler knows the layouts; Rust only ever sees the file names that came out.
 */
#include "ffmpeg_access.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Open the best video stream and its decoder. Returns 0 or a negative averror. */
static int open_video(AVFormatContext *context, AVCodecContext **decoder_out, int *stream_out) {
    int index = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (index < 0) return index;
    AVCodecParameters *params = context->streams[index]->codecpar;
    const AVCodec *codec = avcodec_find_decoder(params->codec_id);
    if (!codec) return AVERROR_DECODER_NOT_FOUND;
    AVCodecContext *decoder = avcodec_alloc_context3(codec);
    if (!decoder) return AVERROR(ENOMEM);
    int status = avcodec_parameters_to_context(decoder, params);
    if (status < 0) {
        avcodec_free_context(&decoder);
        return status;
    }
    /* No threads: wasip2 has none, and this build was configured without them. */
    decoder->thread_count = 1;
    status = avcodec_open2(decoder, codec, NULL);
    if (status < 0) {
        avcodec_free_context(&decoder);
        return status;
    }
    *decoder_out = decoder;
    *stream_out = index;
    return 0;
}

/* The scaled geometry that fits inside max_pixels, keeping the aspect ratio. */
static void scaled_size(int width, int height, int max_pixels, int *out_width, int *out_height) {
    if (max_pixels <= 0 || width <= 0 || height <= 0) {
        *out_width = width;
        *out_height = height;
        return;
    }
    long long pixels = (long long)width * height;
    if (pixels <= max_pixels) {
        *out_width = width;
        *out_height = height;
        return;
    }
    double factor = 1.0;
    while ((double)width * height * factor * factor > max_pixels) factor *= 0.99;
    /* Even dimensions keep the scaler and every consumer happy. */
    int w = (int)(width * factor) & ~1;
    int h = (int)(height * factor) & ~1;
    *out_width = w > 0 ? w : 2;
    *out_height = h > 0 ? h : 2;
}

/* Write one encoded packet to a file. Returns 0 or a negative averror. */
static int write_packet(const char *path, const AVPacket *packet) {
    FILE *file = fopen(path, "wb");
    if (!file) return AVERROR(errno);
    size_t written = fwrite(packet->data, 1, (size_t)packet->size, file);
    int closed = fclose(file);
    if (written != (size_t)packet->size || closed != 0) return AVERROR(EIO);
    return 0;
}

/* One decoded frame, scaled and encoded to `path`. */
static int encode_still(AVFrame *source, const AVCodec *encoder, struct SwsContext **scaler,
                        int width, int height, const char *path) {
    if (!*scaler) {
        *scaler = sws_getContext(source->width, source->height, source->format, width, height,
                                 AV_PIX_FMT_RGB24, SWS_BILINEAR, NULL, NULL, NULL);
        if (!*scaler) return AVERROR(ENOMEM);
    }
    AVFrame *rgb = av_frame_alloc();
    if (!rgb) return AVERROR(ENOMEM);
    rgb->format = AV_PIX_FMT_RGB24;
    rgb->width = width;
    rgb->height = height;
    int status = av_frame_get_buffer(rgb, 0);
    if (status < 0) {
        av_frame_free(&rgb);
        return status;
    }
    sws_scale(*scaler, (const uint8_t *const *)source->data, source->linesize, 0, source->height,
              rgb->data, rgb->linesize);

    AVCodecContext *context = avcodec_alloc_context3(encoder);
    if (!context) {
        av_frame_free(&rgb);
        return AVERROR(ENOMEM);
    }
    context->pix_fmt = AV_PIX_FMT_RGB24;
    context->width = width;
    context->height = height;
    context->time_base = (AVRational){1, 1000};
    status = avcodec_open2(context, encoder, NULL);
    if (status < 0) {
        avcodec_free_context(&context);
        av_frame_free(&rgb);
        return status;
    }
    status = avcodec_send_frame(context, rgb);
    if (status >= 0) {
        AVPacket *packet = av_packet_alloc();
        if (!packet) {
            status = AVERROR(ENOMEM);
        } else {
            status = avcodec_receive_packet(context, packet);
            if (status >= 0) status = write_packet(path, packet);
            av_packet_free(&packet);
        }
    }
    avcodec_free_context(&context);
    av_frame_free(&rgb);
    return status < 0 ? status : 0;
}

/* The frame whose timestamp is at or after `moment_ms`, decoded from a seek to that moment. */
int wa_write_frame(const char *path, long long moment_ms, int max_pixels, const char *out_path) {
    AVFormatContext *context = NULL;
    int status = avformat_open_input(&context, path, NULL, NULL);
    if (status < 0) return status;
    status = avformat_find_stream_info(context, NULL);
    if (status < 0) {
        avformat_close_input(&context);
        return status;
    }

    AVCodecContext *decoder = NULL;
    int stream_index = -1;
    status = open_video(context, &decoder, &stream_index);
    if (status < 0) {
        avformat_close_input(&context);
        return status;
    }

    AVRational time_base = context->streams[stream_index]->time_base;
    long long target = av_rescale_q(moment_ms, (AVRational){1, 1000}, time_base);
    status = av_seek_frame(context, stream_index, target, AVSEEK_FLAG_BACKWARD);

    const AVCodec *encoder = avcodec_find_encoder(AV_CODEC_ID_PPM);
    if (!encoder) {
        avcodec_free_context(&decoder);
        avformat_close_input(&context);
        return AVERROR_ENCODER_NOT_FOUND;
    }

    struct SwsContext *scaler = NULL;
    int width = 0;
    int height = 0;
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    int written = 0;
    while (packet && frame && !written) {
        int read = av_read_frame(context, packet);
        if (read < 0) break;
        if (packet->stream_index != stream_index) {
            av_packet_unref(packet);
            continue;
        }
        if (avcodec_send_packet(decoder, packet) < 0) {
            av_packet_unref(packet);
            continue;
        }
        av_packet_unref(packet);
        while (avcodec_receive_frame(decoder, frame) >= 0) {
            long long at = frame->best_effort_timestamp;
            /* BOTH sides are in the stream time base: `target` was rescaled to it above, so comparing it
             * against {1,1} compared ticks with milliseconds and every frame looked early. */
            int past = at != AV_NOPTS_VALUE && at >= target;
            if (past) {
                if (!width) scaled_size(frame->width, frame->height, max_pixels, &width, &height);
                int encoded = encode_still(frame, encoder, &scaler, width, height, out_path);
                if (encoded < 0) status = encoded;
                written = 1;
            }
            av_frame_unref(frame);
            if (written) break;
        }
    }

    if (scaler) sws_freeContext(scaler);
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&decoder);
    avformat_close_input(&context);
    if (!written) return status < 0 ? status : AVERROR_EOF;
    return status < 0 ? status : 0;
}
