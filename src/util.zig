const std = @import("std");

pub const Value = std.json.Value;
pub const Object = std.json.ObjectMap;

pub const Aborted = error{Aborted};

/// The process-wide default `Io`, initialized by the startup code. Used only
/// for the monotonic/real clocks and blocking sleeps, which are independent of
/// whichever `Io` backend the app wires up for HTTP and filesystem work.
inline fn defaultIo() std.Io {
    return std.Options.debug_io;
}

pub fn nowMs() i64 {
    return std.Io.Clock.real.now(defaultIo()).toMilliseconds();
}

/// Sleep `ms` milliseconds, waking early (returning error.Aborted) if the
/// shutdown flag is set. Checked in 100 ms chunks so SIGTERM is responsive.
pub fn sleepMs(ms: i64, shutdown: *std.atomic.Value(bool)) Aborted!void {
    var remaining = ms;
    while (remaining > 0) {
        if (shutdown.load(.acquire)) return error.Aborted;
        const chunk = @min(remaining, 100);
        defaultIo().sleep(std.Io.Duration.fromMilliseconds(chunk), .awake) catch {};
        remaining -= chunk;
    }
    if (shutdown.load(.acquire)) return error.Aborted;
}

/// The object at `v`, unwrapping a Speedrun.com `{ "data": {...} }` embed.
pub fn embeddedObject(v: ?Value) ?Object {
    const val = v orelse return null;
    if (val != .object) return null;
    if (val.object.get("data")) |data| {
        if (data == .object) return data.object;
    }
    return val.object;
}

pub fn get(obj: ?Object, key: []const u8) ?Value {
    const o = obj orelse return null;
    return o.get(key);
}

pub fn asString(v: ?Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

pub fn asNumber(v: ?Value) ?f64 {
    const val = v orelse return null;
    return switch (val) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// The `id` of a Speedrun.com resource, whether inline string or embedded.
pub fn resourceId(alloc: std.mem.Allocator, v: ?Value) !?[]const u8 {
    const val = v orelse return null;
    if (val == .string) return cleanOptionalLine(alloc, val.string, 128);
    if (embeddedObject(val)) |obj| {
        if (asString(obj.get("id"))) |id| return cleanOptionalLine(alloc, id, 128);
    }
    return null;
}

pub fn objString(alloc: std.mem.Allocator, obj: ?Object, key: []const u8) !?[]const u8 {
    return cleanOptionalLine(alloc, asString(get(obj, key)), 256);
}

pub fn nestedString(
    alloc: std.mem.Allocator,
    obj: ?Object,
    outer: []const u8,
    inner: []const u8,
) !?[]const u8 {
    const o = obj orelse return null;
    const inner_val = o.get(outer) orelse return null;
    if (inner_val != .object) return null;
    return cleanOptionalLine(alloc, asString(inner_val.object.get(inner)), 256);
}

/// Only http/https URLs pass; everything else becomes null (mirrors httpUrl).
pub fn httpUrl(alloc: std.mem.Allocator, v: ?Value) !?[]const u8 {
    const s = asString(v) orelse return null;
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    const uri = std.Uri.parse(trimmed) catch return null;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        return try alloc.dupe(u8, trimmed);
    }
    return null;
}

/// Truncate to at most `max` bytes without splitting a UTF-8 codepoint.
fn utf8Truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

/// Collapse control characters to spaces, trim, truncate. Returns owned memory.
pub fn cleanLine(alloc: std.mem.Allocator, value: []const u8, max: usize) ![]u8 {
    const buf = try alloc.alloc(u8, value.len);
    for (value, 0..) |c, i| buf[i] = if (c < ' ') ' ' else c;
    const trimmed = std.mem.trim(u8, buf, " \t\r\n");
    return alloc.dupe(u8, utf8Truncate(trimmed, max));
}

pub fn cleanOptionalLine(alloc: std.mem.Allocator, value: ?[]const u8, max: usize) !?[]u8 {
    const v = value orelse return null;
    const clean = try cleanLine(alloc, v, max);
    return if (clean.len == 0) null else clean;
}

/// Keep newlines and printable characters, drop other control chars, trim,
/// truncate. Used for multi-line text like rejection reasons.
pub fn cleanText(alloc: std.mem.Allocator, value: []const u8, max: usize) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(alloc);
    for (value) |c| {
        if (c == '\n' or c >= ' ') try list.append(alloc, c);
    }
    const trimmed = std.mem.trim(u8, list.items, " \t\r\n");
    return alloc.dupe(u8, utf8Truncate(trimmed, max));
}

