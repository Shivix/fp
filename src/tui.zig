const std = @import("std");
const builtin = @import("builtin");
const options_mod = @import("options.zig");
const choices_mod = @import("choices.zig");
const tty_mod = @import("tty.zig");
const match_mod = @import("match.zig");

pub const Tty = tty_mod.Tty;
pub const ANSICode = tty_mod.ANSICode;

const Options = options_mod.Options;
const Choices = choices_mod.Choices;
const SearchResults = choices_mod.SearchResults;

const SEARCH_SIZE_MAX = 4096;
const KEYTIMEOUT: u32 = 25;
const TTY_COLOR_HIGHLIGHT = tty_mod.Colour.yellow;
const TTY_COLOR_NORMAL = tty_mod.Colour.normal;
const MATCH_MAX_LEN = 1024;
const SCORE_MIN = -std.math.inf(f64);
const SCROLL_OFFSET = 1;

const match_positions = match_mod.match_positions;

pub const Tui = struct {
    tty: *Tty,
    allocator: std.mem.Allocator,
    choices: *Choices,
    io: std.Io,

    search: [SEARCH_SIZE_MAX + 1]u8,
    last_search: [SEARCH_SIZE_MAX + 1]u8,
    cursor: usize,
    results: SearchResults,
    selection: usize,

    max_lines: usize,
    prompt: []const u8,
    show_info: bool,
    show_scores: bool,

    // Used for combination keybinds (e.g. ctrl + w)
    ambiguous_key_pending: bool,
    input: [32]u8,

    exit: ?c_int,

    pub fn init(self: *Tui, tty: *Tty, choices: *Choices, options: Options, io: std.Io, allocator: std.mem.Allocator) !void {
        self.tty = tty;
        self.allocator = allocator;
        self.choices = choices;
        self.io = io;

        self.search[0] = 0;
        self.last_search[0] = 0;
        self.results = SearchResults.empty;
        self.selection = 0;

        self.max_lines = clamped_lines(options, choices, tty);
        self.prompt = options.prompt;
        self.show_info = options.show_info;
        self.show_scores = options.show_scores;

        self.ambiguous_key_pending = false;
        self.input[0] = 0;

        self.exit = null;

        if (options.query) |query| {
            const len = @min(query.len, SEARCH_SIZE_MAX);
            @memcpy(self.search[0..len], query[0..len]);
            self.search[len] = 0;
        }

        self.cursor = std.mem.len(@as([*:0]const u8, @ptrCast(&self.search)));
        update_search(self);
    }

    pub fn deinit(self: *Tui) void {
        self.results.deinit(self.allocator);
    }
};

fn isprint_unicode(c: u8) bool {
    return std.ascii.isPrint(c) or (c & (1 << 7) != 0);
}

fn is_boundary(c: u8) bool {
    return (~c & (1 << 7) != 0) or (c & (1 << 6) != 0);
}

fn clear(tui: *Tui) !void {
    const tty = tui.tty;

    try tty.reset_col();
    var line: usize = 0;
    const limit = tui.max_lines + (if (tui.show_info) @as(usize, 1) else 0);
    while (line < limit) {
        line += 1;
        try tty.newline();
    }
    try tty.clear_line();
    if (tui.max_lines > 0 or tui.show_info) {
        try tty.cursor_up(@intCast(line));
    }
    try tty.flush();
}

fn draw_match(tui: *Tui, choice: []const u8, selected: bool, current: bool) !void {
    const tty = tui.tty;
    const search_ptr = &tui.last_search;

    var positions: [MATCH_MAX_LEN]usize = undefined;
    for (0..MATCH_MAX_LEN) |i| {
        positions[i] = std.math.maxInt(usize);
    }

    const search_slice = std.mem.span(@as([*:0]const u8, @ptrCast(search_ptr)));
    const score = if (search_slice.len > 0)
        match_positions(tui.allocator, search_slice, choice, positions[0..search_slice.len]) catch SCORE_MIN
    else
        SCORE_MIN;

    if (selected) {
        try tty.print("* ", .{});
    }

    if (tui.show_scores) {
        try tty.print("{d:.3} | ", .{score});
    }

    if (current) {
        try tty.set_invert();
    }
    try tty.set_nowrap();

    var p: usize = 0;
    for (choice, 0..) |c, i| {
        if (p < search_slice.len and positions[p] == i) {
            try tty.set_fg(TTY_COLOR_HIGHLIGHT);
            p += 1;
        } else {
            try tty.set_fg(tty_mod.Colour.normal);
        }
        if (c == '\n') {
            try tty.putc(' ');
        } else {
            try tty.print("{c}", .{c});
        }
    }
    try tty.set_wrap();
    try tty.reset_style();
}

