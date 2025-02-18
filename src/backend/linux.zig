const builtin = @import("builtin");
const std = @import("std");
const serialport = @import("../serialport.zig");
const linux = std.os.linux;

pub const BaudRate = b: {
    const ti = @typeInfo(linux.speed_t).@"enum";
    var baud_rate_ti: std.builtin.Type.Enum = .{
        .tag_type = ti.tag_type,
        .fields = undefined,
        .decls = &.{},
        .is_exhaustive = false,
    };
    var fields: [ti.fields.len]std.builtin.Type.EnumField = undefined;
    @setEvalBranchQuota(3_874);
    for (ti.fields, 0..) |field, i| {
        fields[i].name = field.name;
        fields[i].value = std.fmt.parseInt(
            ti.tag_type,
            field.name[1..],
            10,
        ) catch {
            @compileError("invalid baud rate tag");
        };
    }
    baud_rate_ti.fields = &fields;
    break :b @Type(std.builtin.Type{ .@"enum" = baud_rate_ti });
};

pub fn open(path: []const u8) !std.fs.File {
    var result = try std.fs.cwd().openFile(path, .{
        // .lock_nonblocking and .lock necessary to not block on openFile
        .lock_nonblocking = true,
        .lock = .exclusive,
        .mode = .read_write,
        .allow_ctty = false,
    });
    errdefer result.close();

    var fl_flags = try std.posix.fcntl(result.handle, std.posix.F.GETFL, 0);
    fl_flags |= @as(usize, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));
    _ = try std.posix.fcntl(result.handle, std.posix.F.SETFL, fl_flags);
    return result;
}

