const std = @import("std");

const DEFAULT_TTY = "/dev/tty";
const DEFAULT_PROMPT = "> ";
const DEFAULT_NUM_LINES: u32 = 10;

pub const VERSION = "1.0";

pub const Options = struct {
    filter_scores: bool = false,
    input_delimiter: u8 = '\n',
    lines: u32 = DEFAULT_NUM_LINES,
    prompt: []const u8 = DEFAULT_PROMPT,
    query: ?[]const u8 = null,
    show_info: bool = false,
    show_matches: ?[]const u8 = null,
    show_scores: bool = false,
    tty_filename: []const u8 = DEFAULT_TTY,

    pub fn parse(args: std.process.Args) !Options {
        var result = Options{};

        var args_iter = args.iterate();
        defer args_iter.deinit();

        // Skip executable name
        _ = args_iter.next();

        while (args_iter.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--")) {
                result.handle_long_opt(&args_iter, arg) catch |err| {
                    try handle_option_error(arg, err);
                };
            } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
                result.handle_short_opt(&args_iter, arg) catch |err| {
                    try handle_option_error(arg, err);
                };
            } else {
                return error.InvalidOption;
            }
        }
        return result;
    }

    fn required_value(args_iter: *std.process.Args.Iterator, inline_value: ?[]const u8) ![]const u8 {
        if (inline_value) |value| return value;
        return args_iter.next() orelse error.MissingArgument;
    }

    fn parseLines(input: []const u8) !u32 {
        const result = std.fmt.parseInt(u32, input, 10) catch {
            return error.InvalidArgument;
        };
        if (result < 1) {
            return error.InvalidArgument;
        }
        return result;
    }

    fn split_long_option(arg: []const u8) struct {
        name: []const u8,
        value: ?[]const u8,
    } {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return .{ .name = arg, .value = null };
        return .{
            .name = arg[0..eq],
            .value = arg[eq + 1 ..],
        };
    }

    fn handle_long_opt(self: *Options, args_iter: *std.process.Args.Iterator, full_arg: []const u8) !void {
        // Strip --
        const arg = full_arg[2..];
        const parsed = split_long_option(arg);
        if (std.mem.eql(u8, parsed.name, "version")) {
            std.debug.print("fp {s}\n", .{VERSION});
            std.process.exit(0);
        } else if (std.mem.eql(u8, parsed.name, "help")) {
            usage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, parsed.name, "filter-scores")) {
            self.filter_scores = true;
        } else if (std.mem.eql(u8, parsed.name, "read-null")) {
            self.input_delimiter = 0;
        } else if (std.mem.eql(u8, parsed.name, "show-scores")) {
            self.show_scores = true;
        } else if (std.mem.eql(u8, parsed.name, "show-info")) {
            self.show_info = true;
        } else if (std.mem.eql(u8, parsed.name, "lines")) {
            const value = try required_value(args_iter, parsed.value);
            self.lines = try parseLines(value);
        } else if (std.mem.eql(u8, parsed.name, "prompt")) {
            self.prompt = try required_value(args_iter, parsed.value);
        } else if (std.mem.eql(u8, parsed.name, "query")) {
            self.query = try required_value(args_iter, parsed.value);
        } else if (std.mem.eql(u8, parsed.name, "show-matches")) {
            self.show_matches = try required_value(args_iter, parsed.value);
        } else if (std.mem.eql(u8, parsed.name, "tty")) {
            self.tty_filename = try required_value(args_iter, parsed.value);
        } else {
            handle_option_error(arg, error.InvalidOption);
        }
    }

    fn short_option_value(args_iter: *std.process.Args.Iterator, arg: []const u8, position: usize) ![]const u8 {
        if (position + 1 < arg.len) {
            return arg[position + 1 ..];
        }
        return args_iter.next() orelse error.MissingArgument;
    }

    fn handle_short_opt(self: *Options, args_iter: *std.process.Args.Iterator, arg: []const u8) !void {
        var char_idx: usize = 1;
        while (char_idx < arg.len) : (char_idx += 1) {
            const c = arg[char_idx];
            switch (c) {
                'v' => {
                    std.debug.print("fp {s}\n", .{VERSION});
                    std.process.exit(0);
                },
                'f' => self.filter_scores = true,
                's' => self.show_scores = true,
                '0' => self.input_delimiter = 0,
                'i' => self.show_info = true,
                'h' => {
                    usage();
                    std.process.exit(0);
                },
                'q' => {
                    const val = try short_option_value(args_iter, arg, char_idx);
                    self.query = val;
                    break;
                },
                'e' => {
                    const val = try short_option_value(args_iter, arg, char_idx);
                    self.show_matches = val;
                    break;
                },
                'l' => {
                    const val = try short_option_value(args_iter, arg, char_idx);
                    self.lines = try parseLines(val);
                    break;
                },
                't' => {
                    const val = try short_option_value(args_iter, arg, char_idx);
                    self.tty_filename = val;
                    break;
                },
                'p' => {
                    const val = try short_option_value(args_iter, arg, char_idx);
                    self.prompt = val;
                    break;
                },
                else => {
                    return error.InvalidOption;
                },
            }
        }
    }
};

const usage_str =
    \\Usage: fp [OPTION]...
    \\ -l, --lines=LINES        Specify how many lines of results to show (default 10)
    \\ -p, --prompt=PROMPT      Input prompt (default '> ')
    \\ -q, --query=QUERY        Use QUERY as the initial search string
    \\ -e, --show-matches=QUERY Output the sorted matches of QUERY
    \\ -t, --tty=TTY            Specify file to use as TTY device (default /dev/tty)
    \\ -f, --filter-scores      Filter scores that are over 1 point away from top
    \\ -s, --show-scores        Show the scores of each match
    \\ -0, --read-null          Read input delimited by ASCII NUL characters
    \\ -i, --show-info          Show selection info line
    \\ -h, --help               Display this help and exit
    \\ -v, --version            Output version information and exit
;

fn usage() void {
    // TODO: usage on --help should go to stdout.
    std.debug.print("{s}", .{usage_str});
}

fn handle_option_error(opt: []const u8, err: anyerror) noreturn {
    switch (err) {
        error.InvalidOption => {
            std.debug.print("Invalid option: {s}\n", .{opt});
        },
        error.MissingArgument => {
            std.debug.print("Missing argument for option: {s}\n", .{opt});
        },
        error.InvalidArgument => {
            std.debug.print("Invalid value for option: {s}\n", .{opt});
        },
        else => {
            std.debug.print("Error parsing option {s}: {s}\n", .{ opt, @errorName(err) });
        },
    }
    std.process.exit(1);
}
