const std = @import("std");
const util = @import("util.zig");
const cfg = @import("config.zig");
const speedrun = @import("speedrun.zig");
const discord = @import("discord.zig");
const online = @import("online.zig");
const upd = @import("update.zig");
const state = @import("state.zig");

const FeedKind = cfg.FeedKind;

const SCOPE_REFRESH_MS = 6 * 60 * 60_000;
const FEEDS = [_]FeedKind{ .new_run, .approved, .rejected };

const Scope = struct {
    account_id: []const u8,
    game_ids: []const []const u8,
    fingerprint: []const u8,
    refreshed_at: i64,
};

pub const Worker = struct {
    gpa: std.mem.Allocator,
    config: *const cfg.Config,
    speedrun: *speedrun.Client,
    discord: *discord.Discord,
    state: *state.StateStore,
    shutdown: *std.atomic.Value(bool),
    scope_arena: std.heap.ArenaAllocator,
    scope: ?Scope = null,
    consecutive_failures: u32 = 0,
    online_next_at: i64 = 0,
    info_arena: std.heap.ArenaAllocator,
    last_update_key: []const u8 = "",

    pub fn init(
        gpa: std.mem.Allocator,
        config: *const cfg.Config,
        src: *speedrun.Client,
        dsc: *discord.Discord,
        store: *state.StateStore,
        shutdown: *std.atomic.Value(bool),
    ) Worker {
        return .{
            .gpa = gpa,
            .config = config,
            .speedrun = src,
            .discord = dsc,
            .state = store,
            .shutdown = shutdown,
            .scope_arena = std.heap.ArenaAllocator.init(gpa),
            .info_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Worker) void {
        self.scope_arena.deinit();
        self.info_arena.deinit();
    }

    pub fn run(self: *Worker) void {
        std.log.info(
            "[Worker] Started; polling every {d}s; online every {d}s",
            .{ self.config.check_interval_ms / 1000, self.config.online_interval_ms / 1_000 },
        );
        while (!self.shutdown.load(.acquire)) {
            const started = util.nowMs();
            self.reportOnlineIfDue();
            // self.reportUpdateIfDue(); // отключено пользователем: не пишем об апдейтах в канал
            if (self.shutdown.load(.acquire)) break;
            if (self.check()) |_| {
                self.consecutive_failures = 0;
            } else |err| {
                if (err == error.Aborted or self.shutdown.load(.acquire)) break;
                self.consecutive_failures += 1;
                std.log.err("[Worker] Check failed ({d} in a row): {s}", .{ self.consecutive_failures, @errorName(err) });
            }

            const interval: i64 = @intCast(self.config.check_interval_ms);
            const delay = failureDelay(interval, self.consecutive_failures);
            const wait = @max(@as(i64, 250), delay - (util.nowMs() - started));
            std.log.info("[Worker] Next check in {d}s", .{@divTrunc(wait + 999, 1000)});
            util.sleepMs(wait, self.shutdown) catch break;
        }
        std.log.info("[Worker] Stopped", .{});
    }

    /// Fetch the live in-game counter and post it once at startup, then every
    /// ONLINE_COUNT_INTERVAL_MINUTES. A failure is retried in 15 minutes.
    fn reportOnlineIfDue(self: *Worker) void {
        if (!self.config.online_enabled) return;
        if (util.nowMs() < self.online_next_at) return;

        var arena_inst = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_inst.deinit();
        const a = arena_inst.allocator();

        const summary = online.fetch(self.discord.http, a) catch |err| {
            if (self.shutdown.load(.acquire)) return;
            self.scheduleOnlineRetry();
            std.log.err("[Online] Could not fetch the online count: {s}", .{@errorName(err)});
            return;
        };

        self.discord.sendOnline(a, summary.total) catch |err| {
            if (self.shutdown.load(.acquire)) return;
            if (err == error.PermanentFailure) {
                std.log.err("[Online] Discord rejected the online report permanently.", .{});
                self.online_next_at = util.nowMs() + @as(i64, @intCast(self.config.online_interval_ms));
            } else {
                self.scheduleOnlineRetry();
                std.log.err("[Online] Could not post the online count: {s}", .{@errorName(err)});
            }
            return;
        };

        self.online_next_at = util.nowMs() + @as(i64, @intCast(self.config.online_interval_ms));
        std.log.info("[Online] Reported {d} player(s) in-game", .{summary.total});
    }

    fn scheduleOnlineRetry(self: *Worker) void {
        const interval: i64 = @intCast(self.config.online_interval_ms);
        const retry = @min(@as(i64, 15 * 60_000), interval);
        self.online_next_at = util.nowMs() + @max(@as(i64, 60_000), retry);
    }

    /// Fetch the Bhop Pro update info and post it to Discord when the snapshot
    /// changes (version or changelog). Always posts the current info once at
    /// startup, because the baseline key starts empty.
    fn reportUpdateIfDue(self: *Worker) void {
        if (self.shutdown.load(.acquire)) return;
        const a = self.info_arena.allocator();

        const update_info = upd.fetch(self.discord.http, a) catch |err| {
            if (self.shutdown.load(.acquire)) return;
            std.log.err("[Update] Could not fetch the update info: {s}", .{@errorName(err)});
            return;
        };

        const key = upd.signature(a, update_info);
        if (self.last_update_key.len > 0 and std.mem.eql(u8, self.last_update_key, key)) return;
        self.last_update_key = key;

        self.discord.sendUpdate(a, update_info) catch |err| {
            if (self.shutdown.load(.acquire)) return;
            std.log.err("[Update] Could not post the update info: {s}", .{@errorName(err)});
            return;
        };
        std.log.info("[Update] Reported version {s}", .{update_info.android_version orelse "unknown"});
    }

    fn check(self: *Worker) !void {
        var arena_inst = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_inst.deinit();
        const a = arena_inst.allocator();

        std.log.info("[Worker] Checking Speedrun.com...", .{});
        try self.drainOutbox(a);
        const scope = try self.currentScope(a);
        if (scope.game_ids.len == 0) {
            std.log.warn("[Worker] The account moderates no selected games; no run feeds were polled.", .{});
            return;
        }

        var found: usize = 0;
        var had_error = false;
        for (FEEDS) |kind| {
            if (!self.config.events.has(kind)) continue;
            const page = self.speedrun.runs(a, kind.status(), scope.game_ids) catch |err| {
                if (err == error.Aborted or self.shutdown.load(.acquire)) return error.Aborted;
                had_error = true;
                std.log.err("[Worker] Feed failed ({s}): {s}", .{ kind.status(), @errorName(err) });
                continue;
            };
            const feed_key = try std.fmt.allocPrint(a, "{s}:{s}:{s}", .{ scope.account_id, scope.fingerprint, kind.label() });
            found += try self.state.applyFeedPage(scope.account_id, feed_key, kind, page);
        }

        std.log.info("[Worker] Found {d} new event(s)", .{found});
        try self.drainOutbox(a);
        try self.state.prune();
        if (had_error) return error.FeedFailed;
    }

    fn currentScope(self: *Worker, a: std.mem.Allocator) !Scope {
        if (self.scope) |sc| {
            if (util.nowMs() - sc.refreshed_at < SCOPE_REFRESH_MS) return sc;
        }

        const account_id = try self.speedrun.profile(a);
        const games = try self.speedrun.moderatedGames(a, account_id);

        // Intersect configured games with the ones this account moderates.
        var matched: std.ArrayList([]const u8) = .empty;
        for (self.config.game_ids) |want| {
            for (games) |g| {
                if (std.mem.eql(u8, g.id, want)) {
                    try matched.append(a, want);
                    break;
                }
            }
        }
        std.sort.insertion([]const u8, matched.items, {}, lessThanStr);

        // Stable fingerprint of the sorted scope (matches worker.ts sha256/16).
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for (matched.items, 0..) |id, i| {
            if (i > 0) hasher.update("\n");
            hasher.update(id);
        }
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        const hex = std.fmt.bytesToHex(digest, .lower);

        _ = self.scope_arena.reset(.free_all);
        const sa = self.scope_arena.allocator();
        const ids = try sa.alloc([]const u8, matched.items.len);
        for (matched.items, 0..) |id, i| ids[i] = try sa.dupe(u8, id);
        const scope = Scope{
            .account_id = try sa.dupe(u8, account_id),
            .game_ids = ids,
            .fingerprint = try sa.dupe(u8, hex[0..16]),
            .refreshed_at = util.nowMs(),
        };
        self.scope = scope;

        if (matched.items.len == 0) {
            std.log.info("[Worker] Scope refreshed: 0 game(s): none", .{});
        } else {
            std.log.info("[Worker] Scope refreshed: {d} game(s)", .{matched.items.len});
        }
        if (self.config.game_ids.len != matched.items.len) {
            std.log.warn("[Worker] Some selected game(s) are not moderated by this account and were ignored.", .{});
        }
        return scope;
    }

    fn drainOutbox(self: *Worker, a: std.mem.Allocator) !void {
        const pending = try self.state.pendingOutbox(a, 20);
        for (pending) |event| {
            self.discord.send(a, event.kind, event.run) catch |err| {
                if (err == error.Aborted or self.shutdown.load(.acquire)) return error.Aborted;
                const permanent = err == error.PermanentFailure;
                const attempts = event.attempts + 1;
                const exhausted = try self.state.markDeliveryFailed(event.id, attempts, permanent);
                std.log.err(
                    "[Discord] Webhook {s}: {s} {s}",
                    .{ if (exhausted) "failed permanently" else "scheduled for retry", event.kind.label(), event.run_id },
                );
                // One outage causes one bounded attempt per cycle, not a burst.
                break;
            };
            try self.state.markDelivered(event.id);
            std.log.info("[Discord] Webhook sent: {s} {s}", .{ event.kind.label(), event.run_id });
        }
    }
};

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn failureDelay(interval: i64, failures: u32) i64 {
    if (failures < 3) return interval;
    const exp: i64 = @min(@as(i64, 3), @as(i64, failures) - 2);
    return @min(@as(i64, 5 * 60_000), interval * (@as(i64, 1) << @intCast(exp)));
}
