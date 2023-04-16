const std = @import("std");

// TODO: Remove this and use std.event.Channel() but std.event.Channel causes "error: async has not been implemented in the self-hosted compiler yet" in pre-built 0.11.0-dev.2582+25e3851fe
pub fn BlockingChannel(comptime T: type) type {
    return struct {
        // locks put()
        put_sema: std.Thread.Semaphore,
        // locks get()
        get_sema: std.Thread.Semaphore,
        value: T,

        pub fn init() @This() {
            return @This(){
                .put_sema = std.Thread.Semaphore{ .permits = 1 },
                .get_sema = std.Thread.Semaphore{ .permits = 0 },
                .value = undefined,
            };
        }

        pub fn put(self: *@This(), v: T) void {
            self.put_sema.wait();
            self.value = v;
            self.get_sema.post();
        }

        pub fn get(self: *@This()) T {
            self.get_sema.wait();
            const value = self.value;
            self.put_sema.post();
            return value;
        }
    };
}

test "put and get" {
    var ch = BlockingChannel(i32).init();
    ch.put(1);
    try std.testing.expect(ch.get() == 1);
}

test "get and put" {
    var ch = BlockingChannel(i32).init();
    var got_value: ?i32 = null;
    var t1 = try std.Thread.spawn(.{}, (struct {
        fn apply(ch2: *BlockingChannel(i32), got_value_ptr: *?i32) void {
            got_value_ptr.* = ch2.get();
        }
    }).apply, .{ &ch, &got_value });
    ch.put(1);
    t1.join();
    try std.testing.expect(got_value == @as(?i32, 1));
}

test "put twice and get twice" {
    var ch = BlockingChannel(i32).init();
    ch.put(1);
    _ = try std.Thread.spawn(.{}, (struct {
        fn apply(ch2: *BlockingChannel(i32)) void {
            ch2.put(2);
        }
    }).apply, .{&ch});
    try std.testing.expect(ch.get() == 1);
    try std.testing.expect(ch.get() == 2);
}
