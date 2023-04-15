const std = @import("std");

// TODO: Remove this and use std.event.Channel() but std.event.Channel causes "error: async has not been implemented in the self-hosted compiler yet" in pre-built 0.11.0-dev.2582+25e3851fe
pub fn BlockingOneshotChannel(comptime T: type) type {
    return struct {
        sema: std.Thread.Semaphore,
        value: T,

        pub fn init() @This() {
            var sema = std.Thread.Semaphore{};
            sema.permits = 0;
            return @This(){
                .sema = sema,
                .value = undefined,
            };
        }

        // TODO: put() twice should be blocked but removing an existing value
        pub fn put(self: *@This(), v: T) void {
            self.sema.post();
            self.value = v;
        }

        pub fn get(self: *@This()) T {
            self.sema.wait();
            return self.value;
        }
    };
}
