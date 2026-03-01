const std = @import("std");
const posix = std.posix;
const Io = std.Io;

pub const Colour = enum(c_int) {
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
    normal = 39,

    brred = 91,
    brgreen = 92,
    bryellow = 93,
    brblue = 94,
    brmagenta = 95,
    brcyan = 96,
    brwhite = 97,
};

pub const Tty = struct {
    fdin: Io.File,
    fout: Io.File,
    original_termios: posix.termios,
    fgcolor: Colour,
    maxwidth: usize,
    maxheight: usize,

    buf: [8192]u8,
    writer: Io.File.Writer,

    pub fn close(self: *Tty, io: Io) void {
        posix.tcsetattr(self.fdin.handle, .NOW, self.original_termios) catch {};
        self.fout.close(io);
        self.fdin.close(io);
    }

    pub fn init(self: *Tty, io: Io, tty_filename: []const u8) !void {
        self.fdin = try Io.Dir.openFileAbsolute(io, tty_filename, .{ .mode = .read_only });
        errdefer self.fdin.close(io);

        self.fout = try Io.Dir.openFileAbsolute(io, tty_filename, .{ .mode = .write_only });
        errdefer self.fout.close(io);

        self.original_termios = try posix.tcgetattr(self.fdin.handle);

        var new_termios = self.original_termios;

        new_termios.iflag.ISTRIP = false;
        new_termios.iflag.ICRNL = false;
        new_termios.lflag.ICANON = false;
        new_termios.lflag.ECHO = false;
        new_termios.lflag.ISIG = false;

        try posix.tcsetattr(self.fdin.handle, .NOW, new_termios);

        self.getwinsz();
        self.fgcolor = Colour.normal;
        self.writer = self.fout.writer(io, &self.buf);
    }

    pub fn getwinsz(self: *Tty) void {
        var ws: posix.winsize = undefined;
        const err = posix.system.ioctl(self.fout.handle, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (err == -1) {
            self.maxwidth = 80;
            self.maxheight = 25;
        } else {
            self.maxwidth = ws.col;
            self.maxheight = ws.row;
        }
    }

    pub fn getchar(self: *Tty, io: Io) !u8 {
        var reader_buf: [1]u8 = undefined;
        var r = self.fdin.reader(io, &reader_buf);
        return try r.interface.takeByte();
    }

    pub fn input_ready(self: *Tty, timeout_ms: c_long) bool {
        var fds = [1]posix.pollfd{.{
            .fd = self.fdin.handle,
            .events = posix.POLL.IN,
            .revents = 0,
        }};

        const count = posix.poll(&fds, @intCast(timeout_ms)) catch |err| {
            if (err == error.Interrupted) return false;
            std.debug.print("poll failed: {}\n", .{err});
            std.process.exit(1);
        };

        return count > 0 and (fds[0].revents & posix.POLL.IN != 0);
    }

    pub fn set_fg(self: *Tty, fg: Colour) !void {
        if (self.fgcolor != fg) {
            try self.print("\x1b[{d}m", .{@intFromEnum(fg)});
            self.fgcolor = fg;
        }
    }

    pub fn set_invert(self: *Tty) !void {
        try self.print("\x1b[7m", .{});
    }

    pub fn set_underline(self: *Tty) !void {
        try self.print("\x1b[4m", .{});
    }

    pub fn reset_style(self: *Tty) !void {
        try self.print("\x1b[0m", .{});
        self.fgcolor = Colour.normal;
    }

    pub fn set_nowrap(self: *Tty) !void {
        try self.print("\x1b[?7l", .{});
    }

    pub fn set_wrap(self: *Tty) !void {
        try self.print("\x1b[?7h", .{});
    }

    pub fn newline(self: *Tty) !void {
        try self.print("\x1b[K\n", .{});
    }

    pub fn clear_line(self: *Tty) !void {
        try self.print("\x1b[K", .{});
    }

    pub fn reset_col(self: *Tty) !void {
        try self.print("\x1b[1G", .{});
    }

    pub fn cursor_up(self: *Tty, i: c_int) !void {
        try self.print("\x1b[{d}A", .{i});
    }

    pub fn hide_cursor(self: *Tty) !void {
        try self.print("\x1b[?25l", .{});
    }

    pub fn show_cursor(self: *Tty) !void {
        try self.print("\x1b[?25h", .{});
    }

    pub fn print(self: *Tty, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.interface.print(fmt, args);
    }

    pub fn putc(self: *Tty, c: u8) !void {
        try self.writer.interface.writeByte(c);
    }

    pub fn flush(self: *Tty) !void {
        try self.writer.interface.flush();
    }
};
