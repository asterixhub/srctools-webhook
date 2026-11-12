const std = @import("std");
const builtin = @import("builtin");

/// A single check normally takes a few seconds. If it does not finish within
/// this window, terminate so Railway's ON_FAILURE policy starts a fresh
/// container; the persisted state makes the restart safe.
pub const CHECK_TIMEOUT_SECONDS: isize = 120;

pub fn install() void {
    if (builtin.os.tag == .linux) {
        const H = struct {
            fn on(_: std.posix.SIG) callconv(.c) void {
                const msg = "error: [Worker] Watchdog timeout; exiting for restart\n";
                _ = std.os.linux.write(std.posix.STDERR_FILENO, msg.ptr, msg.len);
                std.os.linux.exit_group(1);
            }
        };
        const act = std.posix.Sigaction{
            .handler = .{ .handler = &H.on },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.ALRM, &act, null);
    }
}

pub fn arm(seconds: isize) void {
    if (builtin.os.tag == .linux) {
        const spec = std.os.linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = seconds, .nsec = 0 },
        };
        _ = std.os.linux.setitimer(@intFromEnum(std.os.linux.ITIMER.REAL), &spec, null);
    }
}

pub fn disarm() void {
    if (builtin.os.tag == .linux) {
        const spec = std.os.linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = 0, .nsec = 0 },
        };
        _ = std.os.linux.setitimer(@intFromEnum(std.os.linux.ITIMER.REAL), &spec, null);
    }
}
