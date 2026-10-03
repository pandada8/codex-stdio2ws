//! codex-stdio2ws: expose a shared `codex app-server` control socket as a
//! stdio JSON-RPC child process.
//!
//! `codex app-server proxy` is a byte relay to the control socket, which is a
//! WebSocket endpoint listening on a Unix domain socket. A client that only
//! speaks newline-delimited JSON-RPC cannot use it. This program performs the
//! WebSocket upgrade itself and then bridges:
//!
//!   stdin  (newline-delimited JSON-RPC)  <->  WebSocket text frames
//!
//! See README.md for the transport details this relies on.

const std = @import("std");
const Io = std.Io;

/// RFC 6455 handshake GUID.
const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
/// Refuse absurd WebSocket frames instead of allocating on a bad length.
const max_payload_bytes: u64 = 64 * 1024 * 1024;

/// Buffers for the stdio and socket readers/writers. Payloads are read into
/// their own allocations, so this only has to hold one frame header (or one
/// socket read) at a time; keeping it small keeps the idle footprint small when
/// one of these runs per session.
const io_buffer_bytes = 8 * 1024;

const op_continuation: u8 = 0x0;
const op_text: u8 = 0x1;
const op_binary: u8 = 0x2;
const op_close: u8 = 0x8;
const op_ping: u8 = 0x9;
const op_pong: u8 = 0xA;

const Context = struct {
    io: Io,
    gpa: std.mem.Allocator,
    /// Set with CODEX_STDIO2WS_DEBUG=1; logs frame traffic to stderr.
    debug: bool,
    /// Set when stdin closed and this process initiated the WebSocket close,
    /// so a socket EOF stops being an error.
    closing: std.atomic.Value(bool) = .init(false),
    /// Serializes writes from the stdin pump and the socket pump.
    write_mutex: Io.Mutex = .init,
    socket_reader: *Io.Reader,
    socket_writer: *Io.Writer,
    stdin_reader: *Io.Reader,
    stdout_writer: *Io.Writer,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    var socket_path: ?[]const u8 = null;
    var print_version = false;
    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "--sock")) {
            arg_index += 1;
            if (arg_index >= args.len) fatal("--sock requires a path", .{});
            socket_path = args[arg_index];
        } else if (std.mem.startsWith(u8, arg, "--sock=")) {
            socket_path = arg["--sock=".len..];
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            print_version = true;
        } else if (std.mem.eql(u8, arg, "app-server") or std.mem.eql(u8, arg, "--stdio")) {
            // Tolerated so this binary can be dropped in as the provider
            // command: Paseo appends `app-server` to whatever argv it is given,
            // and the daemon already speaks the same protocol.
        } else if (std.mem.eql(u8, arg, "--enable") or std.mem.eql(u8, arg, "--disable")) {
            // Feature flags are fixed when the shared daemon starts, so a
            // per-session `--enable goals` cannot be honoured here. Swallow the
            // flag and its value rather than failing the launch.
            arg_index += 1;
            if (arg_index >= args.len) fatal("{s} requires a feature name", .{arg});
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else {
            fatal("unknown argument: {s}", .{arg});
        }
    }

    const path = socket_path orelse
        defaultSocketPath(arena, init.environ_map) catch |err| fatal(
        "cannot resolve the default app-server socket path ({s}); pass --sock",
        .{@errorName(err)},
    );

    if (print_version) {
        printDaemonVersion(io, init.gpa, path);
        return;
    }

    const address = std.Io.net.UnixAddress.init(path) catch |err| fatal(
        "invalid socket path {s}: {s}",
        .{ path, @errorName(err) },
    );
    const stream = address.connect(io) catch |err| fatal(
        "failed to connect to {s}: {s}",
        .{ path, @errorName(err) },
    );

    var socket_read_buffer: [io_buffer_bytes]u8 = undefined;
    var socket_write_buffer: [io_buffer_bytes]u8 = undefined;
    var socket_reader = stream.reader(io, &socket_read_buffer);
    var socket_writer = stream.writer(io, &socket_write_buffer);

    performHandshake(io, &socket_reader.interface, &socket_writer.interface) catch |err| fatal(
        "WebSocket handshake with {s} failed: {s}",
        .{ path, @errorName(err) },
    );
    if (debugEnabled(init.environ_map)) {
        std.debug.print("codex-stdio2ws: connected to {s}\n", .{path});
    }

    var stdin_read_buffer: [io_buffer_bytes]u8 = undefined;
    var stdout_write_buffer: [io_buffer_bytes]u8 = undefined;
    var stdin_reader = Io.File.stdin().readerStreaming(io, &stdin_read_buffer);
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_write_buffer);

    var context = Context{
        .io = io,
        .gpa = init.gpa,
        .debug = debugEnabled(init.environ_map),
        .socket_reader = &socket_reader.interface,
        .socket_writer = &socket_writer.interface,
        .stdin_reader = &stdin_reader.interface,
        .stdout_writer = &stdout_writer.interface,
    };

    const stdin_thread = std.Thread.spawn(.{}, stdinPump, .{&context}) catch |err| fatal(
        "failed to start the stdin pump: {s}",
        .{@errorName(err)},
    );
    stdin_thread.detach();

    // The socket pump owns main: its exit ends the process, which is what the
    // parent observes as the app-server child terminating.
    socketPump(&context) catch |err| switch (err) {
        error.ServerClosed => std.process.exit(0),
        error.EndOfStream => {
            if (context.closing.load(.acquire)) std.process.exit(0);
            fatal("app-server connection ended: {s}", .{@errorName(err)});
        },
        else => fatal("app-server connection ended: {s}", .{@errorName(err)}),
    };
}

