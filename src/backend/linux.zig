const builtin = @import("builtin");
const std = @import("std");
const serialport = @import("../serialport.zig");
const linux = std.os.linux;

pub const BaudRate = b: {
    const ti = @typeInfo(linux.speed_t).@"enum";
    @setEvalBranchQuota(3_874);
    var field_names: [ti.fields.len][]const u8 = undefined;
    var field_values: [ti.fields.len]ti.tag_type = undefined;
    for (ti.fields, 0..) |field, i| {
        field_names[i] = field.name;
        field_values[i] = std.fmt.parseInt(
            ti.tag_type,
            field.name[1..],
            10,
        ) catch {
            @compileError("invalid baud rate tag");
        };
    }
    break :b @Enum(ti.tag_type, .nonexhaustive, &field_names, &field_values);
};

pub fn open(
    io: std.Io,
    path: []const u8,
    flags: std.Io.File.OpenFlags,
) std.Io.File.OpenError!std.Io.File {
    var result = try std.Io.Dir.cwd().openFile(io, path, flags);
    errdefer result.close();
    var fl_flags = std.os.linux.fcntl(result.handle, std.os.linux.F.GETFL, 0);
    fl_flags |= @as(usize, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));
    _ = std.os.linux.fcntl(result.handle, std.os.linux.F.SETFL, 0);
    return result;
}

/// Configure serial port. Returns original `termios` settings on success.
pub fn configure(
    port: std.Io.File,
    config: serialport.Config,
) !linux.termios {
    var settings = try std.posix.tcgetattr(port.handle);
    const orig_termios = settings;

    // `cfmakeraw`
    settings.iflag.IGNBRK = false;
    settings.iflag.BRKINT = false;
    settings.iflag.PARMRK = false;
    settings.iflag.ISTRIP = false;
    settings.iflag.INLCR = false;
    settings.iflag.IGNCR = false;
    settings.iflag.ICRNL = false;
    settings.iflag.IXON = false;

    settings.oflag.OPOST = false;

    settings.lflag.ECHO = false;
    settings.lflag.ECHONL = false;
    settings.lflag.ICANON = false;
    settings.lflag.ISIG = false;
    settings.lflag.IEXTEN = false;

    settings.cflag.CREAD = true;
    settings.cflag.CSTOPB = config.stop_bits == .two;
    settings.cflag.CSIZE = @enumFromInt(@intFromEnum(config.data_bits));

    configureBaudRate(&settings, config.baud_rate, config.input_baud_rate);
    configureParity(&settings, config.parity);
    configureFlowControl(&settings, config.flow_control);

    // Minimum arrived bytes before read returns.
    settings.cc[@intFromEnum(linux.V.MIN)] = 0;
    // Inter-byte timeout before read returns.
    settings.cc[@intFromEnum(linux.V.TIME)] = 0;
    settings.cc[@intFromEnum(linux.V.START)] = 0x11;
    settings.cc[@intFromEnum(linux.V.STOP)] = 0x13;

    try std.posix.tcsetattr(port.handle, .NOW, settings);
    return orig_termios;
}

