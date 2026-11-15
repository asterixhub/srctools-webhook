const std = @import("std");
const util = @import("util.zig");
const http = @import("http.zig");
const cfg = @import("config.zig");
const types = @import("types.zig");

const Value = std.json.Value;
const RunSummary = types.RunSummary;

const API_BASE = "https://www.speedrun.com/api/v1";
const RUN_EMBEDS = "category,level,players";
const MAX_ATTEMPTS = 4;
const MIN_REQUEST_GAP_MS = 650;
const VARIABLES_CACHE_MS = 12 * 60 * 60 * 1000;

pub const Game = struct { id: []const u8, name: []const u8 };

pub const Error = error{ SpeedrunRequestFailed, MalformedResponse } || util.Aborted || std.mem.Allocator.Error;

const Subcategory = struct {
    var_id: []u8,
    values: std.StringHashMap([]u8),
};

const CacheEntry = struct { expires_at: i64, subs: []Subcategory };

pub const Client = struct {
    http: *http.Http,
    api_key: []const u8,
    gpa: std.mem.Allocator,
    shutdown: *std.atomic.Value(bool),
    next_request_at: i64 = 0,
    prng: std.Random.DefaultPrng,
    var_cache: std.StringHashMap(CacheEntry),

    pub fn init(
        gpa: std.mem.Allocator,
        client: *http.Http,
        api_key: []const u8,
        shutdown: *std.atomic.Value(bool),
    ) Client {
        return .{
            .http = client,
            .api_key = api_key,
            .gpa = gpa,
            .shutdown = shutdown,
            .prng = std.Random.DefaultPrng.init(@bitCast(util.nowMs())),
            .var_cache = std.StringHashMap(CacheEntry).init(gpa),
        };
    }

    pub fn deinit(self: *Client) void {
        var it = self.var_cache.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            freeSubs(self.gpa, entry.value_ptr.*.subs);
        }
        self.var_cache.deinit();
    }

    fn gate(self: *Client) util.Aborted!void {
        const wait = self.next_request_at - util.nowMs();
        if (wait > 0) try util.sleepMs(wait, self.shutdown);
        self.next_request_at = util.nowMs() + MIN_REQUEST_GAP_MS;
    }

    fn backoffMs(self: *Client, attempt: u32) i64 {
        const base = @min(@as(i64, 8000), @as(i64, 400) * (@as(i64, 1) << @intCast(attempt)));
        return base + @as(i64, @intCast(self.prng.random().uintLessThan(u32, 250)));
    }

    fn request(self: *Client, arena: std.mem.Allocator, url: []const u8) Error![]u8 {
        var attempt: u32 = 1;
        while (attempt <= MAX_ATTEMPTS) : (attempt += 1) {
            if (self.shutdown.load(.acquire)) return error.Aborted;
            try self.gate();

            var body: http.Allocating = .init(arena);
            const status: u16 = self.http.getJson(url, self.api_key, &body) catch |e| {
                if (self.shutdown.load(.acquire)) return error.Aborted;
                if (attempt == MAX_ATTEMPTS) {
                    std.log.err("[Speedrun.com] Request failed: {s}", .{@errorName(e)});
                    return error.SpeedrunRequestFailed;
                }
                const delay = self.backoffMs(attempt);
                std.log.warn("[Speedrun.com] Request failed ({s}); retrying in {d}ms", .{ @errorName(e), delay });
                try util.sleepMs(delay, self.shutdown);
                continue;
            };

            if (status >= 200 and status < 300) return body.written();

            const retryable = status == 420 or status == 429 or status >= 500;
            if (!retryable or attempt == MAX_ATTEMPTS) {
                std.log.err("[Speedrun.com] HTTP {d}", .{status});
                return error.SpeedrunRequestFailed;
            }
            const delay = self.backoffMs(attempt);
            std.log.warn("[Speedrun.com] HTTP {d}; retrying in {d}ms", .{ status, delay });
            try util.sleepMs(delay, self.shutdown);
        }
        return error.SpeedrunRequestFailed;
    }

    fn parse(arena: std.mem.Allocator, body: []const u8) Error!Value {
        return std.json.parseFromSliceLeaky(Value, arena, body, .{}) catch return error.MalformedResponse;
    }

    fn collection(self: *Client, arena: std.mem.Allocator, path: []const u8, limit: usize) Error![]Value {
        var items: std.ArrayList(Value) = .empty;
        const sep: []const u8 = if (std.mem.indexOfScalar(u8, path, '?') != null) "&" else "?";
        var offset: usize = 0;

        while (items.items.len < limit) {
            const page_size = @min(@as(usize, 200), limit - items.items.len);
            const url = try std.fmt.allocPrint(arena, "{s}{s}{s}max={d}&offset={d}", .{ API_BASE, path, sep, page_size, offset });
            const body = try self.request(arena, url);
            const root = try parse(arena, body);
            if (root != .object) return error.MalformedResponse;
            const data = root.object.get("data") orelse return error.MalformedResponse;
            if (data != .array) return error.MalformedResponse;
            for (data.array.items) |item| try items.append(arena, item);

            const has_next = pageHasNext(root.object);
            if (!has_next or data.array.items.len == 0) break;
            offset += data.array.items.len;
            if (offset > 10_000) break;
        }
        const end = @min(items.items.len, limit);
        return items.items[0..end];
    }

    pub fn profile(self: *Client, arena: std.mem.Allocator) Error![]const u8 {
        const body = try self.request(arena, API_BASE ++ "/profile");
        const root = try parse(arena, body);
        if (root != .object) return error.MalformedResponse;
        const data = util.embeddedObject(root.object.get("data")) orelse return error.MalformedResponse;
        const id = util.asString(data.get("id")) orelse return error.MalformedResponse;
        return arena.dupe(u8, id);
    }

    pub fn moderatedGames(self: *Client, arena: std.mem.Allocator, user_id: []const u8) Error![]Game {
        const path = try std.fmt.allocPrint(arena, "/games?moderator={s}", .{user_id});
        const items = try self.collection(arena, path, 500);
        var games: std.ArrayList(Game) = .empty;
        for (items) |item| {
            if (item != .object) continue;
            const id = (try util.resourceId(arena, item)) orelse continue;
            const name = (try util.nestedString(arena, item.object, "names", "international")) orelse cfg.gameName(id);
            try games.append(arena, .{ .id = id, .name = name });
        }
        return games.toOwnedSlice(arena);
    }

    fn variables(self: *Client, arena: std.mem.Allocator, game_id: []const u8) Error![]Subcategory {
        const now = util.nowMs();
        if (self.var_cache.get(game_id)) |entry| {
            if (entry.expires_at > now) return entry.subs;
        }
        const url = try std.fmt.allocPrint(arena, "{s}/games/{s}/variables", .{ API_BASE, game_id });
        const body = try self.request(arena, url);
        const root = try parse(arena, body);
        const subs = try parseSubcategories(self.gpa, root);
        errdefer freeSubs(self.gpa, subs);

        const key_copy = try self.gpa.dupe(u8, game_id);
        const gop = self.var_cache.getOrPut(game_id) catch |e| {
            self.gpa.free(key_copy);
            return e;
        };
        if (gop.found_existing) {
            self.gpa.free(key_copy);
            freeSubs(self.gpa, gop.value_ptr.*.subs);
        } else {
            gop.key_ptr.* = key_copy;
        }
        gop.value_ptr.* = .{ .expires_at = now + VARIABLES_CACHE_MS, .subs = subs };
        return subs;
    }

    fn dataArray(root: Value) []Value {
        if (root != .object) return &.{};
        const data = root.object.get("data") orelse return &.{};
        if (data != .array) return &.{};
        return data.array.items;
    }

    fn parseSubcategories(gpa: std.mem.Allocator, root: Value) ![]Subcategory {
        var list: std.ArrayList(Subcategory) = .empty;
        errdefer {
            for (list.items) |*sub| freeSub(gpa, sub);
            list.deinit(gpa);
        }

        var tmp = std.heap.ArenaAllocator.init(gpa);
        defer tmp.deinit();
        const ta = tmp.allocator();

        for (dataArray(root)) |var_val| {
            if (var_val != .object) continue;
            const variable = var_val.object;
            const is_sub = variable.get("is-subcategory") orelse continue;
            if (is_sub != .bool or !is_sub.bool) continue;
            const var_id = util.asString(variable.get("id")) orelse continue;
            const values1 = variable.get("values") orelse continue;
            if (values1 != .object) continue;
            const values2 = values1.object.get("values") orelse continue;
            if (values2 != .object) continue;

            try list.ensureUnusedCapacity(gpa, 1);
            var map = std.StringHashMap([]u8).init(gpa);
            errdefer freeMap(gpa, &map);

            var it = values2.object.iterator();
            while (it.next()) |entry| {
                const entry_val = entry.value_ptr.*;
                if (entry_val != .object) continue;
                const label_raw = util.asString(entry_val.object.get("label")) orelse continue;
                const label = (try util.cleanOptionalLine(ta, label_raw, 256)) orelse continue;
                const key = try gpa.dupe(u8, entry.key_ptr.*);
                errdefer gpa.free(key);
                try map.put(key, try gpa.dupe(u8, label));
            }
            if (map.count() == 0) {
                map.deinit();
                continue;
            }
            list.appendAssumeCapacity(.{
                .var_id = try gpa.dupe(u8, var_id),
                .values = map,
            });
        }
        return list.toOwnedSlice(gpa);
    }

    fn freeMap(gpa: std.mem.Allocator, map: *std.StringHashMap([]u8)) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        map.deinit();
    }

    fn freeSub(gpa: std.mem.Allocator, sub: *Subcategory) void {
        gpa.free(sub.var_id);
        freeMap(gpa, &sub.values);
    }

    fn freeSubs(gpa: std.mem.Allocator, subs: []Subcategory) void {
        for (subs) |*sub| freeSub(gpa, sub);
        gpa.free(subs);
    }

    fn runsForGame(
        self: *Client,
        arena: std.mem.Allocator,
        status: []const u8,
        order: []const u8,
        game_id: []const u8,
    ) Error![]RunSummary {
        const path = try std.fmt.allocPrint(
            arena,
            "/runs?game={s}&status={s}&orderby={s}&direction=desc&embed={s}&_={d}",
            .{ game_id, status, order, RUN_EMBEDS, util.nowMs() },
        );
        const items = try self.collection(arena, path, 20);

        var scoped: std.ArrayList(Value) = .empty;
        for (items) |item| {
            if (item != .object) continue;
            const gid = (try util.resourceId(arena, item.object.get("game"))) orelse continue;
            if (std.mem.eql(u8, gid, game_id)) try scoped.append(arena, item);
        }

        var variables_for_game: []Subcategory = &.{};
        for (scoped.items) |item| {
            if (runHasValues(item.object)) {
                variables_for_game = try self.variables(arena, game_id);
                break;
            }
        }

        var result: std.ArrayList(RunSummary) = .empty;
        for (scoped.items) |item| {
            try result.append(arena, try normalizeRun(arena, item, variables_for_game));
        }
        return result.toOwnedSlice(arena);
    }

    pub fn runs(
        self: *Client,
        arena: std.mem.Allocator,
        status: []const u8,
        game_ids: []const []const u8,
    ) Error![]RunSummary {
        const order: []const u8 = if (std.mem.eql(u8, status, "verified")) "verify-date" else "submitted";
        var result: std.ArrayList(RunSummary) = .empty;
        for (game_ids) |game_id| {
            const page = try self.runsForGame(arena, status, order, game_id);
            try result.appendSlice(arena, page);
        }
        return result.toOwnedSlice(arena);
    }
};

