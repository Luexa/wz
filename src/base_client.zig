const std = @import("std");

const wz = @import("main.zig");
const MessageParser = wz.MessageParser;

const base64 = std.base64;
const ascii = std.ascii;
const math = std.math;
const time = std.time;
const mem = std.mem;
const http = std.http;

const Random = std.rand.Random;

const Sha1 = std.crypto.hash.Sha1;

const assert = std.debug.assert;

pub fn baseClient(buffer: []u8, reader: anytype, writer: anytype, prng: Random) BaseClient(@TypeOf(reader), @TypeOf(writer)) {
    assert(buffer.len >= 16);

    return BaseClient(@TypeOf(reader), @TypeOf(writer)).init(buffer, reader, writer, prng);
}

pub const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
pub const handshake_key_length = 16;
pub const handshake_key_length_b64 = base64.standard.Encoder.calcSize(handshake_key_length);
pub const encoded_key_length_b64 = base64.standard.Encoder.calcSize(Sha1.digest_length);

fn checkHandshakeKey(original: []const u8, received: []const u8) bool {
    var hash = Sha1.init(.{});
    hash.update(original);
    hash.update(websocket_guid);

    var hashed_key: [Sha1.digest_length]u8 = undefined;
    hash.final(&hashed_key);

    var encoded: [encoded_key_length_b64]u8 = undefined;
    _ = base64.standard.Encoder.encode(&encoded, &hashed_key);

    return mem.eql(u8, &encoded, received);
}

pub const HttpWebsocketClient = BaseClient(http.Client.Connection.Reader, http.Client.Connection.Writer);

pub const Handshake = struct {
    prng: Random,
    // request: http.Client.Request,
    handshake_key: [handshake_key_length_b64]u8 = undefined,

    // pub const InitError = http.Client.RequestError;
    // pub const StartError = http.Client.Connection.WriteError;
    // pub const WaitError = http.Client.Request.WaitError || error{ InvalidStatus, FailedChallenge, UpgradeFailed };

    pub fn init(prng: Random) Handshake {
        return .{ .prng = prng };
    }

    // pub fn init(
    //     http_client: *http.Client,
    //     uri: std.Uri,
    //     headers: http.Headers,
    //     prng: Random,
    // ) InitError!Handshake {
    //     if (!mem.eql(u8, "ws", uri.scheme) and !mem.eql(u8, "wss", uri.scheme)) return error.UnsupportedUrlScheme;
    //     return .{
    //         .prng = prng,
    //         .request = try http_client.request(.GET, uri, headers, .{
    //             .handle_redirects = false,
    //         }),
    //     };
    // }

    // pub fn deinit(handshake: *Handshake) void {
    //     handshake.request.deinit();
    //     handshake.* = undefined;
    // }    

    fn generateKey(handshake: *Handshake) void {
        var raw_key: [handshake_key_length]u8 = undefined;
        handshake.prng.bytes(&raw_key);
        _ = base64.standard.Encoder.encode(&handshake.handshake_key, &raw_key);
    }

    pub fn writeStatusLine(writer: anytype, uri: std.Uri) !void {
        try writer.writeAll("GET ");
        try writer.print("{/}", .{ uri });
        try writer.writeAll(" HTTP/1.1\r\n");
    }

    pub fn writeHost(writer: anytype, uri: std.Uri) !void {
        try writer.writeAll("Host: ");
        try writer.writeAll(uri.host.?);
        try writer.writeAll("\r\n");
    }

    pub fn writeUserAgent(writer: anytype) !void {
        try writer.writeAll("User-Agent: wz/0.0.8 (zig, std.http)\r\n");
    }

    pub fn writeWebsocketHeaders(handshake: *Handshake, writer: anytype) !void {
        handshake.generateKey();

        try writer.writeAll("Connection: Upgrade\r\n");
        try writer.writeAll("Upgrade: websocket\r\n");
        try writer.writeAll("Sec-WebSocket-Version: 13\r\n");
        try writer.writeAll("Sec-WebSocket-Key: ");
        try writer.writeAll(&handshake.handshake_key);
        try writer.writeAll("\r\n");
    }

    pub fn finishHeaders(writer: anytype) !void {
        try writer.writeAll("\r\n");
    }

    pub fn validateResponse(
        handshake: *const Handshake,
        status: http.Status,
        connection_header: []const u8,
        sec_websocket_accept_header: []const u8,
    ) !void {
        if (status != .switching_protocols) return error.InvalidStatus;
        if (!ascii.eqlIgnoreCase("upgrade", connection_header)) return error.UpgradeFailed;
        if (!checkHandshakeKey(&handshake.handshake_key, sec_websocket_accept_header)) return error.FailedChallenge;
    }
};