pub fn cleanOptionalText(alloc: std.mem.Allocator, value: ?[]const u8, max: usize) !?[]u8 {
    const v = value orelse return null;
    const clean = try cleanText(alloc, v, max);
    return if (clean.len == 0) null else clean;
}

/// "1:22.111", "17.879", "1:02:03" — mirrors formatDuration.
pub fn formatDuration(alloc: std.mem.Allocator, seconds: f64) ![]u8 {
    const total_ms: i64 = @intFromFloat(@round(seconds * 1000.0));
    const ms = @mod(total_ms, 1000);
    const total_s = @divFloor(total_ms, 1000);
    const hours = @divFloor(total_s, 3600);
    const minutes = @divFloor(@mod(total_s, 3600), 60);
    const secs = @mod(total_s, 60);

    var base: []u8 = undefined;
    if (hours > 0) {
        base = try std.fmt.allocPrint(alloc, "{d}:{s}:{s}", .{ hours, try padInt(alloc, minutes, 2), try padInt(alloc, secs, 2) });
    } else if (minutes > 0) {
        base = try std.fmt.allocPrint(alloc, "{d}:{s}", .{ minutes, try padInt(alloc, secs, 2) });
    } else {
        base = try std.fmt.allocPrint(alloc, "{d}", .{secs});
    }
    if (ms == 0) return base;
    return std.fmt.allocPrint(alloc, "{s}.{s}", .{ base, try padInt(alloc, ms, 3) });
}

/// "1m 22s 111ms" — mirrors compactDuration.
pub fn compactDuration(alloc: std.mem.Allocator, seconds: f64) ![]u8 {
    const total_ms: i64 = @intFromFloat(@round(seconds * 1000.0));
    const m = @divFloor(total_ms, 60_000);
    const s = @mod(@divFloor(total_ms, 1000), 60);
    const ms = @mod(total_ms, 1000);
    return try std.fmt.allocPrint(alloc, "{d}m {d}s {s}ms", .{ m, s, try padInt(alloc, ms, 3) });
}

/// Zero-pad a non-negative integer to `width` digits. The `{d:0>3}` / `{d:0>2}`
/// format specs are not reliable here (they render a sign prefix, e.g. "+345"), so
/// the padding is done explicitly to keep the output clean.
fn padInt(alloc: std.mem.Allocator, value: i64, width: usize) ![]u8 {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return error.OutOfMemory;
    if (s.len >= width) return try alloc.dupe(u8, s);
    const padded = try alloc.alloc(u8, width);
    @memset(padded, '0');
    const start = width - s.len;
    @memcpy(padded[start..], s);
    return padded;
}

test "compactDuration has no sign prefix and pads milliseconds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const short_ = try compactDuration(a, 12.345);
    defer arena.allocator().free(short_);
    try std.testing.expectEqualStrings("0m 12s 345ms", short_);

    const tiny = try compactDuration(a, 45.6);
    defer arena.allocator().free(tiny);
    try std.testing.expectEqualStrings("0m 45s 600ms", tiny);

    const hours = try compactDuration(a, 3661.5);
    defer arena.allocator().free(hours);
    try std.testing.expectEqualStrings("61m 1s 500ms", hours);
}

test "formatDuration pads hours and milliseconds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const long = try formatDuration(a, 3661.25);
    defer arena.allocator().free(long);
    try std.testing.expectEqualStrings("1:01:01.250", long);

    const minutes = try formatDuration(a, 82.5);
    defer arena.allocator().free(minutes);
    try std.testing.expectEqualStrings("1:22.500", minutes);

    const seconds = try formatDuration(a, 12.345);
    defer arena.allocator().free(seconds);
    try std.testing.expectEqualStrings("12.345", seconds);
}
