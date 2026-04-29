const std = @import("std");
const windows = std.os.windows;

const serialport = @import("../serialport.zig");

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

pub const OpenError = error{
    IsDir,
    NotDir,
    FileNotFound,
    NoDevice,
    AccessDenied,
    PipeBusy,
    PathAlreadyExists,
    Unexpected,
    NameTooLong,
    WouldBlock,
    NetworkNotFound,
    AntivirusInterference,
    BadPathName,
};

const Wtf8ToWtf16Error = error{ BadPathName, NameTooLong };

const WaitForSingleObjectError = error{
    WaitAbandoned,
    WaitTimeOut,
    Unexpected,
};

pub const ReadError =
    std.Io.File.Reader.Error ||
    OpenError ||
    Wtf8ToWtf16Error ||
    WaitForSingleObjectError;
pub const Reader = struct {
    context: std.Io.File,
    /// Last error encountered by interface.
    err: ?windows.Win32Error = null,
    interface: std.Io.Reader,
};
pub const WriteError =
    std.Io.File.Writer.Error ||
    OpenError ||
    Wtf8ToWtf16Error ||
    WaitForSingleObjectError;
pub const Writer = struct {
    context: std.Io.File,
    /// Last error encountered by interface.
    err: ?windows.Win32Error = null,
    interface: std.Io.Writer,
};

