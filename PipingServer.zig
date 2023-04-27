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
    std.debug.print("{s} {s}\n", .{ @tagName(res.request.method), res.request.target });

    const uri = try std.Uri.parseWithoutScheme(res.request.target);

    // Top page
    if (res.request.method == .GET and std.mem.eql(u8, uri.path, "/")) {
        const body: []const u8 = "Piping Server in Zig (experimental)\n";
        try res.headers.append("Content-Type", "text/plain");
        try res.headers.append("Connection", "close");
        res.transfer_encoding = .{ .content_length = body.len };
        // Send respose header
        try res.do();
        _ = try res.write(body);
        try res.finish();
        res.reset();
        return;
    }

    // Handle sender
    if (res.request.method == .POST or res.request.method == .PUT) {
        std.debug.print("handling sender {s} ...\n", .{res.request.target});
        const pipe = try self.getPipe(uri.path);
        res.transfer_encoding = .chunked;
        try res.headers.append("Connection", "close");
        // Send respose header
        try res.do();
        _ = try res.write("[INFO] Waiting for 1 receiver(s)...\n");
        const receiver_res: *std.http.Server.Response = pipe.receiver_res_channel.get();
        // TODO: consider timing of removinig
        self.removePipe(uri.path);
        _ = try res.write("[INFO] A receiver was connected.\n");
        _ = try res.write("[INFO] Start sending to 1 receiver(s)!\n");

        if (res.request.transfer_encoding == @as(?std.http.TransferEncoding, .chunked)) {
            receiver_res.transfer_encoding = .chunked;
        } else if (res.request.content_length) |sender_content_length| {
            receiver_res.transfer_encoding = .{ .content_length = sender_content_length };
        }
        try receiver_res.headers.append("Connection", "close");
        // TODO: Transfer Content-Type
        try receiver_res.do();

        var buf: [65536]u8 = undefined;
        while (true) {
            const size = res.read(&buf) catch |err| {
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
        receiver_res.reset();

        _ = try res.write("[INFO] Sent successfully!\n");
        try res.finish();
        res.reset();

        return;
    }

    // Handle receiver
    if (res.request.method == .GET) {
        std.debug.print("handling receiver {s} ...\n", .{res.request.target});
        const pipe = try self.getPipe(uri.path);
        pipe.receiver_res_channel.put(res);
        return;
    }
}
