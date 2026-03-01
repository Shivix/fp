const std = @import("std");

const Allocator = std.mem.Allocator;

const SCORE_MAX = std.math.inf(f64);
const SCORE_MIN = -std.math.inf(f64);
const MATCH_MAX_LEN = 1024;

const SCORE_GAP_LEADING: f64 = -0.005;
const SCORE_GAP_TRAILING: f64 = -0.005;
const SCORE_GAP_INNER: f64 = -0.01;
const SCORE_MATCH_CONSECUTIVE: f64 = 1.0;
const SCORE_MATCH_SLASH: f64 = 0.9;
const SCORE_MATCH_WORD: f64 = 0.8;
const SCORE_MATCH_CAPITAL: f64 = 0.7;
const SCORE_MATCH_DOT: f64 = 0.6;

// bonus.h implementation
const bonus_states = init_bonus_states();
const bonus_index = init_bonus_index();

const Match = struct {
    needle_len: usize,
    haystack_len: usize,
    lower_needle: [MATCH_MAX_LEN]u8,
    lower_haystack: [MATCH_MAX_LEN]u8,
    match_bonus: [MATCH_MAX_LEN]f64,
};

fn init_bonus_states() [3][256]f64 {
    var states: [3][256]f64 = undefined;
    for (0..3) |i| {
        for (0..256) |j| {
            states[i][j] = 0;
        }
    }

    states[1]['/'] = SCORE_MATCH_SLASH;
    states[1]['-'] = SCORE_MATCH_WORD;
    states[1]['_'] = SCORE_MATCH_WORD;
    states[1][' '] = SCORE_MATCH_WORD;
    states[1]['.'] = SCORE_MATCH_DOT;

    states[2]['/'] = SCORE_MATCH_SLASH;
    states[2]['-'] = SCORE_MATCH_WORD;
    states[2]['_'] = SCORE_MATCH_WORD;
    states[2][' '] = SCORE_MATCH_WORD;
    states[2]['.'] = SCORE_MATCH_DOT;

    for ('a'..('z' + 1)) |c| {
        states[2][c] = SCORE_MATCH_CAPITAL;
    }

    return states;
}

fn init_bonus_index() [256]usize {
    var index: [256]usize = undefined;
    for (0..256) |i| {
        index[i] = 0;
    }

    for ('A'..('Z' + 1)) |c| {
        index[c] = 2;
    }
    for ('a'..('z' + 1)) |c| {
        index[c] = 1;
    }
    for ('0'..('9' + 1)) |c| {
        index[c] = 1;
    }
    return index;
}

fn compute_bonus(last_ch: u8, ch: u8) f64 {
    return bonus_states[bonus_index[ch]][last_ch];
}

fn strcasechr(s: []const u8, c: u8) ?usize {
    const lower_c = std.ascii.toLower(c);
    const upper_c = std.ascii.toUpper(c);
    for (s, 0..) |ch, i| {
        if (ch == lower_c or ch == upper_c) return i;
    }
    return null;
}

pub fn has_match(needle: []const u8, haystack: []const u8) bool {
    var h = haystack;
    for (needle) |c| {
        const found_idx = strcasechr(h, c) orelse return false;
        h = h[found_idx + 1 ..];
    }
    return true;
}

fn precompute_bonus(haystack: []const u8, match_bonus: []f64) void {
    var last_ch: u8 = '/';
    for (haystack, 0..) |ch, i| {
        match_bonus[i] = compute_bonus(last_ch, ch);
        last_ch = ch;
    }
}

fn new_match(needle: []const u8, haystack: []const u8) Match {
    var result: Match = undefined;
    result.needle_len = needle.len;
    result.haystack_len = haystack.len;

    if (result.haystack_len > MATCH_MAX_LEN) result.haystack_len = MATCH_MAX_LEN;
    if (result.needle_len > result.haystack_len) result.needle_len = result.haystack_len;

    for (needle[0..result.needle_len], 0..) |ch, i| {
        result.lower_needle[i] = std.ascii.toLower(ch);
    }
    for (haystack[0..result.haystack_len], 0..) |ch, i| {
        result.lower_haystack[i] = std.ascii.toLower(ch);
    }

    precompute_bonus(haystack[0..result.haystack_len], &result.match_bonus);
    return result;
}