pub fn open(
    _: std.Io,
    path: []const u8,
    flags: std.Io.File.OpenFlags,
) (Wtf8ToWtf16Error || std.Io.Dir.RealPathFileError)!std.Io.File {
    var path_wtf16: [windows.PATH_MAX_WIDE:0]u16 =
        .{0} ** windows.PATH_MAX_WIDE;
    const path_wtf16_len = try windows.wtf8ToWtf16Le(
        &path_wtf16,
        path,
    );
    // TODO: Support other flags
    const result: std.Io.File = .{
        .handle = CreateFileW(
            path_wtf16[0..path_wtf16_len :0],
            switch (flags.mode) {
                .read_only => GENERIC_READ,
                .write_only => GENERIC_WRITE,
                .read_write => GENERIC_READ | GENERIC_WRITE,
            },
            0,
            null,
            OPEN_EXISTING,
            FILE_FLAG_OVERLAPPED,
            null,
        ),
        .flags = .{ .nonblocking = true },
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

pub fn configure(port: std.Io.File, config: serialport.Config) !void {
    var dcb: DCB = std.mem.zeroes(DCB);
    dcb.DCBlength = @sizeOf(DCB);

    if (config.input_baud_rate != null)
        return error.InputBaudRateUnsupported;

    if (GetCommState(port.handle, &dcb) == .FALSE)
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

    if (SetCommState(port.handle, &dcb) == .FALSE) {
        return windows.unexpectedError(windows.GetLastError());
    }
    if (SetCommMask(port.handle, .{ .RXCHAR = true }) == .FALSE) {
        return windows.unexpectedError(windows.GetLastError());
    }
    const timeouts: CommTimeouts = .{
        .ReadIntervalTimeout = std.math.maxInt(windows.DWORD),
        .ReadTotalTimeoutMultiplier = 0,
        .ReadTotalTimeoutConstant = 0,
        .WriteTotalTimeoutMultiplier = 0,
        .WriteTotalTimeoutConstant = 0,
    };
    if (SetCommTimeouts(port.handle, &timeouts) == .FALSE) {
        return windows.unexpectedError(windows.GetLastError());
    }
}

pub fn reader(port: std.Io.File, buffer: []u8) Reader {
    return .{
        .context = port,
        .interface = .{
            .buffer = buffer,
            .seek = 0,
            .end = 0,
            .vtable = &.{ .stream = stream },
        },
    };
}

pub fn writer(port: std.Io.File, buffer: []u8) Writer {
    return .{
        .context = port,
        .interface = .{
            .buffer = buffer,
            .vtable = &.{
                .drain = drain,
            },
        },
    };
}

pub fn iterate(_: std.Io) !Iterator {
    const HKEY_LOCAL_MACHINE = @as(windows.HKEY, @ptrFromInt(0x80000002));
    const KEY_READ: @typeInfo(std.os.windows.REGSAM).@"struct".backing_integer.? = 0x20019;

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
    if (RegOpenKeyExW(
        HKEY_LOCAL_MACHINE,
        &w_str,
        0,
        @bitCast(KEY_READ),
        &result.key,
    ) != 0) {
        switch (windows.GetLastError()) {
            windows.Win32Error.SUCCESS => {},
            else => |e| return windows.unexpectedError(e),
        }
    }

    return result;
}

pub const Iterator = struct {
    key: windows.HKEY,
    index: windows.DWORD = 0,
    name_buffer: [16]u8 = undefined,
    path_buffer: [16]u8 = undefined,

    pub fn next(self: *@This(), _: std.Io) !?serialport.Stub {
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

    pub fn deinit(self: *@This(), _: std.Io) void {
        _ = RegCloseKey(self.key);
        self.* = undefined;
    }
};

fn stream(
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    limit: std.Io.Limit,
) std.Io.Reader.StreamError!usize {
    if (!limit.nonzero()) return 0;
    const port_reader: *Reader = @fieldParentPtr("interface", r);
    var overlapped: OVERLAPPED = .{
        .Internal = 0,
        .InternalHigh = 0,
        .DUMMYUNIONNAME = .{
            .DUMMYSTRUCTNAME = .{
                .Offset = 0,
                .OffsetHigh = 0,
            },
        },
        .hEvent = CreateEventEx(
            null,
            "",
            CREATE_EVENT_MANUAL_RESET,
            EVENT_ALL_ACCESS,
        ) catch |e| {
            switch (e) {
                error.BadPathName, error.NameTooLong => {
                    port_reader.err = .BAD_PATHNAME;
                },
                else => {
                    port_reader.err = windows.GetLastError();
                },
            }
            return error.ReadFailed;
        },
    };
    defer windows.CloseHandle(overlapped.hEvent.?);
    var unbuffered: [1]u8 = undefined;
    const buf = limit.slice(if (w.buffer.len > 0)
        w.writableSliceGreedy(1) catch |e| {
            port_reader.err = null;
            return e;
        }
    else
        &unbuffered);

    const want_read_count: windows.DWORD = @min(
        @as(windows.DWORD, std.math.maxInt(windows.DWORD)),
        buf.len,
    );
    var read_amount: windows.DWORD = undefined;
    if (ReadFile(
        port_reader.context.handle,
        buf.ptr,
        want_read_count,
        &read_amount,
        &overlapped,
    ) == .FALSE) {
        switch (windows.GetLastError()) {
            windows.Win32Error.IO_PENDING => {},
            else => |e| {
                port_reader.err = e;
                return error.ReadFailed;
            },
        }
    } else if (read_amount == 0) {
        // Must return EOS when there are no bytes left.
        port_reader.err = null;
        return error.EndOfStream;
    } else {
        return read_amount;
    }

    var async_read_amount: windows.DWORD = undefined;
    if (GetOverlappedResult(
        port_reader.context.handle,
        &overlapped,
        &async_read_amount,
        .FALSE,
    ) != .FALSE) {
        if (async_read_amount == 0) {
            // Must return EOS when there are no bytes left.
            port_reader.err = null;
            return error.EndOfStream;
        }
        return async_read_amount;
    }
    if (GetOverlappedResult(
        port_reader.context.handle,
        &overlapped,
        &async_read_amount,
        .TRUE,
    ) == .FALSE) {
        switch (windows.GetLastError()) {
            .HANDLE_EOF => {
                port_reader.err = null;
                return error.EndOfStream;
            },
            else => |e| {
                port_reader.err = e;
                return error.ReadFailed;
            },
        }
    }
    if (async_read_amount == 0) {
        // Must return EOS when there are no bytes left.
        port_reader.err = null;
        return error.EndOfStream;
    }
    return async_read_amount;
}

fn drain(
    w: *std.Io.Writer,
    data: []const []const u8,
    splat: usize,
) std.Io.Writer.Error!usize {
    const port_writer: *Writer = @fieldParentPtr("interface", w);

    while (w.end > 0) {
        const drained = drainBuffer(port_writer, w.buffer[0..w.end]) catch
            return error.WriteFailed;
        if (drained == 0) return 0;
        w.end -= drained;
    }

    var written: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        const drained = drainBuffer(port_writer, bytes) catch
            return error.WriteFailed;
        if (drained == 0) return written;
        written += drained;
    }

    const pattern = data[data.len - 1];
    if (pattern.len == 0) return written;
    for (0..splat) |_| {
        const drained = drainBuffer(port_writer, pattern) catch
            return error.WriteFailed;
        if (drained == 0) return written;
        written += drained;
    }
    return written;
}

fn drainBuffer(
    port_writer: *Writer,
    bytes: []const u8,
) !usize {
    var bytes_written: windows.DWORD = undefined;
    var overlapped: OVERLAPPED = .{
        .Internal = 0,
        .InternalHigh = 0,
        .DUMMYUNIONNAME = .{
            .DUMMYSTRUCTNAME = .{
                .Offset = 0,
                .OffsetHigh = 0,
            },
        },
        .hEvent = CreateEventEx(
            null,
            "",
            CREATE_EVENT_MANUAL_RESET,
            EVENT_ALL_ACCESS,
        ) catch |e| {
            switch (e) {
                error.BadPathName, error.NameTooLong => {
                    port_writer.err = .BAD_PATHNAME;
                },
                else => {
                    port_writer.err = windows.GetLastError();
                },
            }
            return error.ReadFailed;
        },
    };
    defer windows.CloseHandle(overlapped.hEvent.?);
    const adjusted_len =
        std.math.cast(u32, bytes.len) orelse std.math.maxInt(u32);

    if (WriteFile(
        port_writer.context.handle,
        bytes.ptr,
        adjusted_len,
        &bytes_written,
        &overlapped,
    ) == .FALSE) {
        port_writer.err = windows.GetLastError();
        switch (port_writer.err.?) {
            .INVALID_USER_BUFFER => return error.SystemResources,
            .NOT_ENOUGH_MEMORY => return error.SystemResources,
            .OPERATION_ABORTED => return error.OperationAborted,
            .NOT_ENOUGH_QUOTA => return error.SystemResources,
            .IO_PENDING => {
                try WaitForSingleObject(
                    overlapped.hEvent.?,
                    INFINITE,
                );
                const amount_written = try GetOverlappedResultWrapper(
                    port_writer.context.handle,
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
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetCommState(
    hFile: windows.HANDLE,
    lpDCB: *DCB,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn SetCommMask(
    hFile: windows.HANDLE,
    dwEvtMask: EventMask,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn SetCommTimeouts(
    hFile: windows.HANDLE,
    lpCommTimeouts: *const CommTimeouts,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn WaitCommEvent(
    hFile: windows.HANDLE,
    lpEvtMask: *EventMask,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn ClearCommError(
    hFile: windows.HANDLE,
    lpErrors: ?*ErrorsMask,
    lpStat: ?*ComStat,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn PurgeComm(
    hFile: windows.HANDLE,
    dwFlags: packed struct(windows.DWORD) {
        PURGE_TXABORT: bool = false,
        PURGE_RXABORT: bool = false,
        PURGE_TXCLEAR: bool = false,
        PURGE_RXCLEAR: bool = false,
        _: u28 = 0,
    },
) callconv(.winapi) windows.BOOL;

extern "advapi32" fn RegEnumValueA(
    hKey: windows.HKEY,
    dwIndex: windows.DWORD,
    lpValueName: windows.LPSTR,
    lpcchValueName: *windows.DWORD,
    lpReserved: ?*windows.DWORD,
    lpType: ?*windows.DWORD,
    lpData: [*]windows.BYTE,
    lpcbData: *windows.DWORD,
) callconv(.winapi) std.os.windows.LSTATUS;

extern "advapi32" fn RegOpenKeyExW(
    hKey: windows.HKEY,
    lpSubKey: windows.LPCWSTR,
    ulOptions: windows.DWORD,
    samDesired: windows.REGSAM,
    phkResult: *windows.HKEY,
) callconv(.winapi) windows.LSTATUS;

extern "advapi32" fn RegCloseKey(
    hKey: windows.HKEY,
) callconv(.winapi) windows.LSTATUS;

extern "kernel32" fn CreateFileW(
    lpFileName: windows.LPCWSTR,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
    dwCreationDisposition: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;

pub extern "kernel32" fn WaitForSingleObjectEx(
    hHandle: windows.HANDLE,
    dwMilliseconds: windows.DWORD,
    bAlertable: windows.BOOL,
) callconv(.winapi) windows.DWORD;

const WAIT_ABANDONED = 0x00000080;
const WAIT_ABANDONED_0 = WAIT_ABANDONED + 0;
const WAIT_OBJECT_0 = 0x00000000;
const WAIT_TIMEOUT = 0x00000102;
const WAIT_FAILED = 0xFFFFFFFF;

const GENERIC_READ = 0x80000000;
const GENERIC_WRITE = 0x40000000;

const OPEN_EXISTING = 3;
const FILE_FLAG_OVERLAPPED = 0x40000000;
const CREATE_EVENT_MANUAL_RESET = 0x00000001;
const EVENT_ALL_ACCESS = 0x1F0003;

const INFINITE = 4294967295;

pub fn WaitForSingleObject(
    handle: windows.HANDLE,
    milliseconds: windows.DWORD,
) WaitForSingleObjectError!void {
    switch (WaitForSingleObjectEx(handle, milliseconds, .FALSE)) {
        WAIT_ABANDONED => return error.WaitAbandoned,
        WAIT_OBJECT_0 => return,
        WAIT_TIMEOUT => return error.WaitTimeOut,
        WAIT_FAILED => switch (windows.GetLastError()) {
            else => |err| return windows.unexpectedError(err),
        },
        else => return error.Unexpected,
    }
}

pub const OVERLAPPED = extern struct {
    Internal: windows.ULONG_PTR,
    InternalHigh: windows.ULONG_PTR,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: windows.DWORD,
            OffsetHigh: windows.DWORD,
        },
        Pointer: ?windows.PVOID,
    },
    hEvent: ?windows.HANDLE,
};

fn CreateEventEx(
    attributes: ?*windows.SECURITY_ATTRIBUTES,
    name: []const u8,
    flags: windows.DWORD,
    desired_access: windows.DWORD,
) (Wtf8ToWtf16Error || error{Unexpected})!windows.HANDLE {
    var path: [windows.PATH_MAX_WIDE:0]u16 =
        .{0} ** windows.PATH_MAX_WIDE;
    const path_len = try windows.wtf8ToWtf16Le(&path, name);
    const handle = CreateEventExW(
        attributes,
        path[0..path_len :0],
        flags,
        desired_access,
    );
    if (handle) |h| {
        return h;
    } else {
        switch (windows.GetLastError()) {
            else => |err| return windows.unexpectedError(err),
        }
    }
}

extern "kernel32" fn CreateEventExW(
    lpEventAttributes: ?*windows.SECURITY_ATTRIBUTES,
    lpName: ?windows.LPCWSTR,
    dwFlags: windows.DWORD,
    dwDesiredAccess: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;

extern "kernel32" fn ReadFile(
    hFile: windows.HANDLE,
    lpBuffer: windows.LPVOID,
    nNumberOfBytesToRead: windows.DWORD,
    lpNumberOfBytesRead: ?*windows.DWORD,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn WriteFile(
    in_hFile: windows.HANDLE,
    in_lpBuffer: [*]const u8,
    in_nNumberOfBytesToWrite: windows.DWORD,
    out_lpNumberOfBytesWritten: ?*windows.DWORD,
    in_out_lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetOverlappedResult(
    hFile: windows.HANDLE,
    lpOverlapped: *OVERLAPPED,
    lpNumberOfBytesTransferred: *windows.DWORD,
    bWait: windows.BOOL,
) callconv(.winapi) windows.BOOL;

pub fn GetOverlappedResultWrapper(
    h: windows.HANDLE,
    overlapped: *OVERLAPPED,
    wait: bool,
) !windows.DWORD {
    var bytes: windows.DWORD = undefined;
    if (GetOverlappedResult(h, overlapped, &bytes, .fromBool(wait)) == .FALSE) {
        switch (windows.GetLastError()) {
            .IO_INCOMPLETE => if (!wait) return error.WouldBlock else unreachable,
            else => |err| return windows.unexpectedError(err),
        }
    }
    return bytes;
}
