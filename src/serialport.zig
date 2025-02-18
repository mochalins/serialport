const serialport = @This();
const builtin = @import("builtin");
const std = @import("std");

pub const linux = @import("backend/linux.zig");
pub const macos = @import("backend/macos.zig");
pub const windows = @import("backend/windows.zig");

pub fn iterate() !Iterator {
    switch (builtin.target.os.tag) {
        .linux, .macos, .windows => return backend.iterate(),
        else => @compileError("unsupported OS"),
    }
}

pub fn open(file_path: []const u8, flags: std.fs.File.OpenFlags) !Port {
    return switch (builtin.target.os.tag) {
        .linux, .macos, .windows => .{ ._impl = .{
            .file = try backend.open(file_path, flags),
        } },
        else => @compileError("unsupported OS"),
    };
}

const PortImpl = switch (builtin.target.os.tag) {
    .linux, .macos => struct {
        file: std.fs.File,
        orig_termios: ?std.posix.termios = null,
    },
    .windows => struct {
        file: std.fs.File,
        poll_continuation: ?windows.PollContinuation = null,
    },
    else => @compileError("unsupported OS"),
};

pub const Port = struct {
    _impl: PortImpl,

    pub const Reader = switch (builtin.target.os.tag) {
        .linux, .macos => std.fs.File.Reader,
        .windows => windows.Reader,
        else => @compileError("unsupported OS"),
    };
    pub const ReadError = switch (builtin.target.os.tag) {
        .linux, .macos => std.fs.File.ReadError,
        .windows => windows.ReadError,
        else => @compileError("unsupported OS"),
    };
    pub const Writer = switch (builtin.target.os.tag) {
        .linux, .macos => std.fs.File.Writer,
        .windows => windows.Writer,
        else => @compileError("unsupported OS"),
    };
    pub const WriteError = switch (builtin.target.os.tag) {
        .linux, .macos => std.fs.File.WriteError,
        .windows => windows.WriteError,
        else => @compileError("unsupported OS"),
    };

    pub fn close(self: *@This()) void {
        switch (comptime builtin.target.os.tag) {
            .linux, .macos => {
                if (self._impl.orig_termios) |orig_termios| {
                    std.posix.tcsetattr(
                        self._impl.file.handle,
                        .NOW,
                        orig_termios,
                    ) catch {};
                }
                self._impl.file.close();
            },
            .windows => {
                self._impl.file.close();
            },
            else => @compileError("unsupported OS"),
        }
        self.* = undefined;
    }

    pub fn configure(self: *@This(), config: Config) !void {
        switch (comptime builtin.target.os.tag) {
            .linux, .macos => {
                const termios = try backend.configure(
                    self._impl.file,
                    config,
                );
                // Only save original termios once so that reconfiguration
                // will not overwrite original termios.
                if (self._impl.orig_termios == null) {
                    self._impl.orig_termios = termios;
                }
            },
            .windows => try windows.configure(self._impl.file, config),
            else => @compileError("unsupported OS"),
        }
    }

    pub fn flush(self: *@This(), options: FlushOptions) !void {
        switch (comptime builtin.target.os.tag) {
            .linux, .macos, .windows => try backend.flush(
                self._impl.file,
                options,
            ),
            else => @compileError("unsupported OS"),
        }
    }

    pub fn poll(self: *@This()) !bool {
        switch (comptime builtin.target.os.tag) {
            .linux, .macos => return backend.poll(self._impl.file),
            .windows => {
                return windows.poll(
                    self._impl.file,
                    &self._impl.poll_continuation,
                );
            },
            else => @compileError("unsupported OS"),
        }
    }

    pub fn reader(self: @This()) Reader {
        switch (comptime builtin.target.os.tag) {
            .linux, .macos => return self._impl.file.reader(),
            .windows => return windows.reader(self._impl.file),
            else => @compileError("unsupported OS"),
        }
    }

    pub fn writer(self: @This()) Writer {
        switch (comptime builtin.target.os.tag) {
            .linux, .macos => return self._impl.file.writer(),
            .windows => return windows.writer(self._impl.file),
            else => @compileError("unsupported OS"),
        }
    }
};

pub const FlushOptions = struct {
    input: bool = true,
    output: bool = true,
};

pub const Config = struct {
    /// Baud rate. Used as both output and input baud rate, unless an input
    /// baud is separately provided.
    baud_rate: BaudRate,
    /// Input-specific baud rate. Use only when a custom input baud rate
    /// different than the output baud rate must be specified.
    input_baud_rate: ?BaudRate = null,
    /// Per-character parity bit use. Data bits must be less than eight to use
    /// parity bit (eighth bit is used as parity bit).
    parity: Parity = .none,
    /// Number of bits used to signal end of character. Appended after all data
    /// and parity bits.
    stop_bits: StopBits = .one,
    /// Number of data bits to use per character.
    data_bits: DataBits = .eight,
    flow_control: FlowControl = .none,

    pub const BaudRate = if (@hasDecl(backend, "BaudRate"))
        backend.BaudRate
    else if (@TypeOf(std.posix.speed_t) != void)
        std.posix.speed_t
    else
        @compileError("unsupported backend/OS");

    pub const Parity = enum(u3) {
        /// Do not create or check for parity bit per character.
        none,
        /// Parity bit set to `0` when data has odd number of `1` bits.
        odd,
        /// Parity bit set to `0` when data has even number of `1` bits.
        even,
        /// Parity bit always set to `1`.
        mark,
        /// Parity bit always set to `0`. A.k.a. bit filling.
        space,
    };

    pub const StopBits = enum(u1) {
        /// One bit to signal end of character.
        one,
        /// Two bits to signal end of character.
        two,
    };

    pub const DataBits = enum(u2) {
        /// Five data bits per character.
        five,
        /// Six data bits per character.
        six,
        /// Seven data bits per character.
        seven,
        /// Eight data bits per character.
        eight,
    };

    pub const FlowControl = enum(u2) {
        /// No flow control is used.
        none,
        /// XON-XOFF software flow control is used.
        software,
        /// Hardware flow control with RTS (RFR) / CTS is used. A.k.a.
        /// hardware handshaking, pacing.
        hardware,
    };
};

/// Serial port stub that contains minimal information necessary to
/// identify and open a serial port. Stubs may be dependent on its source
/// iterator, and are not guaranteed to stay valid after iterator state
/// is changed.
pub const Stub = struct {
    name: []const u8,
    path: []const u8,

    pub fn open(self: @This(), flags: std.fs.File.OpenFlags) !Port {
        return serialport.open(self.path, flags);
    }
};

pub const Iterator = switch (builtin.target.os.tag) {
    .linux, .macos, .windows => backend.Iterator,
    else => @compileError("unsupported OS"),
};

const backend = switch (builtin.target.os.tag) {
    .windows => windows,
    .macos => macos,
    .linux => linux,
    else => @compileError("unsupported OS"),
};

test {
    std.testing.refAllDeclsRecursive(Port);
    std.testing.refAllDeclsRecursive(Iterator);
    std.testing.refAllDeclsRecursive(Stub);
    _ = try iterate();

    switch (builtin.target.os.tag) {
        .linux => std.testing.refAllDeclsRecursive(linux),
        .macos => std.testing.refAllDeclsRecursive(macos),
        .windows => std.testing.refAllDeclsRecursive(windows),
        else => @compileError("unsupported OS"),
    }
}
