/* Compile dr_libs implementations (single-header library pattern). */
#define DR_FLAC_IMPLEMENTATION
#define DR_WAV_IMPLEMENTATION

/* Include library headers to produce their function definitions. */
#include "dr_flac.h"
#include "dr_wav.h"

/* Include the Zig-facing header that declares the accessor helpers.
   Include guards on dr_flac.h / dr_wav.h prevent redefinition. */
#include "dr_flac_zig.h"

/* Accessor helpers — these let Zig read fields of the opaque drflac struct. */
drflac_uint32 drflac_zig_get_sample_rate(const drflac* f) {
    return (drflac_uint32)f->sampleRate;
}

drflac_uint8 drflac_zig_get_channels(const drflac* f) {
    return (drflac_uint8)f->channels;
}

drflac_uint8 drflac_zig_get_bits_per_sample(const drflac* f) {
    return (drflac_uint8)f->bitsPerSample;
}

drflac_uint64 drflac_zig_get_total_pcm_frame_count(const drflac* f) {
    return f->totalPCMFrameCount;
}
