const std = @import("std");
const serialport = @import("../serialport.zig");
const c = @cImport({
    @cInclude("termios.h");
});

pub fn open(path: []const u8) !std.fs.File {
    var result = try std.fs.cwd().openFile(path, .{
        .mode = .read_write,
        .allow_ctty = false,
    });
    errdefer result.close();

    var fl_flags = try std.posix.fcntl(result.handle, std.posix.F.GETFL, 0);
    fl_flags |= @as(usize, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));
    _ = try std.posix.fcntl(result.handle, std.posix.F.SETFL, fl_flags);
    return result;
}

pub fn configure(
    port: std.fs.File,
    config: serialport.Config,
) !std.posix.termios {
    if (config.parity == .mark or config.parity == .space)
        return error.ParityMarkSpaceUnsupported;

    var settings = try std.posix.tcgetattr(port.handle);
    const orig_termios = settings;

    c.cfmakeraw(@ptrCast(&settings));

    if (config.input_baud_rate) |ibr| {
        switch (std.posix.errno(
            c.cfsetospeed(@ptrCast(&settings), @intFromEnum(config.baud_rate)),
        )) {
            .SUCCESS => {},
            else => |err| return std.posix.unexpectedErrno(err),
        }
        switch (std.posix.errno(
            c.cfsetispeed(@ptrCast(&settings), @intFromEnum(ibr)),
        )) {
            .SUCCESS => {},
            else => |err| return std.posix.unexpectedErrno(err),
        }
    } else {
        switch (std.posix.errno(
            c.cfsetspeed(@ptrCast(&settings), @intFromEnum(config.baud_rate)),
        )) {
            .SUCCESS => {},
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }

    configureParity(&settings, config.parity);
    configureFlowControl(&settings, config.flow_control);

    settings.cflag.CREAD = true;
    settings.cflag.CSTOPB = config.stop_bits == .two;
    settings.cflag.CSIZE = @enumFromInt(@intFromEnum(config.data_bits));

    // Minimum arrived bytes before read returns.
    settings.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    // Inter-byte timeout before read returns.
    settings.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    settings.cc[@intFromEnum(std.posix.V.START)] = 0x11;
    settings.cc[@intFromEnum(std.posix.V.STOP)] = 0x13;

    try std.posix.tcsetattr(port.handle, .NOW, settings);
    return orig_termios;
}

pub fn configureParity(
    termios: *std.posix.termios,
    parity: serialport.Config.Parity,
) void {
    termios.cflag.PARENB = parity != .none;
    termios.cflag.PARODD = parity == .odd;

    termios.iflag.INPCK = parity != .none;
    termios.iflag.IGNPAR = parity == .none;
}

pub fn configureFlowControl(
    termios: *std.posix.termios,
    flow_control: serialport.Config.FlowControl,
) void {
    termios.cflag.CLOCAL = flow_control == .none;
    termios.cflag.CCTS_OFLOW = flow_control == .hardware;
    termios.cflag.CRTS_IFLOW = flow_control == .hardware;

    termios.iflag.IXANY = flow_control == .software;
    termios.iflag.IXON = flow_control == .software;
    termios.iflag.IXOFF = flow_control == .software;
}

pub fn flush(port: std.fs.File, options: serialport.FlushOptions) !void {
    if (!options.input and !options.output) return;
    const result = c.tcflush(
        port.handle,
        if (options.input and options.output)
            c.TCIOFLUSH
        else if (options.input)
            c.TCIFLUSH
        else
            c.TCOFLUSH,
    );
    return switch (std.posix.errno(result)) {
        .SUCCESS => {},
        .BADF => error.FileNotFound,
        .NOTTY => error.FileNotTty,
        else => unreachable,
    };
}

pub fn poll(port: std.fs.File) !bool {
    var pollfds: [1]std.posix.pollfd = .{
        .{
            .fd = port.handle,
            .events = std.posix.POLL.IN,
            .revents = undefined,
        },
    };
    if (try std.posix.poll(&pollfds, 0) == 0) return false;
    if (pollfds[0].revents & std.posix.POLL.IN == 0) return false;

    const err_mask = std.posix.POLL.ERR | std.posix.POLL.NVAL |
        std.posix.POLL.HUP;
    if (pollfds[0].revents & err_mask != 0) return false;
    return true;
}

pub fn iterate() !Iterator {
    var result: Iterator = .{
        .dir = try std.fs.cwd().openDir("/dev", .{ .iterate = true }),
        .iterator = undefined,
    };
    result.iterator = result.dir.iterate();
    return result;
}

pub const Iterator = struct {
    dir: std.fs.Dir,
    iterator: std.fs.Dir.Iterator,
    name_buffer: [256]u8 = undefined,
    path_buffer: [std.fs.max_path_bytes]u8 = undefined,

    pub fn next(self: *@This()) !?serialport.Stub {
        var result: serialport.Stub = undefined;
        while (try self.iterator.next()) |entry| {
            if (entry.kind != .character_device) continue;
            if (entry.name.len < 4) continue;
            if (!std.mem.eql(u8, "tty.", entry.name[0..4])) continue;

            @memcpy(
                self.name_buffer[0 .. entry.name.len - 4],
                entry.name[4..],
            );
            result.name = self.name_buffer[0 .. entry.name.len - 4];
            @memcpy(self.path_buffer[0..entry.name.len], entry.name);
            result.path = self.path_buffer[0..entry.name.len];
            return result;
        } else return null;
    }

    pub fn deinit(self: *@This()) void {
        self.dir.close();
        self.* = undefined;
    }
};