fn printUsage() void {
    // Help output goes to stderr so stdout stays a clean JSON-RPC channel.
    std.debug.print(
        \\codex-stdio2ws - bridge a shared codex app-server control socket to stdio
        \\
        \\Usage: codex-stdio2ws [--sock <path>]
        \\
        \\  --sock <path>  app-server control socket (default: $CODEX_HOME/app-server-control/app-server-control.sock)
        \\  -v, --version  report the codex version served by the daemon
        \\  -h, --help     show this help
        \\
        \\stdin/stdout carry newline-delimited JSON-RPC; the socket carries
        \\WebSocket text frames. No permessage-deflate is negotiated.
        \\
        \\`app-server`, `--stdio`, `--enable <feature>` and `--disable <feature>`
        \\are accepted and ignored so this binary can be used directly as a
        \\provider command, which always receives `app-server` appended.
        \\
    , .{});
}

/// Prints the codex version behind the daemon, so version-gated features in the
/// parent process keep working when this binary replaces the codex command.
/// Falls back to version 0.0.0 when the daemon is unreachable.
fn printDaemonVersion(io: Io, gpa: std.mem.Allocator, path: []const u8) void {
    const fallback = "codex-cli 0.0.0 (codex-stdio2ws; daemon unreachable)";
    var version_buffer: [32]u8 = undefined;
    const version = daemonVersion(io, gpa, path, &version_buffer) catch {
        std.debug.print("{s}\n", .{fallback});
        return;
    };
    std.debug.print("codex-cli {s}\n", .{version});
}

/// The returned slice points into `out`, not into the parsed response, which is
/// freed before returning.
fn daemonVersion(io: Io, gpa: std.mem.Allocator, path: []const u8, out: []u8) ![]const u8 {
    var read_buffer: [io_buffer_bytes]u8 = undefined;
    var write_buffer: [io_buffer_bytes]u8 = undefined;
    const stream = (try std.Io.net.UnixAddress.init(path)).connect(io) catch return error.ConnectFailed;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    try performHandshake(io, &reader.interface, &writer.interface);

    const request = "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"codex-stdio2ws\",\"title\":\"codex-stdio2ws\",\"version\":\"0.1.0\"},\"capabilities\":{}}}";
    var context = Context{
        .io = io,
        .gpa = gpa,
        .debug = false,
        .socket_reader = &reader.interface,
        .socket_writer = &writer.interface,
        .stdin_reader = undefined,
        .stdout_writer = undefined,
    };
    try sendFrame(&context, op_text, request);

    while (true) {
        const frame = try readFrame(&context);
        defer gpa.free(frame.payload);
        if (frame.opcode != op_text and frame.opcode != op_binary) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, frame.payload, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const result = parsed.value.object.get("result") orelse continue;
        if (result != .object) continue;
        const user_agent = result.object.get("userAgent") orelse continue;
        if (user_agent != .string) continue;
        const version = firstVersionNumber(user_agent.string) orelse return error.NoVersion;
        if (version.len > out.len) return error.NoVersion;
        @memcpy(out[0..version.len], version);
        return out[0..version.len];
    }
}

