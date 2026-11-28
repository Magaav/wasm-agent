/* The audio track, decoded and rewritten as WAV at the rate and channel count the request asks for.
 *
 * The shape is frames' shape - open, find the stream, decode, convert, encode, write - with two differences
 * that are the whole point of doing it in C: the converter is libswresample (sample format, rate and channel
 * layout in one call) and the writer is the wav muxer through libavformat, because a WAV file has a header
 * whose fields come from the same codec parameters that produced the samples.
 */
#include "ffmpeg_access.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>

/* Everything the loop needs to keep between calls, so failures have one place to free from. */
typedef struct {
    AVFormatContext *input;
    AVFormatContext *output;
    AVCodecContext *decoder;
    AVCodecContext *encoder;
    SwrContext *resampler;
    AVPacket *packet;
    AVFrame *frame;
    AVFrame *converted;
    int stream_index;
    /* Samples written so far: the WAV muxer rejects packets without a pts, and "making some up" is a warning
     * that means the timestamps in the file are not the ones this loop intended. */
    long long samples;
} AudioWork;

static void release(AudioWork *work) {
    av_frame_free(&work->converted);
    av_frame_free(&work->frame);
    av_packet_free(&work->packet);
    swr_free(&work->resampler);
    avcodec_free_context(&work->encoder);
    avcodec_free_context(&work->decoder);
    if (work->output) {
        if (!(work->output->oformat->flags & AVFMT_NOFILE) && work->output->pb) avio_closep(&work->output->pb);
        avformat_free_context(work->output);
    }
    if (work->input) avformat_close_input(&work->input);
}

/* Find the audio stream and open its decoder. */
static int open_decoder(AudioWork *work) {
    int index = av_find_best_stream(work->input, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (index < 0) return index;
    AVCodecParameters *params = work->input->streams[index]->codecpar;
    const AVCodec *codec = avcodec_find_decoder(params->codec_id);
    if (!codec) return AVERROR_DECODER_NOT_FOUND;
    work->decoder = avcodec_alloc_context3(codec);
    if (!work->decoder) return AVERROR(ENOMEM);
    int status = avcodec_parameters_to_context(work->decoder, params);
    if (status < 0) return status;
    work->decoder->thread_count = 1;
    status = avcodec_open2(work->decoder, codec, NULL);
    if (status < 0) return status;
    work->stream_index = index;
    return 0;
}

/* Open the WAV output at the requested rate and channel count. */
static int open_output(AudioWork *work, const char *out_path, int sample_rate, int channels) {
    int status = avformat_alloc_output_context2(&work->output, NULL, "wav", out_path);
    if (status < 0 || !work->output) return status < 0 ? status : AVERROR(ENOMEM);

    const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_PCM_S16LE);
    if (!codec) return AVERROR_ENCODER_NOT_FOUND;
    work->encoder = avcodec_alloc_context3(codec);
    if (!work->encoder) return AVERROR(ENOMEM);
    work->encoder->sample_rate = sample_rate;
    work->encoder->ch_layout = channels == 1 ? (AVChannelLayout)AV_CHANNEL_LAYOUT_MONO
                                             : (AVChannelLayout)AV_CHANNEL_LAYOUT_STEREO;
    work->encoder->sample_fmt = AV_SAMPLE_FMT_S16;
    work->encoder->time_base = (AVRational){1, sample_rate};
    status = avcodec_open2(work->encoder, codec, NULL);
    if (status < 0) return status;

    AVStream *stream = avformat_new_stream(work->output, NULL);
    if (!stream) return AVERROR(ENOMEM);
    status = avcodec_parameters_from_context(stream->codecpar, work->encoder);
    if (status < 0) return status;
    stream->time_base = work->encoder->time_base;

    if (!(work->output->oformat->flags & AVFMT_NOFILE)) {
        status = avio_open(&work->output->pb, out_path, AVIO_FLAG_WRITE);
        if (status < 0) return status;
    }
    return avformat_write_header(work->output, NULL);
}