fn draw(tui: *Tui) !void {
    const tty = tui.tty;
    const choices = tui.choices;

    var start: usize = 0;
    const current_selection = tui.selection;
    const available = tui.results.items.len;

    if (current_selection + SCROLL_OFFSET >= tui.max_lines) {
        start = current_selection + SCROLL_OFFSET - tui.max_lines + 1;
        if (start + tui.max_lines >= available and available > 0) {
            start = available - tui.max_lines;
        }
    }

    try tty.hide_cursor();
    try tty.reset_col();
    try tty.print("{s}{s}", .{ tui.prompt, std.mem.span(@as([*:0]const u8, @ptrCast(&tui.search))) });
    try tty.clear_line();

    if (tui.show_info) {
        try tty.print("\n[{d}/{d}]", .{ available, choices.strings.items.len });
        try tty.clear_line();
    }

    var i = start;
    while (i < start + tui.max_lines) : (i += 1) {
        try tty.print("\n", .{});
        try tty.clear_line();
        if (i < available) {
            try draw_match(tui, tui.results.items[i].str, tui.results.items[i].selected, i == tui.selection);
        }
    }

    if (tui.max_lines + (if (tui.show_info) @as(u32, 1) else 0) > 0) {
        try tty.cursor_up(@intCast(tui.max_lines + (if (tui.show_info) @as(u32, 1) else 0)));
    }

    try tty.reset_col();
    try tty.print("{s}", .{tui.prompt});

    for (0..tui.cursor) |k| {
        try tty.putc(tui.search[k]);
    }
    try tty.show_cursor();
    try tty.flush();
}

fn update_search(tui: *Tui) void {
    const new_results = tui.choices.search(std.mem.span(@as([*:0]const u8, @ptrCast(&tui.search))), tui.allocator) catch |err| {
        std.debug.print("Search failed: {}\n", .{err});
        std.process.exit(1);
    };
    tui.results.deinit(tui.allocator);
    tui.results = new_results;
    tui.selection = 0;

    const search_len = std.mem.len(@as([*:0]const u8, @ptrCast(&tui.search)));
    @memcpy(tui.last_search[0..search_len], tui.search[0..search_len]);
    tui.last_search[search_len] = 0;
}

fn update_state(tui: *Tui) !void {
    const search_slice = std.mem.span(@as([*:0]const u8, @ptrCast(&tui.search)));
    const last_search_slice = std.mem.span(@as([*:0]const u8, @ptrCast(&tui.last_search)));
    if (!std.mem.eql(u8, search_slice, last_search_slice)) {
        update_search(tui);
        try draw(tui);
    }
}

fn action_select(tui: *Tui) !void {
    try update_state(tui);
    try clear(tui);

    if (tui.selection >= tui.results.items.len) {
        tui.exit = 1;
        return;
    }

    var out_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(tui.io, &out_buf);

    var selection_exists = false;
    for (tui.results.items) |result| {
        if (result.selected) {
            selection_exists = true;
            try stdout.interface.print("{s}\n", .{result.str});
        }
    }

    if (!selection_exists) {
        try stdout.interface.print("{s}\n", .{tui.results.items[tui.selection].str});
    }
    try stdout.interface.flush();
    tui.exit = 0;
}

fn action_del_char(tui: *Tui) !void {
    const length = std.mem.len(@as([*:0]const u8, @ptrCast(&tui.search)));
    if (tui.cursor == 0) return;

    const original_cursor = tui.cursor;

    tui.cursor -= 1;
    while (tui.cursor > 0 and !is_boundary(tui.search[tui.cursor])) {
        tui.cursor -= 1;
    }

    const dist = length - original_cursor + 1;
    std.mem.copyForwards(u8, tui.search[tui.cursor..], tui.search[original_cursor..][0..dist]);
}

