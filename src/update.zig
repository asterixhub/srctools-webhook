const std = @import("std");
const http = @import("http.zig");

const UPDATE_URL = "https://uc.bhoppro.com/bhop-update.json";

pub const UpdateInfo = struct {
    android_version: ?[]const u8 = null,
    android_message: ?[]const u8 = null,
    ios_version: ?[]const u8 = null,
    ios_message: ?[]const u8 = null,
};

pub const UpdateError = error{
    HttpError,
    UnexpectedPayload,
    OutOfMemory,
};

/// Fetch the Bhop Pro update info published on the game servers.
/// `android_version` / `android_message` describe the Android release, the iOS
/// pair the iOS release, so both halves are kept in the summary.
pub fn fetch(client: *http.Http, arena: std.mem.Allocator) !UpdateInfo {
    var body: http.Allocating = .init(arena);
    const status = try client.getJson(UPDATE_URL, null, &body);
    if (status < 200 or status >= 300) return error.HttpError;
    return parse(arena, body.written());
}

/// Parse `/bhop-update.json`.
pub fn parse(arena: std.mem.Allocator, body: []const u8) !UpdateInfo {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
        return error.UnexpectedPayload;
    if (parsed != .object) return error.UnexpectedPayload;

    const android_version = jsonString(parsed.object.get("android_version"));
    const android_message = jsonString(parsed.object.get("android_message"));
    const ios_version = jsonString(parsed.object.get("ios_version"));
    const ios_message = jsonString(parsed.object.get("ios_message"));

    return .{
        .android_version = android_version,
        .android_message = android_message,
        .ios_version = ios_version,
        .ios_message = ios_message,
    };
}

/// Stable fingerprint of the whole update snapshot (versions + changelogs).
pub fn signature(arena: std.mem.Allocator, update: UpdateInfo) []const u8 {
    const version = update.android_version orelse update.ios_version orelse "unknown";
    const message = update.android_message orelse update.ios_message orelse version;
    return std.fmt.allocPrint(arena, "{s}\n{s}", .{ version, message }) catch "";
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

test "parses the live update payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const update = try parse(
        arena.allocator(),
        "{\"android_version\":\"1.7.4\",\"android_url\":\"market://details?id=com.begma.bhoppro\"," ++
            "\"android_message\":\"* New Deathrun map - Square\\n* New Deathrun map - Magma\\n* New Speedrun map - River\"," ++
            "\"ios_version\":\"1.3.7\",\"ios_message\":\"* New mode - Highline\\n* Bug fixes\",\"chartboost_ratio\":\"0.000\"}",
    );
    try std.testing.expectEqualStrings("1.7.4", update.android_version.?);
    try std.testing.expect(std.mem.startsWith(u8, update.android_message.?, "* New Deathrun map - Square"));
    try std.testing.expectEqualStrings("1.3.7", update.ios_version.?);
}

test "signature changes with the changelog" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try parse(a, "{\"android_version\":\"1.7.4\",\"android_message\":\"* New Deathrun map - Square\"}");
    const second = try parse(a, "{\"android_version\":\"1.7.4\",\"android_message\":\"* New Deathrun map - Magma\"}");
    const first_key = signature(a, first);
    const second_key = signature(a, second);
    try std.testing.expect(first_key.len > 0);
    try std.testing.expect(!std.mem.eql(u8, first_key, second_key));
}

test "signature is stable for the same snapshot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const update = try parse(a, "{\"android_version\":\"1.7.4\",\"android_message\":\"* New Deathrun map - Square\"}");
    const key = signature(a, update);
    try std.testing.expectEqualStrings(key, signature(a, update));
}
