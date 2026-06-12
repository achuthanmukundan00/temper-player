// Peak-locked phase vocoder pitch shifter with transient preservation
// and Kaiser-windowed sinc resampling.
//
// Signal path:  input -> STFT time-stretch (ratio p) -> sinc resample (step p)
// Net output rate is 1:1 with input; pitch is shifted by p = 2^(cents/1200).
//
// Quality decisions:
//  - Identity phase locking to spectral peaks (Laroche & Dolson 1999) keeps
//    harmonics coherent instead of phasey/papery.
//  - Spectral-flux transient detection resets phases so attacks stay sharp.
//  - At ratio == 1.0 the entire chain is mathematically transparent:
//    synthesis phases = analysis phases, hop in == hop out, and the resampler
//    kernel is an exact delta at integer positions.

const std = @import("std");

const two_pi: f32 = 2.0 * std.math.pi;

inline fn wrapPhase(x: f32) f32 {
    return x - two_pi * @round(x / two_pi);
}

fn sinc(x: f64) f64 {
    if (@abs(x) < 1e-9) return 1.0;
    const px = std.math.pi * x;
    return @sin(px) / px;
}

fn besselI0(x: f64) f64 {
    var sum: f64 = 1.0;
    var term: f64 = 1.0;
    var k: f64 = 1.0;
    while (k <= 40.0) : (k += 1.0) {
        const t = x / (2.0 * k);
        term *= t * t;
        sum += term;
        if (term < 1e-12 * sum) break;
    }
    return sum;
}

fn Fft(comptime n: usize) type {
    return struct {
        const Self = @This();
        const bits: u5 = @intCast(std.math.log2_int(usize, n));

        cos_tab: [n / 2]f32,
        sin_tab: [n / 2]f32,
        rev: [n]u32,

        fn init(self: *Self) void {
            for (0..n / 2) |k| {
                const ang = -two_pi * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
                self.cos_tab[k] = @cos(ang);
                self.sin_tab[k] = @sin(ang);
            }
            for (0..n) |i| {
                self.rev[i] = @bitReverse(@as(u32, @intCast(i))) >> @intCast(32 - @as(u6, bits));
            }
        }

        fn forward(self: *const Self, re: *[n]f32, im: *[n]f32) void {
            for (0..n) |i| {
                const j: usize = self.rev[i];
                if (i < j) {
                    std.mem.swap(f32, &re[i], &re[j]);
                    std.mem.swap(f32, &im[i], &im[j]);
                }
            }
            var len: usize = 2;
            while (len <= n) : (len <<= 1) {
                const half = len / 2;
                const step = n / len;
                var base: usize = 0;
                while (base < n) : (base += len) {
                    for (0..half) |j| {
                        const wr = self.cos_tab[j * step];
                        const wi = self.sin_tab[j * step];
                        const a = base + j;
                        const b = a + half;
                        const tr = re[b] * wr - im[b] * wi;
                        const ti = re[b] * wi + im[b] * wr;
                        re[b] = re[a] - tr;
                        im[b] = im[a] - ti;
                        re[a] += tr;
                        im[a] += ti;
                    }
                }
            }
        }

        fn inverse(self: *const Self, re: *[n]f32, im: *[n]f32) void {
            for (im) |*v| v.* = -v.*;
            self.forward(re, im);
            const s: f32 = 1.0 / @as(f32, @floatFromInt(n));
            for (re, im) |*r, *i| {
                r.* *= s;
                i.* = -i.* * s;
            }
        }
    };
}

