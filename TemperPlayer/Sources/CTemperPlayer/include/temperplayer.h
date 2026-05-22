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

#endif