pub fn configureBaudRate(
    termios: *linux.termios,
    baud_rate: BaudRate,
    input_baud_rate: ?BaudRate,
) void {
    const CBAUD: u32 = switch (comptime builtin.target.cpu.arch) {
        .powerpc, .powerpcle, .powerpc64, .powerpc64le => 0x000000FF,
        else => 0x0000100F,
    };
    const CIBAUD: u32 = switch (comptime builtin.target.cpu.arch) {
        .powerpc, .powerpcle, .powerpc64, .powerpc64le => 0x00FF0000,
        else => 0x100F0000,
    };
    const BOTHER = switch (comptime builtin.target.cpu.arch) {
        .powerpc, .powerpcle, .powerpc64, .powerpc64le => 0x0000001F,
        else => 0x00001000,
    };
    const IBSHIFT = 16;

    const custom_out: bool = std.enums.tagName(BaudRate, baud_rate) == null;
    const custom_in: bool = if (input_baud_rate) |ibr|
        std.enums.tagName(BaudRate, ibr) == null
    else
        custom_out;

    var out_bits = @intFromEnum(baud_rate);
    var in_bits = @intFromEnum(if (input_baud_rate) |ibr| ibr else baud_rate);

    inline for (@typeInfo(BaudRate).@"enum".fields) |field| {
        if (out_bits == field.value) {
            out_bits = @intFromEnum(@field(linux.speed_t, field.name));
        }
        if (in_bits == field.value) {
            in_bits = @intFromEnum(@field(linux.speed_t, field.name));
        }
    }

    var cflag: u32 = @bitCast(termios.cflag);

    // Set CBAUD and CIBAUD in cflag.
    cflag &= ~CBAUD;
    cflag &= ~CIBAUD;
    if (custom_out) {
        cflag |= BOTHER;
    } else {
        cflag |= out_bits;
    }
    if (custom_in) {
        cflag |= BOTHER << IBSHIFT;
    } else {
        cflag |= in_bits << IBSHIFT;
    }
    termios.cflag = @bitCast(cflag);

    const ospeed: *u32 = @ptrCast(&termios.ospeed);
    ospeed.* = out_bits;
    const ispeed: *u32 = @ptrCast(&termios.ispeed);
    ispeed.* = in_bits;
}

pub fn configureParity(
    termios: *linux.termios,
    parity: serialport.Config.Parity,
) void {
    termios.cflag.PARENB = parity != .none;
    termios.cflag.PARODD = parity == .odd or parity == .mark;
    termios.cflag.CMSPAR = parity == .mark or parity == .space;

    termios.iflag.INPCK = parity != .none;
    termios.iflag.IGNPAR = parity == .none;
}

pub fn configureFlowControl(
    termios: *linux.termios,
    flow_control: serialport.Config.FlowControl,
) void {
    termios.cflag.CLOCAL = flow_control == .none;
    termios.cflag.CRTSCTS = flow_control == .hardware;

    termios.iflag.IXANY = flow_control == .software;
    termios.iflag.IXON = flow_control == .software;
    termios.iflag.IXOFF = flow_control == .software;
}

pub fn iterate(io: std.Io) !Iterator {
    var result: Iterator = .{
        .dir = std.Io.Dir.cwd().openDir(
            io,
            "/dev/serial/by-id",
            .{ .iterate = true },
        ) catch |e| switch (e) {
            error.FileNotFound => null,
            else => return e,
        },
        .iterator = undefined,
    };
    if (result.dir) |d| {
        result.iterator = d.iterate();
    }
    return result;
}

pub const Iterator = struct {
    dir: ?std.Io.Dir,
    iterator: std.Io.Dir.Iterator,
    name_buffer: [256]u8 = undefined,
    path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,

    pub fn next(self: *@This(), io: std.Io) !?serialport.Stub {
        if (self.dir == null) return null;

        var result: serialport.Stub = undefined;
        while (try self.iterator.next(io)) |entry| {
            if (entry.kind != .sym_link) continue;
            @memcpy(self.name_buffer[0..entry.name.len], entry.name);
            result.name = self.name_buffer[0..entry.name.len];
            @memcpy(self.path_buffer[0..18], "/dev/serial/by-id/");
            @memcpy(self.path_buffer[18 .. 18 + entry.name.len], entry.name);
            const len = try std.Io.Dir.realPathFileAbsolute(
                io,
                self.path_buffer[0 .. entry.name.len + 18],
                &self.path_buffer,
            );
            result.path = self.path_buffer[0..len];
            return result;
        } else {
            return null;
        }
    }

    pub fn deinit(self: *@This(), io: std.Io) void {
        if (self.dir) |*d| {
            d.close(io);
        }
        self.* = undefined;
    }
};