pub const PitchShifter = struct {
    const N = 2048; // analysis window (43ms @ 48k)
    const HOP = 512; // 75% overlap
    const HALF = N / 2 + 1;
    const MAX_CH = 2;
    const IN_CAP = 1 << 15;
    const OUT_CAP = 1 << 16;
    const TAPS = 32;
    const HTAPS = TAPS / 2;
    const PHASES = 256;
    const KAISER_BETA = 8.6;
    const TRANSIENT_FLUX_RATIO: f32 = 0.55;
    const PEAK_FLOOR: f32 = 1e-7;

    channels: usize,
    sample_rate: f32,
    cents: f32,
    ratio: f64,

    fft: Fft(N),
    window: [N]f32,

    // Input ring (absolute positions, modulo IN_CAP)
    in_ring: [MAX_CH][IN_CAP]f32,
    in_write: usize,
    in_read: usize,

    // Stretched-output overlap-add ring (absolute positions, modulo OUT_CAP)
    out_ring: [MAX_CH][OUT_CAP]f32,
    weight_ring: [OUT_CAP]f32,
    out_zeroed_end: usize,
    out_final_end: usize,
    synth_pos: f64,
    last_place: usize,
    started: bool,

    // Phase vocoder state
    prev_phase: [MAX_CH][HALF]f32,
    synth_phase: [MAX_CH][HALF]f32,
    prev_mag_mid: [HALF]f32,

    // Resampler
    res_pos: f64,
    res_table: [PHASES + 1][TAPS]f32,

    // Scratch
    re: [N]f32,
    im: [N]f32,
    mag: [MAX_CH][HALF]f32,
    ph: [MAX_CH][HALF]f32,
    mag_mid: [HALF]f32,
    peak_of: [HALF]u32,
    peaks: [HALF]u32,
    rot_buf: [HALF]f32,

    pub fn init(self: *PitchShifter, sample_rate: f32, channels: usize) void {
        self.channels = @min(channels, MAX_CH);
        if (self.channels == 0) self.channels = 1;
        self.sample_rate = sample_rate;
        self.fft.init();
        for (0..N) |i| {
            self.window[i] = 0.5 - 0.5 * @cos(two_pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(N)));
        }
        self.cents = 0;
        self.ratio = 1.0;
        self.buildResampleTable();
        self.resetState();
    }

    pub fn setCents(self: *PitchShifter, cents: f32) void {
        const clamped = std.math.clamp(cents, -1200.0, 1200.0);
        if (clamped == self.cents) return;
        self.cents = clamped;
        self.ratio = std.math.exp2(@as(f64, clamped) / 1200.0);
        self.buildResampleTable();
    }

    pub fn reset(self: *PitchShifter) void {
        self.resetState();
    }

    /// Total chain latency in frames (input domain == output domain, net 1:1).
    pub fn latencyFrames(self: *const PitchShifter) usize {
        _ = self;
        return N + TAPS;
    }

    fn resetState(self: *PitchShifter) void {
        for (0..MAX_CH) |ch| {
            @memset(&self.in_ring[ch], 0);
            @memset(&self.out_ring[ch], 0);
            @memset(&self.prev_phase[ch], 0);
            @memset(&self.synth_phase[ch], 0);
        }
        @memset(&self.weight_ring, 0);
        @memset(&self.prev_mag_mid, 0);
        self.in_write = 0;
        self.in_read = 0;
        self.out_zeroed_end = 0;
        self.out_final_end = 0;
        self.synth_pos = 0;
        self.last_place = 0;
        self.started = false;
        self.res_pos = 0;
    }

    fn buildResampleTable(self: *PitchShifter) void {
        // Anti-alias for pitch-up (decimation); exact delta at unity.
        const fc: f64 = if (self.ratio > 1.0) 0.95 / self.ratio else 1.0;
        const denom = besselI0(KAISER_BETA);
        for (0..PHASES + 1) |q| {
            const frac = @as(f64, @floatFromInt(q)) / @as(f64, PHASES);
            var sum: f64 = 0;
            for (0..TAPS) |i| {
                const t = @as(f64, @floatFromInt(@as(i64, @intCast(i)) - (HTAPS - 1))) - frac;
                const u = t / @as(f64, HTAPS);
                var h: f64 = 0;
                if (@abs(u) < 1.0) {
                    const kaiser = besselI0(KAISER_BETA * @sqrt(1.0 - u * u)) / denom;
                    h = fc * sinc(fc * t) * kaiser;
                }
                self.res_table[q][i] = @floatCast(h);
                sum += h;
            }
            // Normalize DC gain to 1 to avoid amplitude ripple across phases.
            if (sum > 1e-9) {
                const g: f32 = @floatCast(1.0 / sum);
                for (0..TAPS) |i| self.res_table[q][i] *= g;
            }
        }
    }

    pub fn process(
        self: *PitchShifter,
        in_l: ?[*]const f32,
        in_r: ?[*]const f32,
        in_frames: usize,
        out_l: ?[*]f32,
        out_r: ?[*]f32,
        out_cap: usize,
    ) usize {
        if (in_frames > 0) {
            if (in_l) |l| self.pushInput(l, in_r, in_frames);
        }
        self.analyzeAvailable();
        return self.produce(out_l, out_r, out_cap);
    }

    /// Drain the window tail at end of stream.
    pub fn flush(self: *PitchShifter, out_l: ?[*]f32, out_r: ?[*]f32, out_cap: usize) usize {
        var zeros = [_]f32{0} ** 256;
        var produced: usize = 0;
        var fed: usize = 0;
        const max_feed = 2 * N + TAPS * 4;
        while (produced < out_cap and fed < max_feed) {
            self.pushInput(&zeros, null, zeros.len);
            fed += zeros.len;
            self.analyzeAvailable();
            const ol: ?[*]f32 = if (out_l) |p| p + produced else null;
            const orr: ?[*]f32 = if (out_r) |p| p + produced else null;
            produced += self.produce(ol, orr, out_cap - produced);
        }
        return produced;
    }

    fn pushInput(self: *PitchShifter, in_l: [*]const f32, in_r: ?[*]const f32, n: usize) void {
        // Overflow guard: callers drain every call so this should never trip.
        if (self.in_write - self.in_read + n > IN_CAP) {
            self.in_read = self.in_write + n - IN_CAP;
        }
        for (0..n) |i| {
            const idx = (self.in_write + i) % IN_CAP;
            self.in_ring[0][idx] = in_l[i];
            if (self.channels == 2) {
                self.in_ring[1][idx] = if (in_r) |r| r[i] else in_l[i];
            }
        }
        self.in_write += n;
    }

    fn analyzeAvailable(self: *PitchShifter) void {
        while (self.in_write - self.in_read >= N) {
            // Stretch-ring overrun guard: never let the writer lap the resampler.
            const res_base: usize = @intFromFloat(@max(0.0, @floor(self.res_pos)));
            const read_low = res_base -| HTAPS;
            const next_place: usize = @intFromFloat(@ceil(self.synth_pos + @as(f64, HOP) * self.ratio) + 1.0);
            if (next_place + N - @min(read_low, next_place) > OUT_CAP) break;
            self.analyzeFrame();
            self.in_read += HOP;
        }
    }

    fn analyzeFrame(self: *PitchShifter) void {
        const start = self.in_read;

        // 1. Analysis FFT per channel.
        for (0..self.channels) |ch| {
            for (0..N) |i| {
                self.re[i] = self.in_ring[ch][(start + i) % IN_CAP] * self.window[i];
                self.im[i] = 0;
            }
            self.fft.forward(&self.re, &self.im);
            for (0..HALF) |k| {
                self.mag[ch][k] = @sqrt(self.re[k] * self.re[k] + self.im[k] * self.im[k]);
                self.ph[ch][k] = std.math.atan2(self.im[k], self.re[k]);
            }
        }

        // 2. Mid magnitude (shared analysis decisions keep the stereo image stable).
        if (self.channels == 2) {
            for (0..HALF) |k| self.mag_mid[k] = 0.5 * (self.mag[0][k] + self.mag[1][k]);
        } else {
            @memcpy(&self.mag_mid, &self.mag[0]);
        }

        // 3. Transient detection via positive spectral flux.
        var flux: f32 = 0;
        var energy: f32 = 1e-9;
        for (0..HALF) |k| {
            flux += @max(0, self.mag_mid[k] - self.prev_mag_mid[k]);
            energy += self.prev_mag_mid[k];
        }
        const transient = self.started and flux > TRANSIENT_FLUX_RATIO * energy;

        // 4. Frame placement with fractional-hop error diffusion.
        var place: usize = 0;
        var hs: f32 = HOP;
        if (self.started) {
            self.synth_pos += @as(f64, HOP) * self.ratio;
            place = @intFromFloat(@round(self.synth_pos));
            if (place <= self.last_place) place = self.last_place + 1;
            hs = @floatFromInt(place - self.last_place);
        } else {
            self.synth_pos = 0;
        }

        // 5. Synthesis phases.
        const unity = self.ratio == 1.0;
        if (!self.started or transient or unity) {
            for (0..self.channels) |ch| {
                @memcpy(&self.synth_phase[ch], &self.ph[ch]);
            }
        } else {
            self.lockPhases(hs);
        }

        // 6. Resynthesize and overlap-add.
        self.zeroExtendOutput(place + N);
        for (0..self.channels) |ch| {
            for (0..HALF) |k| {
                self.re[k] = self.mag[ch][k] * @cos(self.synth_phase[ch][k]);
                self.im[k] = self.mag[ch][k] * @sin(self.synth_phase[ch][k]);
            }
            self.im[0] = 0;
            self.im[N / 2] = 0;
            for (1..N / 2) |k| {
                self.re[N - k] = self.re[k];
                self.im[N - k] = -self.im[k];
            }
            self.fft.inverse(&self.re, &self.im);
            for (0..N) |i| {
                self.out_ring[ch][(place + i) % OUT_CAP] += self.re[i] * self.window[i];
            }
        }
        for (0..N) |i| {
            const w = self.window[i];
            self.weight_ring[(place + i) % OUT_CAP] += w * w;
        }

        // 7. Finalize: samples before `place` receive no further contributions.
        var f = self.out_final_end;
        while (f < place) : (f += 1) {
            const idx = f % OUT_CAP;
            const w = @max(self.weight_ring[idx], 1e-3);
            for (0..self.channels) |ch| {
                self.out_ring[ch][idx] /= w;
            }
        }
        self.out_final_end = place;

        // 8. Roll state.
        for (0..self.channels) |ch| {
            @memcpy(&self.prev_phase[ch], &self.ph[ch]);
        }
        @memcpy(&self.prev_mag_mid, &self.mag_mid);
        self.last_place = place;
        self.started = true;
    }

    fn lockPhases(self: *PitchShifter, hs: f32) void {
        // Peak picking on the mid magnitude spectrum.
        var np: usize = 0;
        var k: usize = 2;
        while (k < HALF - 2) : (k += 1) {
            const m = self.mag_mid[k];
            if (m > PEAK_FLOOR and
                m > self.mag_mid[k - 1] and m > self.mag_mid[k - 2] and
                m >= self.mag_mid[k + 1] and m >= self.mag_mid[k + 2])
            {
                self.peaks[np] = @intCast(k);
                np += 1;
            }
        }

        if (np == 0) {
            for (0..self.channels) |ch| {
                @memcpy(&self.synth_phase[ch], &self.ph[ch]);
            }
            return;
        }

        // Regions of influence: each bin belongs to the nearest peak.
        var bin: usize = 0;
        for (0..np) |j| {
            const upper: usize = if (j + 1 < np)
                (self.peaks[j] + self.peaks[j + 1] + 1) / 2
            else
                HALF;
            while (bin < upper) : (bin += 1) {
                self.peak_of[bin] = self.peaks[j];
            }
        }

        for (0..self.channels) |ch| {
            // Advance each peak's synthesis phase by its instantaneous frequency.
            for (0..np) |j| {
                const pk = self.peaks[j];
                const bin_w = two_pi * @as(f32, @floatFromInt(pk)) / @as(f32, N);
                const expected = bin_w * @as(f32, HOP);
                const dev = wrapPhase(self.ph[ch][pk] - self.prev_phase[ch][pk] - expected);
                const omega = bin_w + dev / @as(f32, HOP);
                const new_synth = wrapPhase(self.synth_phase[ch][pk] + omega * hs);
                self.rot_buf[pk] = new_synth - self.ph[ch][pk];
            }
            // Identity phase locking: rotate every bin by its peak's rotation.
            for (0..HALF) |b| {
                self.synth_phase[ch][b] = wrapPhase(self.ph[ch][b] + self.rot_buf[self.peak_of[b]]);
            }
        }
    }

    fn zeroExtendOutput(self: *PitchShifter, need: usize) void {
        var z = self.out_zeroed_end;
        while (z < need) : (z += 1) {
            const idx = z % OUT_CAP;
            for (0..self.channels) |ch| self.out_ring[ch][idx] = 0;
            self.weight_ring[idx] = 0;
        }
        if (need > self.out_zeroed_end) self.out_zeroed_end = need;
    }

    fn produce(self: *PitchShifter, out_l: ?[*]f32, out_r: ?[*]f32, out_cap: usize) usize {
        const ol = out_l orelse return 0;
        var produced: usize = 0;
        const step = self.ratio;
        while (produced < out_cap) {
            const base_f = @floor(self.res_pos);
            const base: usize = @intFromFloat(@max(0.0, base_f));
            if (base + HTAPS + 1 > self.out_final_end) break;
            if (base < HTAPS) {
                ol[produced] = 0;
                if (out_r) |orr| orr[produced] = 0;
                produced += 1;
                self.res_pos += step;
                continue;
            }
            const frac = self.res_pos - base_f;
            const qf = frac * @as(f64, PHASES);
            const qi: usize = @intFromFloat(@floor(qf));
            const qfr: f32 = @floatCast(qf - @floor(qf));
            const row0 = &self.res_table[@min(qi, PHASES)];
            const row1 = &self.res_table[@min(qi + 1, PHASES)];
            const first = base - (HTAPS - 1);
            var acc_l: f32 = 0;
            var acc_r: f32 = 0;
            for (0..TAPS) |i| {
                const h = row0[i] * (1.0 - qfr) + row1[i] * qfr;
                const idx = (first + i) % OUT_CAP;
                acc_l += self.out_ring[0][idx] * h;
                if (self.channels == 2) acc_r += self.out_ring[1][idx] * h;
            }
            ol[produced] = acc_l;
            if (out_r) |orr| {
                orr[produced] = if (self.channels == 2) acc_r else acc_l;
            }
            produced += 1;
            self.res_pos += step;
        }
        return produced;
    }
};
