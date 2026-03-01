const std = @import("std");
const match_mod = @import("match.zig");

const has_match = match_mod.has_match;
const match = match_mod.match;

const ScoredResult = struct {
    score: f64,
    str: []const u8,
    selected: bool = false,
};

pub const SearchResults = std.ArrayList(ScoredResult);

pub const Choices = struct {
    // buffer holds the raw character data for all choices
    buffer: std.ArrayList(u8),
    strings: std.ArrayList([]const u8),

    pub fn empty() Choices {
        return .{
            .buffer = .empty,
            .strings = .empty,
        };
    }

    pub fn deinit(self: *Choices, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
        self.strings.deinit(allocator);
    }

    pub fn read_input(self: *Choices, reader: *std.Io.Reader, input_delimiter: u8, allocator: std.mem.Allocator) !void {
        var line_idx = self.buffer.items.len;

        try reader.appendRemaining(allocator, &self.buffer, .unlimited);

        const line_end = self.buffer.items.len;
        while (line_idx < line_end) {
            const delimiter_idx = std.mem.indexOfScalarPos(
                u8,
                self.buffer.items,
                line_idx,
                input_delimiter,
            ) orelse {
                if (line_idx < line_end) {
                    const slice = self.buffer.items[line_idx..line_end];
                    try self.strings.append(allocator, slice);
                }
                break;
            };

            if (line_idx < delimiter_idx) {
                const slice = self.buffer.items[line_idx..delimiter_idx];
                try self.strings.append(allocator, slice);
            }
            line_idx = delimiter_idx + 1;
        }
    }

    pub fn search(self: *Choices, search_str: []const u8, allocator: std.mem.Allocator) !SearchResults {
        var list: std.ArrayList(ScoredResult) = .empty;
        errdefer list.deinit(allocator);

        for (self.strings.items) |candidate| {
            if (score_candidate(search_str, candidate)) |result| {
                try list.append(allocator, result);
            }
        }

        std.sort.block(ScoredResult, list.items, {}, compare_scores);

        return list;
    }
};

fn compare_scores(_: void, a: ScoredResult, b: ScoredResult) bool {
    if (a.score == b.score) {
        return @intFromPtr(a.str.ptr) < @intFromPtr(b.str.ptr);
    }
    return a.score > b.score;
}

fn score_candidate(search_str: []const u8, str: []const u8) ?ScoredResult {
    if (!has_match(search_str, str)) {
        return null;
    }

    return .{
        .score = match(search_str, str),
        .str = str,
    };
}

fn add_test_choices(choices: *Choices, allocator: std.mem.Allocator) !void {
    try choices.strings.append(allocator, "foo");
    try choices.strings.append(allocator, "bar");
    try choices.strings.append(allocator, "baz");
    try choices.strings.append(allocator, "foobar");
    try choices.strings.append(allocator, "zap");
}

test "search empty query returns all choices" {
    const alloc = std.testing.allocator;
    var choices = Choices.empty();
    defer choices.deinit(alloc);
    try add_test_choices(&choices, alloc);

    var results = try choices.search("", alloc);
    defer results.deinit(alloc);

    try std.testing.expectEqual(5, choices.strings.items.len);
}

test "search no matches returns empty" {
    const alloc = std.testing.allocator;
    var choices = Choices.empty();
    defer choices.deinit(alloc);
    try add_test_choices(&choices, alloc);

    var results = try choices.search("qqqq", alloc);
    defer results.deinit(alloc);
}

test "search returns sorted matches" {
    const alloc = std.testing.allocator;
    var choices = Choices.empty();
    defer choices.deinit(alloc);
    try add_test_choices(&choices, alloc);

    var results = try choices.search("ba", alloc);
    defer results.deinit(alloc);

    try std.testing.expect(std.mem.eql(u8, results.items[0].str, "bar"));
    try std.testing.expect(std.mem.eql(u8, results.items[1].str, "baz"));
    try std.testing.expect(std.mem.eql(u8, results.items[2].str, "foobar"));
    try std.testing.expect(results.items[0].score >= results.items[1].score);
    try std.testing.expect(results.items[1].score >= results.items[2].score);
}