fn openVirtualPorts(
    io: std.Io,
    master_port: *std.Io.File,
    slave_port: *std.Io.File,
) !void {
    const c = @cImport({
        @cDefine("_XOPEN_SOURCE", "700");
        @cInclude("stdlib.h");
        @cInclude("fcntl.h");
        @cInclude("unistd.h");
    });

    master_port.* = try open(io, "/dev/ptmx", .{ .mode = .read_write });
    errdefer master_port.close(io);

    if (c.grantpt(master_port.handle) < 0 or
        c.unlockpt(master_port.handle) < 0)
        return error.MasterPseudoTerminalSetupError;

    const slave_name = c.ptsname(master_port.handle) orelse
        return error.SlavePseudoTerminalSetupError;
    const slave_name_len = std.mem.len(slave_name);
    if (slave_name_len == 0)
        return error.SlavePseudoTerminalSetupError;

    slave_port.* = try open(
        io,
        slave_name[0..slave_name_len],
        .{ .mode = .read_write },
    );
}

test "software flow control" {
    const io = std.testing.io;
    var master: std.Io.File = undefined;
    var slave: std.Io.File = undefined;
    try openVirtualPorts(io, &master, &slave);
    defer master.close(io);
    defer slave.close(io);

    const config: serialport.Config = .{
        .baud_rate = .B230400,
        .flow_control = .software,
    };

    const orig_master = try configure(master, config);
    defer std.posix.tcsetattr(master.handle, .NOW, orig_master) catch {};
    const orig_slave = try configure(slave, config);
    defer std.posix.tcsetattr(slave.handle, .NOW, orig_slave) catch {};

    var master_w = master.writerStreaming(io, &.{});
    var reader_buf: [128]u8 = undefined;
    var slave_r = slave.readerStreaming(io, &reader_buf);

    try std.testing.expectError(
        error.EndOfStream,
        slave_r.interface.peekByte(),
    );
    try master_w.interface.writeAll("test message");
    try std.testing.expectEqual('t', try slave_r.interface.peekByte());

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqual(
        12,
        try slave_r.interface.readSliceShort(&buffer),
    );
    try std.testing.expectEqualSlices(u8, "test message", buffer[0..12]);
    try std.testing.expectError(
        error.EndOfStream,
        slave_r.interface.peekByte(),
    );

    try master_w.interface.writeAll("test message");
    try std.testing.expectEqual('t', try slave_r.interface.peekByte());

    var small_buffer: [8]u8 = undefined;
    try slave_r.interface.readSliceAll(&small_buffer);
    try std.testing.expectEqualSlices(u8, "test mes", &small_buffer);
    try std.testing.expectEqual('s', try slave_r.interface.peekByte());
    try std.testing.expectEqual(
        4,
        try slave_r.interface.readSliceShort(&small_buffer),
    );
    try std.testing.expectEqualSlices(u8, "sage", small_buffer[0..4]);
    try std.testing.expectEqual(
        error.EndOfStream,
        slave_r.interface.peekByte(),
    );

    try master_w.interface.writeAll("test message");
    try std.testing.expectEqual('t', try slave_r.interface.peekByte());
    try std.testing.expectEqual(12, try slave_r.interface.discardRemaining());
    try std.testing.expectEqual(
        error.EndOfStream,
        slave_r.interface.peekByte(),
    );
}

test {
    const io = std.testing.io;
    var master: std.Io.File = undefined;
    var slave: std.Io.File = undefined;
    try openVirtualPorts(io, &master, &slave);
    defer master.close(io);
    defer slave.close(io);

    const config: serialport.Config = .{ .baud_rate = .B115200 };
    const orig_master = try configure(master, config);
    defer std.posix.tcsetattr(master.handle, .NOW, orig_master) catch {};
    const orig_slave = try configure(slave, config);
    defer std.posix.tcsetattr(slave.handle, .NOW, orig_slave) catch {};

    var master_w = master.writerStreaming(io, &.{});
    var reader_buf: [128]u8 = undefined;
    var slave_r = slave.readerStreaming(io, &reader_buf);

    try std.testing.expectError(
        error.EndOfStream,
        slave_r.interface.peekByte(),
    );
    try master_w.interface.writeAll("test message");
    try std.testing.expectEqual('t', try slave_r.interface.peekByte());

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqual(
        12,
        try slave_r.interface.readSliceShort(&buffer),
    );
    try std.testing.expectEqualSlices(u8, "test message", buffer[0..12]);
    try std.testing.expectError(
        error.EndOfStream,
        slave_r.interface.peekByte(),
    );
    try master_w.interface.writeAll("test message");
    try std.testing.expectEqual('t', slave_r.interface.peekByte());

    var small_buffer: [8]u8 = undefined;
    try slave_r.interface.readSliceAll(&small_buffer);
    try std.testing.expectEqualSlices(u8, "test mes", &small_buffer);
    try std.testing.expectEqual('s', slave_r.interface.peekByte());
    try std.testing.expectEqual(
        4,
        slave_r.interface.readSliceShort(&small_buffer),
    );
    try std.testing.expectEqualSlices(u8, "sage", small_buffer[0..4]);
    try std.testing.expectError(
        error.EndOfStream,
        slave_r.interface.peekByte(),
    );

    try master_w.interface.writeAll("test message");
    try std.testing.expectEqual('t', try slave_r.interface.peekByte());
    try std.testing.expectEqual(12, try slave_r.interface.discardRemaining());
    try std.testing.expectError(
        error.EndOfStream,
        slave_r.interface.peekByte(),
    );
}