/// Returns a slice of `userAgent` shaped like `1.2.3`, or null.
fn firstVersionNumber(text: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < text.len) {
        if (!std.ascii.isDigit(text[index])) {
            index += 1;
            continue;
        }
        var cursor = index;
        var dot_count: usize = 0;
        while (cursor < text.len and (std.ascii.isDigit(text[cursor]) or text[cursor] == '.')) : (cursor += 1) {
            if (text[cursor] == '.') dot_count += 1;
        }
        if (dot_count == 2) return text[index..cursor];
        index = cursor + 1;
    }
    return null;
}

fn fatal(comptime message: []const u8, args: anytype) noreturn {
    std.debug.print("codex-stdio2ws: " ++ message ++ "\n", args);
    std.process.exit(1);
}

fn debugEnabled(environ: *std.process.Environ.Map) bool {
    const value = environ.get("CODEX_STDIO2WS_DEBUG") orelse return false;
    return value.len > 0 and !std.mem.eql(u8, value, "0");
}

fn debugLog(context: *Context, comptime message: []const u8, args: anytype) void {
    if (!context.debug) return;
    std.debug.print("codex-stdio2ws: " ++ message ++ "\n", args);
}

fn defaultSocketPath(arena: std.mem.Allocator, environ: *std.process.Environ.Map) ![]const u8 {
    const relative = "app-server-control/app-server-control.sock";
    if (environ.get("CODEX_HOME")) |codex_home| {
        if (codex_home.len > 0) {
            return try std.fmt.allocPrint(arena, "{s}/{s}", .{ codex_home, relative });
        }
    }
    const home = environ.get("HOME") orelse return error.HomeNotSet;
    if (home.len == 0) return error.HomeNotSet;
    return try std.fmt.allocPrint(arena, "{s}/.codex/{s}", .{ home, relative });
}

/// Upgrades the Unix socket connection to a WebSocket.
///
/// The request deliberately omits `Sec-WebSocket-Extensions`: the codex
/// control socket does not support permessage-deflate, and advertising it
/// makes the server drop the connection.
fn performHandshake(io: Io, reader: *Io.Reader, writer: *Io.Writer) !void {
    var key_bytes: [16]u8 = undefined;
    try Io.randomSecure(io, &key_bytes);
    var key_buffer: [std.base64.standard.Encoder.calcSize(key_bytes.len)]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&key_buffer, &key_bytes);

    var request_buffer: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_buffer,
        "GET /rpc HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
        .{key},
    );
    try writer.writeAll(request);
    try writer.flush();

    const status_line = try readHeaderLine(reader);
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 101")) return error.NotSwitchingProtocols;

    var accept_scratch: [std.base64.standard.Encoder.calcSize(std.crypto.hash.Sha1.digest_length)]u8 = undefined;
    var accept_seen = false;
    while (true) {
        const line = try readHeaderLine(reader);
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (!std.mem.eql(u8, try expectedAccept(key, &accept_scratch), value)) return error.BadAccept;
        accept_seen = true;
    }
    if (!accept_seen) return error.AcceptHeaderMissing;
}

fn expectedAccept(key: []const u8, scratch: []u8) ![]const u8 {
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update(ws_guid);
    hasher.final(&digest);
    return std.base64.standard.Encoder.encode(scratch, &digest);
}

fn readHeaderLine(reader: *Io.Reader) ![]const u8 {
    const line = try reader.takeDelimiterInclusive('\n');
    return std.mem.trimEnd(u8, line, "\r\n");
}