fn action_del_word(tui: *Tui) !void {
    const original_cursor = tui.cursor;
    var cursor = tui.cursor;

    while (cursor > 0 and std.ascii.isWhitespace(tui.search[cursor - 1])) {
        cursor -= 1;
    }
    while (cursor > 0 and !std.ascii.isWhitespace(tui.search[cursor - 1])) {
        cursor -= 1;
    }

    const length = std.mem.len(@as([*:0]const u8, @ptrCast(&tui.search)));
    const dist = length - original_cursor + 1;
    std.mem.copyForwards(u8, tui.search[cursor..], tui.search[original_cursor..][0..dist]);
    tui.cursor = cursor;
}

fn action_del_all(tui: *Tui) !void {
    const length = std.mem.len(@as([*:0]const u8, @ptrCast(&tui.search)));
    const dist = length - tui.cursor + 1;
    std.mem.copyForwards(u8, tui.search[0..], tui.search[tui.cursor..][0..dist]);
    tui.cursor = 0;
}

fn action_prev(tui: *Tui) !void {
    try update_state(tui);
    const available = tui.results.items.len;
    if (available > 0) {
        tui.selection = (tui.selection + available - 1) % available;
    }
}

fn action_next(tui: *Tui) !void {
    try update_state(tui);
    const available = tui.results.items.len;
    if (available > 0) {
        tui.selection = (tui.selection + 1) % available;
    }
}

fn action_left(tui: *Tui) !void {
    if (tui.cursor > 0) {
        tui.cursor -= 1;
        while (tui.cursor > 0 and !is_boundary(tui.search[tui.cursor])) {
            tui.cursor -= 1;
        }
    }
}

fn action_right(tui: *Tui) !void {
    const length = std.mem.len(@as([*:0]const u8, @ptrCast(&tui.search)));
    if (tui.cursor < length) {
        tui.cursor += 1;
        while (tui.cursor < length and !is_boundary(tui.search[tui.cursor])) {
            tui.cursor += 1;
        }
    }
}

fn action_beginning(tui: *Tui) !void {
    tui.cursor = 0;
}

fn action_end(tui: *Tui) !void {
    tui.cursor = std.mem.len(@as([*:0]const u8, @ptrCast(&tui.search)));
}

fn action_pageup(tui: *Tui) !void {
    try update_state(tui);
    var i: usize = 0;
    while (i < tui.max_lines and tui.selection > 0) : (i += 1) {
        tui.selection -= 1;
    }
}

fn action_pagedown(tui: *Tui) !void {
    try update_state(tui);
    const available = tui.results.items.len;
    var i: usize = 0;
    while (i < tui.max_lines and available > 0 and tui.selection < available - 1) : (i += 1) {
        tui.selection += 1;
    }
}

fn action_exit(tui: *Tui) !void {
    try clear(tui);
    tui.exit = 1;
}

fn action_ctrl_c(tui: *Tui) !void {
    try action_exit(tui);
    tui.exit = 130;
}

fn action_select_match(tui: *Tui) !void {
    const i = tui.selection;
    tui.results.items[i].selected = !tui.results.items[i].selected;
    try action_next(tui);
}

fn action_ignore(_: *Tui) !void {}

fn append_search(tui: *Tui, ch: u8) void {
    const length = std.mem.len(@as([*:0]const u8, @ptrCast(&tui.search)));
    if (length < SEARCH_SIZE_MAX) {
        const dist = length - tui.cursor + 1;
        std.mem.copyBackwards(u8, tui.search[tui.cursor + 1 ..], tui.search[tui.cursor..][0..dist]);
        tui.search[tui.cursor] = ch;
        tui.cursor += 1;
    }
}

fn clamped_lines(options: Options, choices: *Choices, tty: *Tty) u32 {
    var lines = options.lines;
    if (lines > choices.strings.items.len) {
        lines = @intCast(choices.strings.items.len);
    }
    var num_lines_adjustment: u32 = 1;
    if (options.show_info) {
        num_lines_adjustment += 1;
    }
    if (lines + num_lines_adjustment > tty.maxheight) {
        lines = @intCast(tty.maxheight - num_lines_adjustment);
    }
    return lines;
}

