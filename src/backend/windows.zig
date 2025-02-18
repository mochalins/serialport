const std = @import("std");
const serialport = @import("../serialport.zig");
const windows = std.os.windows;

/// Windows baud rate table, sourced from Microsoft `DCB` documentation in
/// `win32`'s `winbase.h`. Non-exhaustive enum to allow for custom baud rate
/// values.
pub const BaudRate = enum(windows.DWORD) {
    B110 = 110,
    B300 = 300,
    B600 = 600,
    B1200 = 1200,
    B2400 = 2400,
    B9600 = 9600,
    B14400 = 14400,
    B19200 = 19200,
    B38400 = 38400,
    B57600 = 57600,
    B115200 = 115200,
    B128000 = 128000,
    B256000 = 256000,
    _,
};

/// Reused structures necessary between non-blocking poll calls.
pub const PollContinuation = struct {
    events: EventMask,
    overlapped: windows.OVERLAPPED,
};

pub const ReadError =
    windows.ReadFileError ||
    windows.OpenError ||
    windows.Wtf8ToPrefixedFileWError ||
    windows.WaitForSingleObjectError;
pub const Reader = std.io.GenericReader(
    ReadContext,
    ReadError,
    readFn,
);
pub const WriteError =
    windows.WriteFileError ||
    windows.OpenError ||
    windows.Wtf8ToPrefixedFileWError ||
    windows.WaitForSingleObjectError;
pub const Writer = std.io.GenericWriter(
    WriteContext,
    WriteError,
    writeFn,
);

pub fn open(path: []const u8, flags: std.fs.File.OpenFlags) !std.fs.File {
    const path_w = try windows.sliceToPrefixedFileW(std.fs.cwd().fd, path);
    // TODO: Support other flags
    const result: std.fs.File = .{
        .handle = windows.kernel32.CreateFileW(
            path_w.span(),
            switch (flags.mode) {
                .read_only => windows.GENERIC_READ,
                .write_only => windows.GENERIC_WRITE,
                .read_write => windows.GENERIC_READ | windows.GENERIC_WRITE,
            },
            0,
            null,
            windows.OPEN_EXISTING,
            windows.FILE_FLAG_OVERLAPPED,
            null,
        ),
    };
    if (result.handle == windows.INVALID_HANDLE_VALUE) {
        switch (windows.GetLastError()) {
            windows.Win32Error.FILE_NOT_FOUND => {
                return error.FileNotFound;
            },
            else => |e| return windows.unexpectedError(e),
        }
    }
    return result;
}

pub fn configure(port: std.fs.File, config: serialport.Config) !void {
    var dcb: DCB = std.mem.zeroes(DCB);
    dcb.DCBlength = @sizeOf(DCB);

    if (config.input_baud_rate != null)
        return error.InputBaudRateUnsupported;

    if (GetCommState(port.handle, &dcb) == 0)
        return windows.unexpectedError(windows.GetLastError());

    dcb.BaudRate = config.baud_rate;
    dcb.flags = .{
        .Parity = config.parity != .none,
        .OutxCtsFlow = config.flow_control == .hardware,
        .OutX = config.flow_control == .software,
        .InX = config.flow_control == .software,
        .RtsControl = config.flow_control == .hardware,
    };
    dcb.ByteSize = 5 + @as(windows.BYTE, @intFromEnum(config.data_bits));
    dcb.Parity = @intFromEnum(config.parity);
    dcb.StopBits = if (config.stop_bits == .two) 2 else 0;
    dcb.XonChar = 0x11;
    dcb.XoffChar = 0x13;

    if (SetCommState(port.handle, &dcb) == 0) {
        return windows.unexpectedError(windows.GetLastError());
    }
    if (SetCommMask(port.handle, .{ .RXCHAR = true }) == 0) {
        return windows.unexpectedError(windows.GetLastError());
    }
    const timeouts: CommTimeouts = .{
        .ReadIntervalTimeout = std.math.maxInt(windows.DWORD),
        .ReadTotalTimeoutMultiplier = 0,
        .ReadTotalTimeoutConstant = 0,
        .WriteTotalTimeoutMultiplier = 0,
        .WriteTotalTimeoutConstant = 0,
    };
    if (SetCommTimeouts(port.handle, &timeouts) == 0) {
        return windows.unexpectedError(windows.GetLastError());
    }
}