fn stdinPump(context: *Context) void {
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(context.gpa);

    while (true) {
        // Do exactly one blocking read per iteration. `readSliceShort` would
        // keep reading until it fills the buffer, which would hold back every
        // request until the parent closed stdin.
        if (context.stdin_reader.bufferedLen() == 0) {
            context.stdin_reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    std.debug.print("codex-stdio2ws: stdin read failed: {s}\n", .{@errorName(err)});
                    std.process.exit(1);
                },
            };
        }
        const available = context.stdin_reader.buffered();
        if (available.len == 0) continue;
        pending.appendSlice(context.gpa, available) catch oom();
        context.stdin_reader.toss(available.len);

        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline| {
            const message = std.mem.trim(u8, pending.items[0..newline], " \t\r");
            if (message.len > 0) {
                sendFrame(context, op_text, message) catch |err| {
                    std.debug.print(
                        "codex-stdio2ws: socket write failed: {s}\n",
                        .{@errorName(err)},
                    );
                    std.process.exit(1);
                };
            }
            pending.replaceRange(context.gpa, 0, newline + 1, &.{}) catch oom();
        }
    }

    // stdin closed: the parent wants us gone. Say goodbye and leave; waiting
    // for the server's close frame would only delay the shutdown it expects.
    context.closing.store(true, .release);
    sendFrame(context, op_close, &.{}) catch {};
    std.process.exit(0);
}

fn socketPump(context: *Context) !void {
    var fragments: std.ArrayList(u8) = .empty;
    defer fragments.deinit(context.gpa);
    var fragmented_opcode: u8 = 0;

    while (true) {
        const frame = try readFrame(context);
        defer context.gpa.free(frame.payload);
        debugLog(context, "recv opcode=0x{x} fin={} len={}", .{ frame.opcode, frame.fin, frame.payload.len });

        switch (frame.opcode) {
            op_text, op_binary => {
                if (frame.fin) {
                    try deliver(context, frame.payload);
                } else {
                    fragmented_opcode = frame.opcode;
                    try fragments.appendSlice(context.gpa, frame.payload);
                }
            },
            op_continuation => {
                try fragments.appendSlice(context.gpa, frame.payload);
                if (frame.fin) {
                    if (fragmented_opcode == op_text or fragmented_opcode == op_binary) {
                        try deliver(context, fragments.items);
                    }
                    fragments.clearRetainingCapacity();
                    fragmented_opcode = 0;
                }
            },
            op_ping => try sendFrame(context, op_pong, frame.payload),
            op_pong => {},
            op_close => {
                try sendFrame(context, op_close, frame.payload);
                return error.ServerClosed;
            },
            else => {},
        }
    }
}

fn deliver(context: *Context, payload: []const u8) !void {
    debugLog(context, "deliver len={}", .{payload.len});
    try context.stdout_writer.writeAll(payload);
    try context.stdout_writer.writeAll("\n");
    try context.stdout_writer.flush();
}

fn readFrame(context: *Context) !Frame {
    const reader = context.socket_reader;
    const first = try reader.takeByte();
    const second = try reader.takeByte();

    const fin = first & 0x80 != 0;
    const opcode = first & 0x0F;
    const masked = second & 0x80 != 0;
    var length: u64 = second & 0x7F;

    if (length == 126) {
        length = std.mem.readInt(u16, try reader.takeArray(2), .big);
    } else if (length == 127) {
        length = std.mem.readInt(u64, try reader.takeArray(8), .big);
    }
    if (length > max_payload_bytes) return error.FrameTooLarge;

    var mask: [4]u8 = undefined;
    if (masked) mask = (try reader.takeArray(4)).*;

    const payload = try reader.readAlloc(context.gpa, @intCast(length));
    errdefer context.gpa.free(payload);
    if (masked) {
        for (payload, 0..) |*byte, index| byte.* ^= mask[index % mask.len];
    }
    return .{ .opcode = opcode, .fin = fin, .payload = payload };
}

const Frame = struct {
    opcode: u8,
    fin: bool,
    payload: []u8,
};

fn sendFrame(context: *Context, opcode: u8, payload: []const u8) !void {
    debugLog(context, "send opcode=0x{x} len={}", .{ opcode, payload.len });
    context.write_mutex.lockUncancelable(context.io);
    defer context.write_mutex.unlock(context.io);
    var mask: [4]u8 = undefined;
    try Io.randomSecure(context.io, &mask);
    try writeFrame(context.socket_writer, opcode, payload, mask);
}

