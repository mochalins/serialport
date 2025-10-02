# serialport

![Linux Port Iteration Result](assets/Linux_Iteration_Demo.png)

Cross-platform serial port library, adhering to the standard library's reader
and writer interface. All poll (peek) and flush (discard/flush) operations are
accessible through `std.Io.Reader` and `std.Io.Writer` respectively.

Kept up to date to work with latest Zig stable release (0.15.1).

## Todo

- [ ] Support flow control status check
- [ ] Offer both blocking and non-blocking reads/writes
- [ ] Port descriptions and information
- [ ] Export C library

## Examples

### Port Iteration

```zig
// ...
var it = try serialport.iterate();
defer it.deinit();

while (try it.next()) |stub| {
  // Stub name used only to identify port, not to open it.
  std.log.info("Found COM port {s}", .{stub.name});

  std.log.info("Port file path: {s}", .{stub.path});
}
// ...
```

### Polling Reads

```zig
// ...
var port = try serialport.open(my_port_path, .{ .mode = .read_write });
// Typical serial port use cases will often want exclusive lock of the port.
// Use `lock_nonblocking` field to immediately return an open failure if the
// port is currently being used, rather than blocking and waiting to open.
port = try serialport.open(my_port_path, .{
  .mode = .read_write,
  .lock = .exclusive,
  .lock_nonblocking = true,
});
defer port.close();

try port.configure(.{
  .baud_rate = .B115200,
});

// Increase buffer size >1 to make a buffered reader.
var reader_buffer: [1]u8 = undefined;
var reader = port.reader(&reader_buffer);

var result_buffer: [128]u8 = undefined;
const timeout = 1_000 * std.time.ns_per_ms;

var timer = try std.time.Timer.start();
// Keep polling and reading until no bytes arrive for 1000ms.
while (timer.read() < timeout) {
  // Standard reader's "peek" functions replace the function of poll.
  _ = reader.interface.peekByte() catch |e| switch(e) {
    error.EndOfStream => continue,
    else => return e,
  };

  // ...

  // Or, you can directly attempt a read and loop if no bytes are found.
  const read_size = try reader.interface.readSliceShort(&result_buffer);
  if (read_size == 0) continue;
  std.log.info("Port bytes arrived: {any}", .{result_buffer[0..read_size]});
  timer.reset();
}
// ...
```