pub fn flush(port: std.fs.File, options: serialport.FlushOptions) !void {
    if (!options.input and !options.output) return;
    if (PurgeComm(port.handle, .{
        .PURGE_TXCLEAR = options.output,
        .PURGE_RXCLEAR = options.input,
    }) == 0) {
        return windows.unexpectedError(windows.GetLastError());
    }
}

pub fn poll(port: std.fs.File, continuation: *?PollContinuation) !bool {
    var comstat: ComStat = undefined;
    if (ClearCommError(port.handle, null, &comstat) == 0) {
        return windows.unexpectedError(windows.GetLastError());
    }
    if (comstat.cbInQue > 0) return true;

    if (continuation.*) |*cont| {
        if (windows.GetOverlappedResult(
            port.handle,
            &cont.overlapped,
            false,
        ) catch |e| switch (e) {
            error.WouldBlock => return false,
            else => return e,
        } != 0) {
            const was_rx = cont.events.RXCHAR;
            continuation.* = null;
            return was_rx;
        } else {
            switch (windows.GetLastError()) {
                windows.Win32Error.IO_PENDING => return false,
                else => |e| return windows.unexpectedError(e),
            }
        }
    } else {
        continuation.* = .{
            .events = undefined,
            .overlapped = .{
                .Internal = 0,
                .InternalHigh = 0,
                .DUMMYUNIONNAME = .{
                    .DUMMYSTRUCTNAME = .{
                        .Offset = 0,
                        .OffsetHigh = 0,
                    },
                },
                .hEvent = try windows.CreateEventEx(
                    null,
                    "",
                    windows.CREATE_EVENT_MANUAL_RESET,
                    windows.EVENT_ALL_ACCESS,
                ),
            },
        };
        if (WaitCommEvent(
            port.handle,
            &continuation.*.?.events,
            &continuation.*.?.overlapped,
        ) == 0) {
            switch (windows.GetLastError()) {
                windows.Win32Error.IO_PENDING => return false,
                else => |e| return windows.unexpectedError(e),
            }
        }
        return continuation.*.?.events.RXCHAR;
    }
}

pub fn reader(port: std.fs.File) Reader {
    return .{ .context = port };
}

pub fn writer(port: std.fs.File) Writer {
    return .{ .context = port };
}

pub fn iterate() !Iterator {
    const HKEY_LOCAL_MACHINE = @as(windows.HKEY, @ptrFromInt(0x80000002));
    const KEY_READ = 0x20019;

    const w_str: [30:0]u16 = .{
        'H',
        'A',
        'R',
        'D',
        'W',
        'A',
        'R',
        'E',
        '\\',
        'D',
        'E',
        'V',
        'I',
        'C',
        'E',
        'M',
        'A',
        'P',
        '\\',
        'S',
        'E',
        'R',
        'I',
        'A',
        'L',
        'C',
        'O',
        'M',
        'M',
        '\\',
    };

    var result: Iterator = .{ .key = undefined };
    if (windows.advapi32.RegOpenKeyExW(
        HKEY_LOCAL_MACHINE,
        &w_str,
        0,
        KEY_READ,
        &result.key,
    ) != 0) {
        return windows.unexpectedError(windows.GetLastError());
    }

    return result;
}

pub const Iterator = struct {
    key: windows.HKEY,
    index: windows.DWORD = 0,
    name_buffer: [16]u8 = undefined,
    path_buffer: [16]u8 = undefined,

    pub fn next(self: *@This()) !?serialport.Stub {
        defer self.index += 1;

        var name_size: windows.DWORD = 256;
        var data_size: windows.DWORD = 256;
        var name: [255:0]u8 = undefined;

        return switch (RegEnumValueA(
            self.key,
            self.index,
            &name,
            &name_size,
            null,
            null,
            &self.name_buffer,
            &data_size,
        )) {
            0 => serialport.Stub{
                .name = self.name_buffer[0 .. data_size - 1],
                .path = try std.fmt.bufPrint(
                    &self.path_buffer,
                    "\\\\.\\{s}",
                    .{self.name_buffer[0 .. data_size - 1]},
                ),
            },
            259 => null,
            else => windows.unexpectedError(windows.GetLastError()),
        };
    }

    pub fn deinit(self: *@This()) void {
        _ = windows.advapi32.RegCloseKey(self.key);
        self.* = undefined;
    }
};