/// Configure serial port. Returns original `termios` settings on success.
pub fn configure(
    port: std.fs.File,
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

pub fn flush(port: std.fs.File, options: serialport.FlushOptions) !void {
    if (!options.input and !options.output) return;

    const TCIFLUSH = 0;
    const TCOFLUSH = 1;
    const TCIOFLUSH = 2;
    const TCFLSH = 0x540B;

    const result = linux.syscall3(
        .ioctl,
        @bitCast(@as(isize, @intCast(port.handle))),
        TCFLSH,
        if (options.input and options.output)
            TCIOFLUSH
        else if (options.input)
            TCIFLUSH
        else
            TCOFLUSH,
    );
    // Use `linux.E.init` rather than `std.posix.errno`, as `std.posix.errno`
    // abstraction will not be set by syscall if libc is linked
    return switch (linux.E.init(result)) {
        .SUCCESS => {},
        .BADF => error.FileNotFound,
        .NOTTY => error.FileNotTty,
        else => unreachable,
    };
}

test "flush error handling" {
    var f: std.fs.File = try std.fs.cwd().createFile("temp.txt", .{});
    defer std.fs.cwd().deleteFile("temp.txt") catch {};
    defer f.close();

    try std.testing.expectError(
        error.FileNotTty,
        flush(f, .{ .input = true, .output = true }),
    );
}

pub fn poll(port: std.fs.File) !bool {
    var pollfds: [1]linux.pollfd = .{.{
        .fd = port.handle,
        .events = linux.POLL.IN,
        .revents = undefined,
    }};
    if (linux.poll(&pollfds, 1, 0) == 0) return false;

    if (pollfds[0].revents & linux.POLL.IN == 0) return false;

    const err_mask = linux.POLL.ERR | linux.POLL.NVAL | linux.POLL.HUP;
    if (pollfds[0].revents & err_mask != 0) return false;

    return true;
}

pub fn iterate() !Iterator {
    var result: Iterator = .{
        .dir = std.fs.cwd().openDir(
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
    dir: ?std.fs.Dir,
    iterator: std.fs.Dir.Iterator,
    name_buffer: [256]u8 = undefined,
    path_buffer: [std.fs.max_path_bytes]u8 = undefined,

    pub fn next(self: *@This()) !?serialport.Stub {
        if (self.dir == null) return null;

        var result: serialport.Stub = undefined;
        while (try self.iterator.next()) |entry| {
            if (entry.kind != .sym_link) continue;
            @memcpy(self.name_buffer[0..entry.name.len], entry.name);
            result.name = self.name_buffer[0..entry.name.len];
            @memcpy(self.path_buffer[0..18], "/dev/serial/by-id/");
            @memcpy(self.path_buffer[18 .. 18 + entry.name.len], entry.name);
            result.path = try std.fs.realpath(
                self.path_buffer[0 .. entry.name.len + 18],
                &self.path_buffer,
            );
            return result;
        } else {
            return null;
        }
    }

    pub fn deinit(self: *@This()) void {
        if (self.dir) |*d| {
            d.close();
        }
        self.* = undefined;
    }
};

fn openVirtualPorts(
    master_port: *std.fs.File,
    slave_port: *std.fs.File,
) !void {
    const c = @cImport({
        @cDefine("_XOPEN_SOURCE", "700");
        @cInclude("stdlib.h");
        @cInclude("fcntl.h");
        @cInclude("unistd.h");
    });

    master_port.* = try open("/dev/ptmx");
    errdefer master_port.close();

    if (c.grantpt(master_port.handle) < 0 or
        c.unlockpt(master_port.handle) < 0)
        return error.MasterPseudoTerminalSetupError;

    const slave_name = c.ptsname(master_port.handle) orelse
        return error.SlavePseudoTerminalSetupError;
    const slave_name_len = std.mem.len(slave_name);
    if (slave_name_len == 0)
        return error.SlavePseudoTerminalSetupError;

    slave_port.* = try open(slave_name[0..slave_name_len]);
}

test "software flow control" {
    var master: std.fs.File = undefined;
    var slave: std.fs.File = undefined;
    try openVirtualPorts(&master, &slave);
    defer master.close();
    defer slave.close();

    const config: serialport.Config = .{
        .baud_rate = .B230400,
        .flow_control = .software,
    };

    const orig_master = try configure(master, config);
    defer std.posix.tcsetattr(master.handle, .NOW, orig_master) catch {};
    const orig_slave = try configure(slave, config);
    defer std.posix.tcsetattr(slave.handle, .NOW, orig_slave) catch {};

    const writer_m = master.writer();
    const reader_s = slave.reader();

    try std.testing.expectEqual(false, try poll(slave));
    try std.testing.expectEqual(12, try writer_m.write("test message"));
    try std.testing.expectEqual(true, try poll(slave));

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqual(12, try reader_s.read(&buffer));
    try std.testing.expectEqualSlices(u8, "test message", buffer[0..12]);
    try std.testing.expectEqual(false, try poll(slave));

    try std.testing.expectEqual(12, try writer_m.write("test message"));
    try std.testing.expectEqual(true, try poll(slave));

    var small_buffer: [8]u8 = undefined;
    try std.testing.expectEqual(8, try reader_s.read(&small_buffer));
    try std.testing.expectEqualSlices(u8, "test mes", &small_buffer);
    try std.testing.expectEqual(true, try poll(slave));
    try std.testing.expectEqual(4, try reader_s.read(&small_buffer));
    try std.testing.expectEqualSlices(u8, "sage", small_buffer[0..4]);
    try std.testing.expectEqual(false, try poll(slave));

    try std.testing.expectEqual(12, try writer_m.write("test message"));
    try std.testing.expectEqual(true, try poll(slave));
    try flush(slave, .{ .input = true });
    try std.testing.expectEqual(false, try poll(slave));
}

test {
    var master: std.fs.File = undefined;
    var slave: std.fs.File = undefined;
    try openVirtualPorts(&master, &slave);
    defer master.close();
    defer slave.close();

    const config: serialport.Config = .{ .baud_rate = .B115200 };
    const orig_master = try configure(master, config);
    defer std.posix.tcsetattr(master.handle, .NOW, orig_master) catch {};
    const orig_slave = try configure(slave, config);
    defer std.posix.tcsetattr(slave.handle, .NOW, orig_slave) catch {};

    const writer_m = master.writer();
    const reader_s = slave.reader();

    try std.testing.expectEqual(false, try poll(slave));
    try std.testing.expectEqual(12, try writer_m.write("test message"));
    try std.testing.expectEqual(true, try poll(slave));

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqual(12, try reader_s.read(&buffer));
    try std.testing.expectEqualSlices(u8, "test message", buffer[0..12]);
    try std.testing.expectEqual(false, try poll(slave));

    try std.testing.expectEqual(12, try writer_m.write("test message"));
    try std.testing.expectEqual(true, try poll(slave));

    var small_buffer: [8]u8 = undefined;
    try std.testing.expectEqual(8, try reader_s.read(&small_buffer));
    try std.testing.expectEqualSlices(u8, "test mes", &small_buffer);
    try std.testing.expectEqual(true, try poll(slave));
    try std.testing.expectEqual(4, try reader_s.read(&small_buffer));
    try std.testing.expectEqualSlices(u8, "sage", small_buffer[0..4]);
    try std.testing.expectEqual(false, try poll(slave));

    try std.testing.expectEqual(12, try writer_m.write("test message"));
    try std.testing.expectEqual(true, try poll(slave));
    try flush(slave, .{ .input = true });
    try std.testing.expectEqual(false, try poll(slave));
}

test "nonblock read" {
    var master: std.fs.File = undefined;
    var slave: std.fs.File = undefined;
    try openVirtualPorts(&master, &slave);
    defer master.close();
    defer slave.close();

    const config: serialport.Config = .{ .baud_rate = .B115200 };
    const orig_master = try configure(master, config);
    defer std.posix.tcsetattr(master.handle, .NOW, orig_master) catch {};
    const orig_slave = try configure(slave, config);
    defer std.posix.tcsetattr(slave.handle, .NOW, orig_slave) catch {};

    var read_buffer: [16]u8 = undefined;
    const reader_s = slave.reader();
    try std.testing.expectEqual(0, try reader_s.read(&read_buffer));
}

test "custom baud rate" {
    var master: std.fs.File = undefined;
    var slave: std.fs.File = undefined;
    try openVirtualPorts(&master, &slave);
    defer master.close();
    defer slave.close();

    const config: serialport.Config = .{ .baud_rate = @enumFromInt(7667) };
    const orig_master = try configure(master, config);
    defer std.posix.tcsetattr(master.handle, .NOW, orig_master) catch {};
    const orig_slave = try configure(slave, config);
    defer std.posix.tcsetattr(slave.handle, .NOW, orig_slave) catch {};

    const writer_m = master.writer();
    const reader_s = slave.reader();

    try std.testing.expectEqual(false, try poll(slave));
    try std.testing.expectEqual(12, try writer_m.write("test message"));
    try std.testing.expectEqual(true, try poll(slave));

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqual(12, try reader_s.read(&buffer));
    try std.testing.expectEqualSlices(u8, "test message", buffer[0..12]);
    try std.testing.expectEqual(false, try poll(slave));

    try std.testing.expectEqual(12, try writer_m.write("test message"));
    try std.testing.expectEqual(true, try poll(slave));

    var small_buffer: [8]u8 = undefined;
    try std.testing.expectEqual(8, try reader_s.read(&small_buffer));
    try std.testing.expectEqualSlices(u8, "test mes", &small_buffer);
    try std.testing.expectEqual(true, try poll(slave));
    try std.testing.expectEqual(4, try reader_s.read(&small_buffer));
    try std.testing.expectEqualSlices(u8, "sage", small_buffer[0..4]);
    try std.testing.expectEqual(false, try poll(slave));

    try std.testing.expectEqual(12, try writer_m.write("test message"));
    try std.testing.expectEqual(true, try poll(slave));
    try flush(slave, .{ .input = true });
    try std.testing.expectEqual(false, try poll(slave));
}