/// Frames written by a client must be masked (RFC 6455 section 5.3).
fn writeFrame(writer: *Io.Writer, opcode: u8, payload: []const u8, mask: [4]u8) !void {
    var header: [14]u8 = undefined;
    header[0] = 0x80 | opcode;

    var header_len: usize = 2;
    if (payload.len < 126) {
        header[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else if (payload.len <= std.math.maxInt(u16)) {
        header[1] = 0x80 | 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        header_len = 4;
    } else {
        header[1] = 0x80 | 127;
        std.mem.writeInt(u64, header[2..10], payload.len, .big);
        header_len = 10;
    }

    @memcpy(header[header_len..][0..mask.len], &mask);
    header_len += mask.len;

    try writer.writeAll(header[0..header_len]);

    // Mask in bounded chunks: JSON-RPC payloads can be large and the process
    // should not need a full copy of every message.
    var chunk: [16 * 1024]u8 = undefined;
    var offset: usize = 0;
    while (offset < payload.len) {
        const count = @min(chunk.len, payload.len - offset);
        for (payload[offset..][0..count], 0..) |byte, index| {
            chunk[index] = byte ^ mask[(offset + index) % mask.len];
        }
        try writer.writeAll(chunk[0..count]);
        offset += count;
    }
    try writer.flush();
}

fn oom() noreturn {
    fatal("out of memory", .{});
}

test "expectedAccept matches the RFC 6455 example" {
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    var scratch: [std.base64.standard.Encoder.calcSize(std.crypto.hash.Sha1.digest_length)]u8 = undefined;
    try std.testing.expectEqualStrings(
        "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        try expectedAccept(key, &scratch),
    );
}

fn testContext(reader: *Io.Reader) Context {
    return .{
        .io = undefined,
        .gpa = std.testing.allocator,
        .debug = false,
        .socket_reader = reader,
        .socket_writer = undefined,
        .stdin_reader = undefined,
        .stdout_writer = undefined,
    };
}

test "client frames round-trip through writeFrame and readFrame" {
    const allocator = std.testing.allocator;
    const payload = "{\"id\":1,\"method\":\"initialize\"}";
    const mask = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };

    var allocating: Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();
    try writeFrame(&allocating.writer, op_text, payload, mask);

    var reader = Io.Reader.fixed(allocating.written());
    var context = testContext(&reader);
    const frame = try readFrame(&context);
    defer allocator.free(frame.payload);

    try std.testing.expectEqual(op_text, frame.opcode);
    try std.testing.expect(frame.fin);
    try std.testing.expectEqualStrings(payload, frame.payload);
}

test "writeFrame uses the 16-bit extended length above 125 bytes" {
    const allocator = std.testing.allocator;
    const payload = "x" ** 1000;
    const mask = [4]u8{ 0, 0, 0, 0 };

    var allocating: Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();
    try writeFrame(&allocating.writer, op_text, payload, mask);

    const written = allocating.written();
    try std.testing.expectEqual(@as(u8, 0x81), written[0]);
    try std.testing.expectEqual(@as(u8, 0x80 | 126), written[1]);
    try std.testing.expectEqual(@as(u16, 1000), std.mem.readInt(u16, written[2..4], .big));

    var reader = Io.Reader.fixed(written);
    var context = testContext(&reader);
    const frame = try readFrame(&context);
    defer allocator.free(frame.payload);
    try std.testing.expectEqualStrings(payload, frame.payload);
}

test "readFrame accepts an unmasked 64-bit length server frame" {
    const allocator = std.testing.allocator;
    const payload_len = 70_000;
    const message = try allocator.alloc(u8, 10 + payload_len);
    defer allocator.free(message);
    message[0] = 0x81;
    message[1] = 127;
    std.mem.writeInt(u64, message[2..10], payload_len, .big);
    @memset(message[10..], 'a');

    var reader = Io.Reader.fixed(message);
    var context = testContext(&reader);
    const frame = try readFrame(&context);
    defer allocator.free(frame.payload);
    try std.testing.expectEqual(@as(usize, payload_len), frame.payload.len);
    try std.testing.expectEqual(@as(u8, 'a'), frame.payload[payload_len - 1]);
}
