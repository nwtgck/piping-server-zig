const std = @import("std");
const BlockingOneshotChannel = @import("./BlockingOneshotChannel.zig").BlockingOneshotChannel;

const Pipe = struct { receiver_res_channel: *BlockingOneshotChannel(*std.http.Server.Response) };

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
        var chan_ptr = try self.allocator.create(BlockingOneshotChannel(*std.http.Server.Response));
        chan_ptr.* = BlockingOneshotChannel(*std.http.Server.Response).init();
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

pub fn handle(self: *@This(), res: *std.http.Server.Response) !void {
    errdefer res.reset();

    // Wait for header read
    try res.wait();
    std.debug.print("{} {s}\n", .{ res.request.headers.method, res.request.headers.target });

    // Top page
    if (res.request.headers.method == .GET and std.mem.eql(u8, res.request.headers.target, "/")) {
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
        var pipe = try self.getPipe(res.request.headers.target);
        res.headers.transfer_encoding = .chunked;
        res.headers.connection = res.request.headers.connection;
        // Send respose header
        try res.do();
        _ = try res.write("[INFO] Waiting for 1 receiver(s)...\n");
        const receiver_res: *std.http.Server.Response = pipe.receiver_res_channel.get();
        // TODO: consider timing of removinig
        self.removePipe(res.request.headers.target);
        _ = try res.write("[INFO] A receiver was connected.\n");
        _ = try res.write("[INFO] Start sending to 1 receiver(s)!\n");

        // TODO: How to inline .chunked?
        const chunked: ?std.http.TransferEncoding = .chunked;
        if (res.request.headers.transfer_encoding == chunked) {
            receiver_res.headers.transfer_encoding = .chunked;
        } else if (res.request.headers.content_length) |sender_content_length| {
            receiver_res.headers.transfer_encoding = .{ .content_length = sender_content_length };
        }
        receiver_res.headers.connection = receiver_res.request.headers.connection;
        try receiver_res.do();

        var buf: [65536]u8 = undefined;
        while (true) {
            // Workaround of https://github.com/ziglang/zig/issues/15295
            if (res.request.parser.done) {
                res.request.parser.state = .finished;
            }
            const size = res.transferRead(&buf) catch |err| {
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
        // TODO: .reset() causes "curl: (18) transfer closed with outstanding read data remaining" in the client side but without this, client never ends
        receiver_res.reset();

        _ = try res.write("[INFO] Sent successfully!\n");
        try res.finish();
        // TODO: .reset() causes "curl: (18) transfer closed with outstanding read data remaining" in the client side but without this, client never ends
        res.reset();

        return;
    }

    // Handle receiver
    if (res.request.headers.method == .GET) {
        std.debug.print("handling receiver {s} ...\n", .{res.request.headers.target});
        var pipe = try self.getPipe(res.request.headers.target);
        pipe.receiver_res_channel.put(res);
        return;
    }
}