const ReadContext = std.fs.File;
fn readFn(context: ReadContext, buffer: []u8) ReadError!usize {
    var overlapped: windows.OVERLAPPED = .{
        .Internal = 0,
        .InternalHigh = 0,
        .DUMMYUNIONNAME = .{
            .DUMMYSTRUCTNAME = .{
                .Offset = 0,
                .OffsetHigh = 0,
            },
        },
        .hEvent = try windows.CreateEventEx(
            null,
            "",
            windows.CREATE_EVENT_MANUAL_RESET,
            windows.EVENT_ALL_ACCESS,
        ),
    };

    const want_read_count: windows.DWORD = @min(
        @as(windows.DWORD, std.math.maxInt(windows.DWORD)),
        buffer.len,
    );
    var read_amount: windows.DWORD = undefined;
    if (windows.kernel32.ReadFile(
        context.handle,
        buffer.ptr,
        want_read_count,
        &read_amount,
        &overlapped,
    ) == 0) {
        switch (windows.GetLastError()) {
            windows.Win32Error.IO_PENDING => {},
            else => |e| return windows.unexpectedError(e),
        }
    } else {
        return read_amount;
    }

    var async_read_amount: windows.DWORD = undefined;
    if (windows.kernel32.GetOverlappedResult(
        context.handle,
        &overlapped,
        &async_read_amount,
        0,
    ) != 0) {
        return async_read_amount;
    }
    if (windows.kernel32.GetOverlappedResult(
        context.handle,
        &overlapped,
        &async_read_amount,
        1,
    ) == 0) {
        switch (windows.GetLastError()) {
            .HANDLE_EOF => {
                return async_read_amount;
            },
            else => |e| return windows.unexpectedError(e),
        }
    }
    return async_read_amount;
}

const WriteContext = std.fs.File;
fn writeFn(context: WriteContext, bytes: []const u8) WriteError!usize {
    var bytes_written: windows.DWORD = undefined;
    var overlapped: windows.OVERLAPPED = .{
        .Internal = 0,
        .InternalHigh = 0,
        .DUMMYUNIONNAME = .{
            .DUMMYSTRUCTNAME = .{
                .Offset = 0,
                .OffsetHigh = 0,
            },
        },
        .hEvent = try windows.CreateEventEx(
            null,
            "",
            windows.CREATE_EVENT_MANUAL_RESET,
            windows.EVENT_ALL_ACCESS,
        ),
    };
    defer windows.CloseHandle(overlapped.hEvent.?);
    const adjusted_len =
        std.math.cast(u32, bytes.len) orelse std.math.maxInt(u32);

    if (windows.kernel32.WriteFile(
        context.handle,
        bytes.ptr,
        adjusted_len,
        &bytes_written,
        &overlapped,
    ) == 0) {
        switch (windows.GetLastError()) {
            .INVALID_USER_BUFFER => return error.SystemResources,
            .NOT_ENOUGH_MEMORY => return error.SystemResources,
            .OPERATION_ABORTED => return error.OperationAborted,
            .NOT_ENOUGH_QUOTA => return error.SystemResources,
            .IO_PENDING => {
                try windows.WaitForSingleObject(
                    overlapped.hEvent.?,
                    windows.INFINITE,
                );
                const amount_written = try windows.GetOverlappedResult(
                    context.handle,
                    &overlapped,
                    true,
                );
                return amount_written;
            },
            .BROKEN_PIPE => return error.BrokenPipe,
            .INVALID_HANDLE => return error.NotOpenForWriting,
            .LOCK_VIOLATION => return error.LockViolation,
            .NETNAME_DELETED => return error.ConnectionResetByPeer,
            else => |e| return windows.unexpectedError(e),
        }
    }
    return adjusted_len;
}

/// Windows control settings for a serial communications device, sourced from
/// Microsoft `DCB` documentation in `win32`'s `winbase.h`.
const DCB = extern struct {
    DCBlength: windows.DWORD,
    BaudRate: BaudRate,
    flags: Flags,
    Reserved: windows.WORD,
    XonLim: windows.WORD,
    XoffLim: windows.WORD,
    ByteSize: windows.BYTE,
    Parity: windows.BYTE,
    StopBits: windows.BYTE,
    XonChar: u8,
    XoffChar: u8,
    ErrorChar: u8,
    EofChar: u8,
    EvtChar: u8,
    Reserved1: windows.WORD,

    const Flags = packed struct(windows.DWORD) {
        Binary: bool = true,
        Parity: bool = false,
        OutxCtsFlow: bool = false,
        OutxDsrFlow: bool = false,
        DtrControl: u2 = 1,
        DsrSensitivity: bool = false,
        TXContinueOnXoff: bool = false,
        OutX: bool = false,
        InX: bool = false,
        ErrorChar: bool = false,
        Null: bool = false,
        RtsControl: bool = false,
        _unused: u1 = 0,
        AbortOnError: bool = false,
        _: u17 = 0,
    };
};

