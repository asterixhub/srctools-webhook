const std = @import("std");
const http = @import("http.zig");

/// The same endpoint the game's `OnlineInfoApiManager` polls. `totaluser` is the
/// number shown under "GAMERS ONLINE" in the Bhop Pro main menu.
pub const API_URL = "https://infocdn.bhoppro.com/infototal";
const MAX_PLAYERS: i64 = 10_000_000;

pub const Summary = struct {
    total: i64,
};

/// Fetch and validate the live Bhop Pro online counter.
pub fn fetch(client: *http.Http, arena: std.mem.Allocator) !Summary {
    var body: http.Allocating = .init(arena);
    const status = try client.getJson(API_URL, null, &body);
    if (status < 200 or status >= 300) return error.HttpError;
    return parse(arena, body.written());
}

/// Parse `/infototal`. Only `totaluser` is required; the rest of the payload is
/// ignored so a new field cannot break the report.
pub fn parse(arena: std.mem.Allocator, body: []const u8) !Summary {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
        return error.UnexpectedPayload;
    if (parsed != .object) return error.UnexpectedPayload;

    const value = parsed.object.get("totaluser") orelse return error.UnexpectedPayload;
    const total: i64 = switch (value) {
        .integer => |n| n,
        else => return error.InvalidTotal,
    };
    if (total < 0 or total > MAX_PLAYERS) return error.InvalidTotal;
    return .{ .total = total };
}

test "parses the live online payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const summary = try parse(
        arena.allocator(),
        "{\"dt\":\"2026-11-06T02:31:08.568Z\",\"roomlimit\":12,\"totaluser\":135," ++
            "\"mapstotal\":[{\"map\":\"Speedrun-Mood\",\"online\":16}]}",
    );
    try std.testing.expectEqual(@as(i64, 135), summary.total);
}

test "accepts zero players" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const summary = try parse(arena.allocator(), "{\"totaluser\":0}");
    try std.testing.expectEqual(@as(i64, 0), summary.total);
}

test "rejects a payload without a usable totaluser" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectError(error.UnexpectedPayload, parse(a, "{\"roomlimit\":12}"));
    try std.testing.expectError(error.UnexpectedPayload, parse(a, "[]"));
    try std.testing.expectError(error.InvalidTotal, parse(a, "{\"totaluser\":\"many\"}"));
    try std.testing.expectError(error.InvalidTotal, parse(a, "{\"totaluser\":-1}"));
}