fn pageHasNext(root: std.json.ObjectMap) bool {
    const pagination = root.get("pagination") orelse return false;
    if (pagination != .object) return false;
    const links = pagination.object.get("links") orelse return false;
    if (links != .array) return false;
    for (links.array.items) |link| {
        if (link != .object) continue;
        if (util.asString(link.object.get("rel"))) |rel| {
            if (std.mem.eql(u8, rel, "next")) return true;
        }
    }
    return false;
}

fn runHasValues(run: std.json.ObjectMap) bool {
    const values = run.get("values") orelse return false;
    return values == .object and values.object.count() > 0;
}

fn normalizeRun(arena: std.mem.Allocator, run_val: Value, variables: []const Subcategory) !RunSummary {
    if (run_val != .object) return error.MalformedResponse;
    const run = run_val.object;

    const game = util.embeddedObject(run.get("game"));
    const category = util.embeddedObject(run.get("category"));
    const level = util.embeddedObject(run.get("level"));
    const game_id = try util.resourceId(arena, run.get("game"));

    const base_category = try util.objString(arena, category, "name");
    const subcats = try subcategoryLabels(arena, run.get("values"), variables);

    const category_name = try joinParts(arena, base_category, subcats, " ");

    var primary_seconds: ?f64 = null;
    if (util.embeddedObject(run.get("times"))) |_| {}
    if (run.get("times")) |times| {
        if (times == .object) {
            if (util.asNumber(times.object.get("primary_t"))) |s| {
                if (std.math.isFinite(s) and s > 0) primary_seconds = s;
            }
        }
    }

    const id_clean = try util.cleanOptionalLine(arena, util.asString(run.get("id")), 128);
    const id = id_clean orelse try arena.dupe(u8, "unknown");

    const game_name = (try util.nestedString(arena, game, "names", "international")) orelse
        (try util.objString(arena, game, "abbreviation")) orelse game_id;

    const runner = try playerNames(arena, run.get("players"));

    const map_name = (try util.objString(arena, level, "name")) orelse blk: {
        if (subcats.len > 0) break :blk try std.mem.join(arena, " ", subcats);
        break :blk base_category;
    };

    var time_display: ?[]const u8 = null;
    if (primary_seconds) |s| time_display = try util.formatDuration(arena, s);

    const status_obj: ?util.Object = if (run.get("status")) |st| (if (st == .object) st.object else null) else null;
    const verify_date = if (status_obj) |so| dupeOptional(arena, util.asString(so.get("verify-date"))) else null;
    const rejection_reason = if (status_obj) |so|
        try util.cleanOptionalText(arena, util.asString(so.get("reason")), 2000)
    else
        null;

    return .{
        .id = id,
        .run_url = try util.httpUrl(arena, run.get("weblink")),
        .game_id = game_id,
        .game_name = game_name,
        .category_name = category_name,
        .map_name = map_name,
        .runner = runner,
        .primary_seconds = primary_seconds,
        .time_display = time_display,
        .submitted = dupeOptional(arena, util.asString(run.get("submitted"))),
        .verify_date = verify_date,
        .rejection_reason = rejection_reason,
    };
}

