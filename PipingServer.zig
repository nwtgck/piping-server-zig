const std = @import("std");
const BlockingChannel = @import("./blocking_channel.zig").BlockingChannel;

const Pipe = struct { receiver_res_channel: *BlockingChannel(*std.http.Server.Response) };

allocator: std.mem.Allocator,
path_to_pipe: std.StringHashMap(Pipe),
path_to_pipe_mutex: std.Thread.Mutex,

pub fn init(allocator: std.mem.Allocator) @This() {
    return .{
        .allocator = allocator,
        .path_to_pipe = std.StringHashMap(Pipe).init(allocator),
        .path_to_pipe_mutex = std.Thread.Mutex{},
    };
}

fn getPipe(self: *@This(), path: []const u8) !Pipe {
    // TODO: better lock
    self.path_to_pipe_mutex.lock();
    defer self.path_to_pipe_mutex.unlock();
    return self.path_to_pipe.get(path) orelse {
        const chan_ptr = try self.allocator.create(BlockingChannel(*std.http.Server.Response));
        chan_ptr.* = BlockingChannel(*std.http.Server.Response).init();
        const new_pipe = Pipe{ .receiver_res_channel = chan_ptr };
        try self.path_to_pipe.put(path, new_pipe);
        return new_pipe;
    };
}

fn removePipe(self: *@This(), path: []const u8) void {
    // TODO: better lock
    self.path_to_pipe_mutex.lock();
    defer self.path_to_pipe_mutex.unlock();
    const pipe: ?Pipe = self.path_to_pipe.fetchRemove(path).?.value;
    if (pipe) |pipe2| {
        self.allocator.destroy(pipe2.receiver_res_channel);
    }
}

// TODO: close detection and handle it
pub fn handle(self: *@This(), res: *std.http.Server.Response) !void {
    errdefer res.reset();

    // Wait for header read
    try res.wait();
    std.debug.print("{s} {s}\n", .{ @tagName(res.request.headers.method), res.request.headers.target });

    const uri = try std.Uri.parseWithoutScheme(res.request.headers.target);

    // Top page
    if (res.request.headers.method == .GET and std.mem.eql(u8, uri.path, "/")) {
        const body: []const u8 = "Piping Server in Zig (experimental)\n";
        res.headers.custom = &[_]std.http.CustomHeader{.{
            .name = "Content-Type",
            .value = "text/plain",
        }};
        res.headers.transfer_encoding = .{ .content_length = body.len };
        res.headers.connection = res.request.headers.connection;
        // Send respose header
        try res.do();
        _ = try res.write(body);
        try res.finish();
        res.reset();
        return;
    }

    // Handle sender
    if (res.request.headers.method == .POST or res.request.headers.method == .PUT) {
        std.debug.print("handling sender {s} ...\n", .{res.request.headers.target});
        const pipe = try self.getPipe(uri.path);
        res.headers.transfer_encoding = .chunked;
        res.headers.connection = res.request.headers.connection;
        // Send respose header
        try res.do();
        _ = try res.write("[INFO] Waiting for 1 receiver(s)...\n");
        const receiver_res: *std.http.Server.Response = pipe.receiver_res_channel.get();
        // TODO: consider timing of removinig
        self.removePipe(uri.path);
        _ = try res.write("[INFO] A receiver was connected.\n");
        _ = try res.write("[INFO] Start sending to 1 receiver(s)!\n");

        if (res.request.headers.transfer_encoding == @as(?std.http.TransferEncoding, .chunked)) {
            receiver_res.headers.transfer_encoding = .chunked;
        } else if (res.request.headers.content_length) |sender_content_length| {
            receiver_res.headers.transfer_encoding = .{ .content_length = sender_content_length };
        }
        receiver_res.headers.connection = receiver_res.request.headers.connection;
        // TODO: Transfer Content-Type
        try receiver_res.do();

        var buf: [65536]u8 = undefined;
        while (true) {
            const size = workaroundTransferRead(res, &buf) catch |err| {
                std.debug.print("read error: {}\n", .{err});
                return err;
            };
            // TODO: OK?, but .EndOfStream not returned
            if (size == 0) {
                break;
            }
            _ = try receiver_res.write(buf[0..size]);
        }
        try receiver_res.finish();
        // NOTE: Workaround of https://github.com/ziglang/zig/pull/15298
        try receiver_res.connection.writeAll("\r\n");
        receiver_res.reset();

        _ = try res.write("[INFO] Sent successfully!\n");
        try res.finish();
        // NOTE: Workaround of https://github.com/ziglang/zig/pull/15298
        try res.connection.writeAll("\r\n");
        res.reset();

        return;
    }

    // Handle receiver
    if (res.request.headers.method == .GET) {
        std.debug.print("handling receiver {s} ...\n", .{res.request.headers.target});
        const pipe = try self.getPipe(uri.path);
        pipe.receiver_res_channel.put(res);
        return;
    }
}

// TODO: Replace this entire function to the res.transferRead() if `piping-server-check --http1.1 --server-schemaless-url //localhost:8080 --check post_first_byte_by_byte_streaming` works
fn workaroundTransferRead(res: *std.http.Server.Response, buf: []u8) !usize {
    if (res.request.parser.isComplete()) return 0;

    var index: usize = 0;
    while (index == 0) {
        // Workaround of https://github.com/ziglang/zig/issues/15295
        if (res.request.parser.done) {
            res.request.parser.state = .finished;
        }
        const amt = try res.request.parser.read(&res.connection, buf[index..], false);
        if (amt == 0 and res.request.parser.isComplete()) break;
        index += amt;
    }

    return index;
}
