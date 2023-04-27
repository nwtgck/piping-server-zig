const std = @import("std");
const PipingServer = @import("./PipingServer.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const http_port: u16 = blk: {
        var args = std.process.args();
        _ = args.next();
        if (args.next()) |port_str| {
            break :blk try std.fmt.parseInt(u16, port_str, 10);
        }
        break :blk 8080;
    };

    const max_header_size = 8192;
    var server = std.http.Server.init(allocator, .{ .reuse_address = true });
    defer server.deinit();

    const address = try std.net.Address.parseIp("0.0.0.0", http_port);
    std.debug.print("Listening on {} ...\n", .{address});
    try server.listen(address);

    var pipingServer = PipingServer.init(allocator);

    while (true) {
        const res = try server.accept(.{ .dynamic = max_header_size });

        const thread = try std.Thread.spawn(.{}, (struct {
            fn apply(s: *PipingServer, r: *std.http.Server.Response) !void {
                try s.handle(r);
            }
        }).apply, .{ &pipingServer, res });
        thread.detach();
    }
}