fn dupeOptional(arena: std.mem.Allocator, v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return arena.dupe(u8, s) catch null;
}

fn subcategoryLabels(arena: std.mem.Allocator, selected_val: ?Value, variables: []const Subcategory) ![]const []const u8 {
    var labels: std.ArrayList([]const u8) = .empty;
    const selected = util.embeddedObject(selected_val) orelse {
        if (selected_val) |sv| {
            if (sv == .object) return labelsFrom(arena, sv.object, variables);
        }
        return labels.toOwnedSlice(arena);
    };
    return labelsFrom(arena, selected, variables);
}

fn labelsFrom(arena: std.mem.Allocator, selected: util.Object, subs: []const Subcategory) ![]const []const u8 {
    var labels: std.ArrayList([]const u8) = .empty;
    for (subs) |sub| {
        const value_id_val = selected.get(sub.var_id) orelse continue;
        const value_id = util.asString(value_id_val) orelse continue;
        const label = sub.values.get(value_id) orelse continue;
        try labels.append(arena, try arena.dupe(u8, label));
    }
    return labels.toOwnedSlice(arena);
}

fn playerNames(arena: std.mem.Allocator, players_val: ?Value) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const items: []Value = blk: {
        const pv = players_val orelse break :blk &.{};
        if (pv == .array) break :blk pv.array.items;
        if (pv == .object) {
            if (pv.object.get("data")) |data| {
                if (data == .array) break :blk data.array.items;
            }
        }
        break :blk &.{};
    };
    for (items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        if (util.asString(obj.get("rel"))) |rel| {
            if (std.mem.eql(u8, rel, "guest")) {
                if (try util.cleanOptionalLine(arena, util.asString(obj.get("name")), 128)) |n| {
                    try names.append(arena, n);
                }
                continue;
            }
        }
        const name = (try util.nestedString(arena, obj, "names", "international")) orelse
            (try util.nestedString(arena, obj, "names", "japanese")) orelse
            (try util.cleanOptionalLine(arena, util.asString(obj.get("name")), 128)) orelse
            (try util.cleanOptionalLine(arena, util.asString(obj.get("id")), 128));
        if (name) |n| try names.append(arena, n);
    }
    if (names.items.len == 0) return arena.dupe(u8, "Unknown runner");
    return std.mem.join(arena, ", ", names.items);
}

fn joinParts(arena: std.mem.Allocator, base: ?[]const u8, subcats: []const []const u8, sep: []const u8) !?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    if (base) |b| try parts.append(arena, b);
    for (subcats) |s| try parts.append(arena, s);
    if (parts.items.len == 0) return null;
    return try std.mem.join(arena, sep, parts.items);
}

test "subcategory cache keeps only subcategory labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const variables_json =
        \\{"data":[
        \\{"id":"var1","is-subcategory":true,"values":{"values":{"v1":{"label":"Glitchless"},"v2":{"label":"No Major Glitches"}}}},
        \\{"id":"var2","is-subcategory":false,"values":{"values":{"x":{"label":"Ignored"}}}}
        \\]}
    ;
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, variables_json, .{});
    const subs = try Client.parseSubcategories(a, root);

    const selected_json =
        \\{"var1":"v2","var2":"x"}
    ;
    const selected_root = try std.json.parseFromSliceLeaky(std.json.Value, a, selected_json, .{});
    const labels = try labelsFrom(a, selected_root.object, subs);
    try std.testing.expectEqual(@as(usize, 1), labels.len);
    try std.testing.expectEqualStrings("No Major Glitches", labels[0]);
}