const EventMask = packed struct(windows.DWORD) {
    RXCHAR: bool = false,
    RXFLAG: bool = false,
    TXEMPTY: bool = false,
    CTS: bool = false,
    DSR: bool = false,
    RLSD: bool = false,
    BREAK: bool = false,
    ERR: bool = false,
    RING: bool = false,
    _: u23 = 0,
};

const CommTimeouts = extern struct {
    ReadIntervalTimeout: windows.DWORD,
    ReadTotalTimeoutMultiplier: windows.DWORD,
    ReadTotalTimeoutConstant: windows.DWORD,
    WriteTotalTimeoutMultiplier: windows.DWORD,
    WriteTotalTimeoutConstant: windows.DWORD,
};

const ErrorsMask = packed struct(windows.DWORD) {
    /// Input buffer overflow occurred. Either no room in input buffer, or byte
    /// was received after EOF.
    RX_OVER: bool = false,
    /// Character-buffer overrun occurred. Next character is lost.
    OVERRUN: bool = false,
    /// Hardware detected parity error.
    RXPARITY: bool = false,
    /// Hardware detected a framing error.
    FRAME: bool = false,
    /// Hardware detected a break condition.
    BREAK: bool = false,
    _: u27 = 0,
};

const ComStat = extern struct {
    flags: packed struct(windows.DWORD) {
        CtsHold: bool = false,
        DsrHold: bool = false,
        RlsdHold: bool = false,
        XoffHold: bool = false,
        XoffSent: bool = false,
        Eof: bool = false,
        Txim: bool = false,
        Reserved: u25 = 0,
    },
    cbInQue: windows.DWORD,
    cbOutQue: windows.DWORD,
};

extern "kernel32" fn SetCommState(
    hFile: windows.HANDLE,
    lpDCB: *DCB,
) callconv(windows.WINAPI) windows.BOOL;

extern "kernel32" fn GetCommState(
    hFile: windows.HANDLE,
    lpDCB: *DCB,
) callconv(windows.WINAPI) windows.BOOL;

extern "kernel32" fn SetCommMask(
    hFile: windows.HANDLE,
    dwEvtMask: EventMask,
) callconv(windows.WINAPI) windows.BOOL;

extern "kernel32" fn SetCommTimeouts(
    hFile: windows.HANDLE,
    lpCommTimeouts: *const CommTimeouts,
) callconv(windows.WINAPI) windows.BOOL;

extern "kernel32" fn WaitCommEvent(
    hFile: windows.HANDLE,
    lpEvtMask: *EventMask,
    lpOverlapped: ?*windows.OVERLAPPED,
) callconv(windows.WINAPI) windows.BOOL;

extern "kernel32" fn ClearCommError(
    hFile: windows.HANDLE,
    lpErrors: ?*ErrorsMask,
    lpStat: ?*ComStat,
) callconv(windows.WINAPI) windows.BOOL;

extern "kernel32" fn PurgeComm(
    hFile: windows.HANDLE,
    dwFlags: packed struct(windows.DWORD) {
        PURGE_TXABORT: bool = false,
        PURGE_RXABORT: bool = false,
        PURGE_TXCLEAR: bool = false,
        PURGE_RXCLEAR: bool = false,
        _: u28 = 0,
    },
) callconv(windows.WINAPI) windows.BOOL;

extern "advapi32" fn RegEnumValueA(
    hKey: windows.HKEY,
    dwIndex: windows.DWORD,
    lpValueName: windows.LPSTR,
    lpcchValueName: *windows.DWORD,
    lpReserved: ?*windows.DWORD,
    lpType: ?*windows.DWORD,
    lpData: [*]windows.BYTE,
    lpcbData: *windows.DWORD,
) callconv(std.os.windows.WINAPI) std.os.windows.LSTATUS;