fn match_row(m: *const Match, row: usize, len: usize, curr_D: []f64, curr_M: []f64, last_D: []const f64, last_M: []const f64) void {
    const n = m.needle_len;
    const i = row;

    var prev_score: f64 = SCORE_MIN;
    const gap_score: f64 = if (i == n - 1) SCORE_GAP_TRAILING else SCORE_GAP_INNER;

    for (0..len) |j| {
        if (m.lower_needle[i] == m.lower_haystack[j]) {
            var score: f64 = SCORE_MIN;
            if (i == 0) {
                score = (@as(f64, @floatFromInt(j)) * SCORE_GAP_LEADING) + m.match_bonus[j];
            } else if (j > 0) {
                const prev_M = last_M[j - 1];
                const prev_D = last_D[j - 1];
                score = @max(prev_M + m.match_bonus[j], prev_D + SCORE_MATCH_CONSECUTIVE);
            }

            curr_D[j] = score;
            prev_score = @max(score, prev_score + gap_score);
        } else {
            curr_D[j] = SCORE_MIN;
            prev_score = prev_score + gap_score;
        }
        curr_M[j] = prev_score;
    }
}

pub fn match(needle: []const u8, haystack: []const u8) f64 {
    const n = needle.len;
    const len = haystack.len;

    if (n == 0) return SCORE_MIN;
    if (len > MATCH_MAX_LEN or n > len) return SCORE_MIN;
    if (n == len) return SCORE_MAX;

    var m = new_match(needle, haystack);

    var D1: [MATCH_MAX_LEN]f64 = undefined;
    var M1: [MATCH_MAX_LEN]f64 = undefined;
    var D2: [MATCH_MAX_LEN]f64 = undefined;
    var M2: [MATCH_MAX_LEN]f64 = undefined;

    var last_D = &D1;
    var last_M = &M1;
    var curr_D = &D2;
    var curr_M = &M2;

    // First row
    match_row(&m, 0, len, curr_D, curr_M, last_D, last_M);

    for (1..n) |i| {
        // Swap
        const tmp_D = last_D;
        const tmp_M = last_M;
        last_D = curr_D;
        last_M = curr_M;
        curr_D = tmp_D;
        curr_M = tmp_M;

        match_row(&m, i, len, curr_D, curr_M, last_D, last_M);
    }

    return curr_M[len - 1];
}

pub fn match_positions(allocator: Allocator, needle: []const u8, haystack: []const u8, positions: []usize) !f64 {
    const n = needle.len;
    const len = haystack.len;

    if (n == 0) return SCORE_MIN;
    if (len > MATCH_MAX_LEN or n > len) return SCORE_MIN;

    if (n == len) {
        for (0..n) |i| {
            positions[i] = i;
        }
        return SCORE_MAX;
    }

    var m = new_match(needle, haystack);

    const size = n * len;
    const D_ptr = try allocator.alloc(f64, size);
    defer allocator.free(D_ptr);
    const M_ptr = try allocator.alloc(f64, size);
    defer allocator.free(M_ptr);

    match_row(&m, 0, len, D_ptr[0..len], M_ptr[0..len], D_ptr[0..len], M_ptr[0..len]);

    for (1..n) |i| {
        const curr_start = i * len;
        const prev_start = curr_start - len;
        match_row(&m, i, len, D_ptr[curr_start..][0..len], M_ptr[curr_start..][0..len], D_ptr[prev_start..][0..len], M_ptr[prev_start..][0..len]);
    }

    var match_required = false;
    var i: isize = @intCast(n - 1);
    var j: isize = @intCast(len - 1);

    while (i >= 0) : (i -= 1) {
        while (j >= 0) : (j -= 1) {
            const i_us: usize = @intCast(i);
            const j_us: usize = @intCast(j);
            const d_val = D_ptr[i_us * len + j_us];
            const m_val = M_ptr[i_us * len + j_us];

            if (d_val != SCORE_MIN and (match_required or d_val == m_val)) {
                if (i > 0 and j > 0) {
                    const prev_d = D_ptr[(i_us - 1) * len + (j_us - 1)];
                    match_required = (m_val == prev_d + SCORE_MATCH_CONSECUTIVE);
                } else {
                    match_required = false;
                }

                positions[i_us] = j_us;
                j -= 1;
                break;
            }
        }
    }

    return M_ptr[n * len - 1];
}

test "has_match" {
    const expect = std.testing.expect;
    try expect(has_match("a", "abc"));
    try expect(has_match("abc", "abc"));
    try expect(!has_match("ad", "abc"));
    try expect(has_match("ace", "abcde"));
    try expect(has_match("Ace", "aBCde"));
}

test "match scoring" {
    const expect = std.testing.expect;
    // Perfect match
    try expect(match("abc", "abc") == SCORE_MAX);
    // No match
    try expect(match("z", "abc") == SCORE_MIN);
    // Subsequence match
    const score1 = match("bar", "foobar");
    const score2 = match("foo", "foobar");
    try expect(score1 < score2); // "foo" at start is better than "bar" at end
}
