#ifndef DR_FLAC_ZIG_H
#define DR_FLAC_ZIG_H
#include "dr_flac.h"

drflac_uint32 drflac_zig_get_sample_rate(const drflac* f);
drflac_uint8  drflac_zig_get_channels(const drflac* f);
drflac_uint8  drflac_zig_get_bits_per_sample(const drflac* f);
drflac_uint64 drflac_zig_get_total_pcm_frame_count(const drflac* f);

#endif
