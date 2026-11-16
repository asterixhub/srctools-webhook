const std = @import("std");
const builtin = @import("builtin");

/// Live bytes requested from the worker allocator, filled in by main once the
/// allocator exists.
pub var heap_requested: *const usize = undefined;

pub const Sample = struct {
    rss_kb: u64 = 0,
    anon_kb: u64 = 0,
    file_kb: u64 = 0,
    shmem_kb: u64 = 0,
    vsz_kb: u64 = 0,
    threads: u64 = 0,
    heap_kb: u64 = 0,
};

/// Reads the worker's resident set size, memory split and thread count from
/// procfs. Only Linux exposes these numbers; elsewhere only the heap counter is
/// useful.
pub fn sample(io: std.Io) Sample {
    var out: Sample = .{};
    out.heap_kb = heap_requested.* / 1024;
    if (builtin.os.tag != .linux) return out;

    var file = std.Io.Dir.openFileAbsolute(io, "/proc/self/status", .{}) catch return out;
    defer file.close(io);

    var read_buf: [1024]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    const data = reader.interface.allocRemaining(std.heap.page_allocator, .limited(8192)) catch return out;
    defer std.heap.page_allocator.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "VmRSS:")) {
            out.rss_kb = firstNumber(line) orelse 0;
        } else if (std.mem.startsWith(u8, line, "RssAnon:")) {
            out.anon_kb = firstNumber(line) orelse 0;
        } else if (std.mem.startsWith(u8, line, "RssFile:")) {
            out.file_kb = firstNumber(line) orelse 0;
        } else if (std.mem.startsWith(u8, line, "RssShmem:")) {
            out.shmem_kb = firstNumber(line) orelse 0;
        } else if (std.mem.startsWith(u8, line, "VmSize:")) {
            out.vsz_kb = firstNumber(line) orelse 0;
        } else if (std.mem.startsWith(u8, line, "Threads:")) {
            out.threads = firstNumber(line) orelse 0;
        }
    }
    return out;
}

fn firstNumber(line: []const u8) ?u64 {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    _ = it.next() orelse return null;
    const value = it.next() orelse return null;
    return std.fmt.parseInt(u64, value, 10) catch null;
}
