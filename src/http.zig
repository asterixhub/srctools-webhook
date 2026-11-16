const std = @import("std");

pub const Allocating = std.Io.Writer.Allocating;

/// Only the roots that the monitored hosts actually chain to. The full Debian
/// bundle is ~140 KB; this one is a few KB and covers speedrun.com and
/// Discord. A host served by anything else falls back to the system bundle.
const MINI_CA_PATH = "/etc/ssl/certs/ca-mini.pem";

pub const Http = struct {
    io: std.Io,
    client: std.http.Client,
    mini_ca: bool = false,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) Http {
        var self: Http = .{
            .io = io,
            .client = .{ .allocator = alloc, .io = io, .read_buffer_size = 4096 },
        };
        self.loadMiniCa();
        return self;
    }

    fn loadMiniCa(self: *Http) void {
        const now = std.Io.Clock.real.now(self.io);
        var bundle: std.crypto.Certificate.Bundle = .empty;
        bundle.addCertsFromFilePathAbsolute(self.client.allocator, self.io, now, MINI_CA_PATH) catch {
            bundle.deinit(self.client.allocator);
            return;
        };
        const roots = bundle.map.count();
        if (roots == 0) {
            bundle.deinit(self.client.allocator);
            return;
        }
        self.client.ca_bundle = bundle;
        self.client.now = now;
        self.mini_ca = true;
        std.log.info("[TLS] Loaded {d} bundled root certificate(s)", .{roots});
    }

    /// Undo the mini bundle and let std.http.Client rescan the full system
    /// store on the next handshake.
    fn dropMiniCa(self: *Http) void {
        self.client.ca_bundle.deinit(self.client.allocator);
        self.client.ca_bundle = .empty;
        self.client.now = null;
        self.mini_ca = false;
    }

    fn fetch(self: *Http, options: std.http.Client.FetchOptions) !std.http.Client.FetchResult {
        // std passes this timestamp to TLS as "now" for certificate validity.
        // A non-null value also tells the client the bundle is already loaded.
        if (self.client.now != null) self.client.now = std.Io.Clock.real.now(self.io);
        return self.client.fetch(options) catch |err| switch (err) {
            error.TlsInitializationFailed => {
                if (!self.mini_ca) return err;
                std.log.warn("[TLS] Bundled roots did not verify the peer; using the system bundle", .{});
                self.dropMiniCa();
                return self.client.fetch(options);
            },
            else => |e| return e,
        };
    }

    pub fn deinit(self: *Http) void {
        self.client.deinit();
    }

    pub fn getJson(
        self: *Http,
        url: []const u8,
        api_key: ?[]const u8,
        out: *Allocating,
    ) !u16 {
        const decompress_buffer = try std.heap.page_allocator.alloc(u8, std.compress.flate.max_window_len);
        defer std.heap.page_allocator.free(decompress_buffer);
        const redirect_buffer = try std.heap.page_allocator.alloc(u8, 8 * 1024);
        defer std.heap.page_allocator.free(redirect_buffer);

        var extra: [2]std.http.Header = undefined;
        var n: usize = 0;
        extra[n] = .{ .name = "Accept", .value = "application/json" };
        n += 1;
        if (api_key) |key| {
            extra[n] = .{ .name = "X-API-Key", .value = key };
            n += 1;
        }
        const res = try self.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &out.writer,
            .headers = .{ .user_agent = .{ .override = "s" } },
            .extra_headers = extra[0..n],
            .redirect_behavior = .not_allowed,
            .redirect_buffer = redirect_buffer,
            .decompress_buffer = decompress_buffer,
            .keep_alive = false,
        });
        return @intFromEnum(res.status);
    }

    pub fn postJson(
        self: *Http,
        url: []const u8,
        body: []const u8,
        out: *Allocating,
    ) !u16 {
        const decompress_buffer = try std.heap.page_allocator.alloc(u8, std.compress.flate.max_window_len);
        defer std.heap.page_allocator.free(decompress_buffer);
        const redirect_buffer = try std.heap.page_allocator.alloc(u8, 8 * 1024);
        defer std.heap.page_allocator.free(redirect_buffer);

        const res = try self.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .response_writer = &out.writer,
            .headers = .{
                .user_agent = .{ .override = "s" },
                .content_type = .{ .override = "application/json" },
            },
            .redirect_behavior = .not_allowed,
            .redirect_buffer = redirect_buffer,
            .decompress_buffer = decompress_buffer,
            .keep_alive = false,
        });
        return @intFromEnum(res.status);
    }
};