pub const HttpHandshakeClient = struct {
    handshake: Handshake,
    request: http.Client.Request,

    pub fn init(
        http_client: *http.Client,
        uri: std.Uri,
        headers: http.Headers,
        prng: Random,
    ) !HttpHandshakeClient {
        if (!mem.eql(u8, "ws", uri.scheme) and !mem.eql(u8, "wss", uri.scheme)) return error.UnsupportedUrlScheme;
        return .{
            .handshake = Handshake.init(prng),
            .request = try http_client.request(.GET, uri, headers, .{
                .handle_redirects = false,
            }),
        };
    }

    pub fn deinit(handshake_client: *HttpHandshakeClient) void {
        handshake_client.request.deinit();
        handshake_client.* = undefined;
    }

    pub fn start(handshake_client: *HttpHandshakeClient) !void {
        var buffered = std.io.bufferedWriter(handshake_client.request.connection.?.data.writer());
        const writer = buffered.writer();

        const headers = &handshake_client.request.headers;

        try Handshake.writeStatusLine(writer, handshake_client.request.uri);
        if (!headers.contains("host")) {
            try Handshake.writeHost(writer, handshake_client.request.uri);
        }
        if (!headers.contains("user-agent")) {
            try Handshake.writeUserAgent(writer);
        }
        try handshake_client.handshake.writeWebsocketHeaders(writer);
        try writer.print("{}", .{ headers.* });
        try Handshake.finishHeaders(writer);

        try buffered.flush();
    }

    pub fn wait(handshake_client: *HttpHandshakeClient) !void {
        try handshake_client.request.wait();
        const response = &handshake_client.request.response;

        const connection_header = response.headers.getFirstValue("connection") orelse return error.UpgradeFailed;
        const sec_websocket_accept_header = response.headers.getFirstValue("sec-websocket-accept") orelse return error.UpgradeFailed;
        try handshake_client.handshake.validateResponse(
            response.status,
            connection_header,
            sec_websocket_accept_header,
        );
    }

    pub fn websocketClient(handshake_client: *HttpHandshakeClient, read_buffer: []u8) !HttpWebsocketClient {
        return baseClient(
            read_buffer,
            handshake_client.request.connection.?.data.reader(),
            handshake_client.request.connection.?.data.writer(),
            handshake_client.handshake.prng,
        );
    }
};