const KeyBinding = struct {
    key: []const u8,
    action: *const fn (*Tui) anyerror!void,
};

fn CTRL(comptime key: u8) []const u8 {
    return &[_]u8{key - '@'};
}

const keybindings = [_]KeyBinding{
    .{ .key = "\x1b", .action = action_exit },
    .{ .key = "\x7f", .action = action_del_char },
    .{ .key = CTRL('W'), .action = action_del_word },
    .{ .key = CTRL('U'), .action = action_del_all },
    // Tab also
    .{ .key = CTRL('I'), .action = action_select_match },
    .{ .key = CTRL('C'), .action = action_ctrl_c },
    .{ .key = CTRL('D'), .action = action_exit },
    .{ .key = CTRL('G'), .action = action_exit },
    // Enter also
    .{ .key = CTRL('M'), .action = action_select },
    .{ .key = CTRL('P'), .action = action_prev },
    .{ .key = CTRL('N'), .action = action_next },
    .{ .key = CTRL('K'), .action = action_prev },
    .{ .key = CTRL('J'), .action = action_next },

    .{ .key = "\x1bOD", .action = action_left },
    .{ .key = "\x1b[D", .action = action_left },
    .{ .key = "\x1bOC", .action = action_right },
    .{ .key = "\x1b[C", .action = action_right },
    .{ .key = "\x1b[1~", .action = action_beginning },
    .{ .key = "\x1b[H", .action = action_beginning },
    .{ .key = "\x1b[4~", .action = action_end },
    .{ .key = "\x1b[F", .action = action_end },
    .{ .key = "\x1b[A", .action = action_prev },
    .{ .key = "\x1bOA", .action = action_prev },
    .{ .key = "\x1b[B", .action = action_next },
    .{ .key = "\x1bOB", .action = action_next },
    .{ .key = "\x1b[5~", .action = action_pageup },
    .{ .key = "\x1b[6~", .action = action_pagedown },
    .{ .key = "\x1b[200~", .action = action_ignore },
    .{ .key = "\x1b[201~", .action = action_ignore },
};

fn handle_input(tui: *Tui, c: u8, handle_ambiguous_key: bool) !void {
    tui.ambiguous_key_pending = false;

    const input_len = std.mem.len(@as([*:0]const u8, @ptrCast(&tui.input)));
    if (input_len + 1 < 32) {
        tui.input[input_len] = c;
        tui.input[input_len + 1] = 0;
    }

    const input_slice = std.mem.span(@as([*:0]const u8, @ptrCast(&tui.input)));

    var found_keybinding: ?usize = null;
    var in_middle = false;

    for (keybindings, 0..) |kb, i| {
        if (std.mem.eql(u8, input_slice, kb.key)) {
            found_keybinding = i;
        } else if (std.mem.startsWith(u8, kb.key, input_slice)) {
            in_middle = true;
        }
    }

    if (found_keybinding != null and (!in_middle or handle_ambiguous_key)) {
        try keybindings[found_keybinding.?].action(tui);
        tui.input[0] = 0;
        return;
    }

    if (found_keybinding != null and in_middle) {
        tui.ambiguous_key_pending = true;
        return;
    }

    if (in_middle) return;

    for (input_slice) |ch| {
        if (isprint_unicode(ch)) {
            append_search(tui, ch);
        }
    }
    tui.input[0] = 0;
}

pub fn run(tui: *Tui) !c_int {
    try draw(tui);

    while (true) {
        while (true) {
            const c = try tui.tty.getchar(tui.io);
            try handle_input(tui, c, false);

            if (tui.exit) |exit_code| {
                return exit_code;
            }
            try draw(tui);

            if (!tui.tty.input_ready(if (tui.ambiguous_key_pending) KEYTIMEOUT else 0)) {
                break;
            }
        }

        if (tui.ambiguous_key_pending) {
            try handle_input(tui, 0, true);

            if (tui.exit) |exit_code| {
                return exit_code;
            }
        }
        try update_state(tui);
    }
}
