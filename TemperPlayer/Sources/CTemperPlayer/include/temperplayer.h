#ifndef temperplayer_h
#define temperplayer_h

#include <stdint.h>

struct SampleFormat {
    int sample_rate;
    int channels;
    int bit_depth;
    double duration_seconds;
};

struct MasteringInfo {
    double lufs;
    double true_peak_db;
    double peak_db;
    double dynamic_range_db;
    double phase_correlation;
    double dc_offset_pct;
    int phase_ok;
};

void* decode_open(const char* path);
int  decode_read_frames(void* handle, float* buf, int frame_count);
int  decode_seek(void* handle, int64_t pcm_frame);
void decode_close(void* handle);
struct SampleFormat decode_get_info(void* handle);
char* metadata_read(const char* path);
void  metadata_free(char* ptr);
struct MasteringInfo decode_get_mastering(const char* path);

// Peak-locked phase vocoder pitch shifter (net 1:1 rate, shifts by cents)
void* pitch_create(float sample_rate, int channels);
void  pitch_destroy(void* handle);
void  pitch_set_cents(void* handle, float cents);
void  pitch_reset(void* handle);
int   pitch_latency_frames(void* handle);
int   pitch_process(void* handle,
                    const float* in_l, const float* in_r, int in_frames,
                    float* out_l, float* out_r, int out_cap);
int   pitch_flush(void* handle, float* out_l, float* out_r, int out_cap);

#endif