/* Convert one decoded frame into the encoder's format and write it out. Returns 0 or a negative averror. */
static int write_converted(AudioWork *work) {
    int status = swr_convert_frame(work->resampler, work->converted, work->frame);
    if (status < 0) return status;
    if (!work->converted->nb_samples) return 0;
    work->converted->pts = work->samples;
    work->samples += work->converted->nb_samples;
    status = avcodec_send_frame(work->encoder, work->converted);
    if (status < 0) return status;
    while (1) {
        status = avcodec_receive_packet(work->encoder, work->packet);
        if (status == AVERROR(EAGAIN) || status == AVERROR_EOF) return 0;
        if (status < 0) return status;
        status = av_interleaved_write_frame(work->output, work->packet);
        av_packet_unref(work->packet);
        if (status < 0) return status;
    }
}

/* Decode, convert and write. Returns 0 or a negative averror; the caller reads duration from sample_count. */
int wa_write_audio(const char *path, int sample_rate, int channels, const char *out_path,
                   long long *samples_out) {
    AudioWork work = {0};
    int status = avformat_open_input(&work.input, path, NULL, NULL);
    if (status < 0) return status;
    status = avformat_find_stream_info(work.input, NULL);
    if (status < 0) {
        release(&work);
        return status;
    }
    status = open_decoder(&work);
    if (status < 0) {
        release(&work);
        return status;
    }
    status = open_output(&work, out_path, sample_rate, channels);
    if (status < 0) {
        release(&work);
        return status;
    }

    AVChannelLayout in_layout = work.decoder->ch_layout;
    if (in_layout.nb_channels == 0) av_channel_layout_default(&in_layout, 2);
    status = swr_alloc_set_opts2(&work.resampler, &work.encoder->ch_layout, work.encoder->sample_fmt,
                                 work.encoder->sample_rate, &in_layout, work.decoder->sample_fmt,
                                 work.decoder->sample_rate, 0, NULL);
    if (status < 0) {
        release(&work);
        return status;
    }
    status = swr_init(work.resampler);
    if (status < 0) {
        release(&work);
        return status;
    }

    work.packet = av_packet_alloc();
    work.frame = av_frame_alloc();
    work.converted = av_frame_alloc();
    if (!work.packet || !work.frame || !work.converted) {
        release(&work);
        return AVERROR(ENOMEM);
    }
    work.converted->format = work.encoder->sample_fmt;
    work.converted->ch_layout = work.encoder->ch_layout;
    work.converted->sample_rate = work.encoder->sample_rate;

    long long samples = 0;
    work.samples = 0;
    while (av_read_frame(work.input, work.packet) >= 0) {
        if (work.packet->stream_index != work.stream_index) {
            av_packet_unref(work.packet);
            continue;
        }
        if (avcodec_send_packet(work.decoder, work.packet) >= 0) {
            av_packet_unref(work.packet);
            while (avcodec_receive_frame(work.decoder, work.frame) >= 0) {
                status = write_converted(&work);
                if (status < 0) break;
                samples += work.converted->nb_samples;
                av_frame_unref(work.frame);
            }
        } else {
            av_packet_unref(work.packet);
        }
        if (status < 0) break;
    }

    if (status >= 0) {
        /* Flush the decoder: the last frames have no packet of their own. */
        avcodec_send_packet(work.decoder, NULL);
        while (avcodec_receive_frame(work.decoder, work.frame) >= 0) {
            status = write_converted(&work);
            if (status < 0) break;
            samples += work.converted->nb_samples;
            av_frame_unref(work.frame);
        }
    }
    if (status >= 0) {
        avcodec_send_frame(work.encoder, NULL);
        while (avcodec_receive_packet(work.encoder, work.packet) >= 0) {
            av_interleaved_write_frame(work.output, work.packet);
            av_packet_unref(work.packet);
        }
        status = av_write_trailer(work.output);
    }

    if (samples_out) *samples_out = samples;
    release(&work);
    return status < 0 ? status : 0;
}
