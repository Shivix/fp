const std = @import("std");
const options_mod = @import("options.zig");
const choices_mod = @import("choices.zig");
const tui_mod = @import("tui.zig");
const tty_mod = @import("tty.zig");

const Tty = tty_mod.Tty;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    const options = try options_mod.Options.parse(init.minimal.args);

    var choices = choices_mod.Choices.empty();
    defer choices.deinit(allocator);

    const stdin = std.Io.File.stdin();
    var reader_buf: [4096]u8 = undefined;
    var reader = stdin.reader(io, &reader_buf);

    if (options.show_matches) |pattern| {
        try choices.read_input(&reader.interface, options.input_delimiter, allocator);
        var results = try choices.search(pattern, allocator);
        defer results.deinit(allocator);

        var out_buf: [1024]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &out_buf);

        const top_score = if (results.items.len > 0) results.items[0].score else null;
        for (results.items) |match| {
            if (options.filter_scores) {
                if (match.score < top_score.? - 1) {
                    break;
                }
            }
            if (options.show_scores) {
                try stdout.interface.print("{d:.3}\t", .{match.score});
            }
            try stdout.interface.print("{s}\n", .{match.str});
        }
        try stdout.interface.flush();
        return 0;
    }

    const stdin_is_tty = stdin.isTty(io) catch false;
    if (stdin_is_tty) {
        try choices.read_input(&reader.interface, options.input_delimiter, allocator);
    }

    var tty: Tty = undefined;
    try tty.init(io, options.tty_filename);
    defer tty.close(io);

    if (!stdin_is_tty) {
        try choices.read_input(&reader.interface, options.input_delimiter, allocator);
    }

    var tui: tui_mod.Tui = undefined;
    try tui.init(&tty, &choices, options, io, allocator);
    defer tui.deinit();

    return @intCast(try tui_mod.run(&tui));
}