test "nonblock read" {
    const io = std.testing.io;
    var master: std.Io.File = undefined;
    var slave: std.Io.File = undefined;
    try openVirtualPorts(io, &master, &slave);
    defer master.close(io);
    defer slave.close(io);

    const config: serialport.Config = .{ .baud_rate = .B115200 };
    const orig_master = try configure(master, config);
    defer std.posix.tcsetattr(master.handle, .NOW, orig_master) catch {};
    const orig_slave = try configure(slave, config);
    defer std.posix.tcsetattr(slave.handle, .NOW, orig_slave) catch {};

    var reader_buf: [128]u8 = undefined;
    var slave_r = slave.readerStreaming(io, &reader_buf);

    var result: [16]u8 = undefined;
    try std.testing.expectEqual(
        0,
        try slave_r.interface.readSliceShort(&result),
    );
}

test "custom baud rate" {
    const io = std.testing.io;
    var master: std.Io.File = undefined;
    var slave: std.Io.File = undefined;
    try openVirtualPorts(io, &master, &slave);
    defer master.close(io);
    defer slave.close(io);

    const config: serialport.Config = .{ .baud_rate = @enumFromInt(7667) };
    const orig_master = try configure(master, config);
    defer std.posix.tcsetattr(master.handle, .NOW, orig_master) catch {};
    const orig_slave = try configure(slave, config);
    defer std.posix.tcsetattr(slave.handle, .NOW, orig_slave) catch {};

    var master_w = master.writerStreaming(io, &.{});
    var reader_buf: [128]u8 = undefined;
    var slave_r = slave.readerStreaming(io, &reader_buf);

    try std.testing.expectError(
        error.EndOfStream,
        slave_r.interface.peekByte(),
    );
    try master_w.interface.writeAll("test message");
    try std.testing.expectEqual('t', slave_r.interface.peekByte());

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqual(
        12,
        try slave_r.interface.readSliceShort(&buffer),
    );
    try std.testing.expectEqualSlices(u8, "test message", buffer[0..12]);
    try std.testing.expectEqual(
        error.EndOfStream,
        slave_r.interface.peekByte(),
    );

    try master_w.interface.writeAll("test message");
    try std.testing.expectEqual('t', try slave_r.interface.peekByte());

    var small_buffer: [8]u8 = undefined;
    try std.testing.expectEqual(
        8,
        try slave_r.interface.readSliceShort(&small_buffer),
    );
    try std.testing.expectEqualSlices(u8, "test mes", &small_buffer);
    try std.testing.expectEqual('s', try slave_r.interface.peekByte());
    try std.testing.expectEqual(
        4,
        try slave_r.interface.readSliceShort(&small_buffer),
    );
    try std.testing.expectEqualSlices(u8, "sage", small_buffer[0..4]);
    try std.testing.expectError(
        error.EndOfStream,
        slave_r.interface.peekByte(),
    );

    try master_w.interface.writeAll("test message");
    try std.testing.expectEqual('t', try slave_r.interface.peekByte());
    try std.testing.expectEqual(12, try slave_r.interface.discardRemaining());
    try std.testing.expectError(
        error.EndOfStream,
        slave_r.interface.peekByte(),
    );
}