pub fn BaseClient(comptime Reader: type, comptime Writer: type) type {
    const ParserType = MessageParser(Reader);

    return struct {
        const Self = @This();

        read_buffer: []u8,
        parser: ParserType,
        writer: Writer,

        current_mask: [4]u8 = std.mem.zeroes([4]u8),
        mask_index: usize = 0,

        payload_size: usize = 0,
        payload_index: usize = 0,

        prng: Random,

        // Whether a reader is currently using the read_buffer. if true, parser.next should NOT be called since the
        // reader expects all of the data.
        self_contained: bool = false,

        pub fn init(buffer: []u8, input: Reader, output: Writer, prng: Random) Self {
            return .{
                .parser = ParserType.init(buffer, input),
                .read_buffer = buffer,
                .writer = output,
                .prng = prng,
            };
        }

        pub const WriteHeaderError = error{ MissingMask } || Writer.Error;
        pub fn writeHeader(self: *Self, header: wz.MessageHeader) WriteHeaderError!void {
            var bytes: [14]u8 = undefined;
            var len: usize = 2;

            bytes[0] = @intFromEnum(header.opcode);

            if (header.fin) bytes[0] |= 0x80;
            if (header.rsv1) bytes[0] |= 0x40;
            if (header.rsv2) bytes[0] |= 0x20;
            if (header.rsv3) bytes[0] |= 0x10;

            // client messages MUST be masked.
            var mask: [4]u8 = undefined;
            if (header.mask) |m| {
                @memcpy(&mask, &m);
            } else {
                self.prng.bytes(&mask);
            }

            bytes[1] = 0x80;

            if (header.length < 126) {
                bytes[1] |= @truncate(header.length);
            } else if (header.length < 0x10000) {
                bytes[1] |= 126;

                mem.writeIntBig(u16, bytes[2..4], @as(u16, @truncate(header.length)));
                len += 2;
            } else {
                bytes[1] |= 127;

                mem.writeIntBig(u64, bytes[2..10], header.length);
                len += 8;
            }

            @memcpy(bytes[len .. len + 4], &mask);
            len += 4;

            try self.writer.writeAll(bytes[0..len]);

            self.current_mask = mask;
            self.mask_index = 0;
        }

        pub fn writeChunkRaw(self: *Self, payload: []const u8) Writer.Error!void {
            try self.writer.writeAll(payload);
        }

        const mask_buffer_size = 1024;
        pub fn writeChunk(self: *Self, payload: []const u8) Writer.Error!void {
            var buffer: [mask_buffer_size]u8 = undefined;
            var index: usize = 0;

            for (payload, 0..) |c, i| {
                buffer[index] = c ^ self.current_mask[(i + self.mask_index) % 4];

                index += 1;
                if (index == mask_buffer_size) {
                    try self.writer.writeAll(&buffer);

                    index = 0;
                }
            }

            if (index > 0) {
                try self.writer.writeAll(buffer[0..index]);
            }

            self.mask_index += payload.len;
        }

        pub fn next(self: *Self) ParserType.NextError!?wz.message_parser.Event {
            assert(!self.self_contained);

            return self.parser.next();
        }

        pub const ReadNextError = ParserType.NextError;
        pub fn readNextChunk(self: *Self) ReadNextError!?wz.message_parser.ChunkEvent {
            if (self.parser.state != .chunk) return null;
            assert(!self.self_contained);

            if (try self.parser.next()) |event| {
                switch (event) {
                    .chunk => |chunk| return chunk,
                    .header => unreachable,
                }
            }

            return null;
        }

        pub fn flushReader(self: *Self) ReadNextError!void {
            var buffer: [256]u8 = undefined;
            while (self.self_contained) {
                _ = try self.readNextChunkBuffer(&buffer);
            }
        }

        pub fn readNextChunkBuffer(self: *Self, buffer: []u8) ReadNextError!usize {
            if (self.payload_index >= self.payload_size) {
                if (self.parser.state != .chunk) {
                    self.self_contained = false;
                    return 0;
                }

                self.self_contained = true;

                if (try self.parser.next()) |event| {
                    switch (event) {
                        .chunk => |chunk| {
                            self.payload_index = 0;
                            self.payload_size = chunk.data.len;
                        },

                        .header => unreachable,
                    }
                } else unreachable;
            }

            const size = @min(buffer.len, self.payload_size - self.payload_index);
            const end = self.payload_index + size;

            @memcpy(buffer[0..size], self.read_buffer[self.payload_index..end]);
            self.payload_index = end;

            return size;
        }

        pub const PayloadReader = std.io.Reader(*Self, ReadNextError, readNextChunkBuffer);

        pub fn reader(self: *Self) PayloadReader {
            assert(self.parser.state == .chunk);

            return .{ .context = self };
        }
    };
}

const testing = std.testing;

test {
    testing.refAllDecls(Handshake);
    testing.refAllDecls(HttpHandshakeClient);
    testing.refAllDecls(HttpWebsocketClient);
}

// test "example usage" {
//     if (true) return error.SkipZigTest;

//     var buffer: [256]u8 = undefined;
//     var stream = std.io.fixedBufferStream(&buffer);

//     const reader = stream.reader();
//     const writer = stream.writer();

//     const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
//     var prng = std.rand.DefaultPrng.init(seed);

//     var handshake = handshakeClient(&buffer, reader, writer, prng.random());
//     try handshake.writeStatusLine("/");
//     try handshake.writeHeaderValue("Host", "echo.websocket.events");
//     try handshake.finishHeaders();

//     if (try handshake.wait()) {
//         var client = handshake.socket();

//         try client.writeHeader(.{
//             .opcode = .binary,
//             .length = 4,
//         });

//         try client.writeChunk("abcd");

//         while (try client.next()) |event| {
//             _ = event;
//             // directly from the parser
//         }
//     }
// }
