const std = @import("std");
const types = @import("types");
const DailyLimiter = @import("daily_limiter").DailyLimiter;

// Test suite for filesystem-related operations (DailyLimiter, history, seen hashes)
// Run with: zig build test-filesystem

// ============================================================================
// TEST DAILY LIMITER (using tmpDir for sandboxed testing)
// ============================================================================

const TestLimiter = struct {
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    seen_ids_file: []const u8,

    pub fn init(allocator: std.mem.Allocator, base_dir: std.fs.Dir) !TestLimiter {
        try base_dir.makePath("history");
        const state_dir = try base_dir.realpathAlloc(allocator, "history");
        const base_path = try base_dir.realpathAlloc(allocator, ".");
        defer allocator.free(base_path);
        const seen_ids_file = try std.fs.path.join(allocator, &.{ base_path, "seen_ids.bin" });
        return TestLimiter{ .allocator = allocator, .state_dir = state_dir, .seen_ids_file = seen_ids_file };
    }

    pub fn deinit(self: TestLimiter) void {
        self.allocator.free(self.state_dir);
        self.allocator.free(self.seen_ids_file);
    }

    pub fn saveToFile(self: TestLimiter, filename: []const u8, items: []const types.RssItem) !void {
        const filepath = try std.fs.path.join(self.allocator, &.{ self.state_dir, filename });
        defer self.allocator.free(filepath);
        const json = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(types.LastRunState{
            .timestamp = std.time.timestamp(), .items = items,
        }, .{ .whitespace = .indent_2 })});
        defer self.allocator.free(json);
        const file = try std.fs.cwd().createFile(filepath, .{});
        defer file.close();
        try file.writeAll(json);
    }

    pub fn fileExists(self: TestLimiter, filename: []const u8) bool {
        const filepath = std.fs.path.join(self.allocator, &.{ self.state_dir, filename }) catch return false;
        defer self.allocator.free(filepath);
        std.fs.cwd().access(filepath, .{}) catch return false;
        return true;
    }

    pub fn loadSeenHashes(self: TestLimiter) !std.AutoHashMap(u64, void) {
        var hashes = std.AutoHashMap(u64, void).init(self.allocator);
        const file = std.fs.cwd().openFile(self.seen_ids_file, .{}) catch |e| switch (e) {
            error.FileNotFound => return hashes,
            else => return e,
        };
        defer file.close();
        const size = try file.getEndPos();
        if (size == 0 or size % 12 != 0) return hashes;
        const count = size / 12;
        try hashes.ensureTotalCapacity(@intCast(count));
        var i: usize = 0;
        while (i < count) : (i += 1) {
            var buf: [12]u8 = undefined;
            if (try file.readAll(&buf) < 12) break;
            hashes.putAssumeCapacity(std.mem.readInt(u64, buf[4..12], .little), {});
        }
        return hashes;
    }

    pub fn saveNewHashes(self: TestLimiter, new_hashes: []const u64) !void {
        if (new_hashes.len == 0) return;
        const file = std.fs.cwd().openFile(self.seen_ids_file, .{ .mode = .read_write }) catch |e| switch (e) {
            error.FileNotFound => try std.fs.cwd().createFile(self.seen_ids_file, .{}),
            else => return e,
        };
        defer file.close();
        try file.seekFromEnd(0);
        const ts: u32 = @truncate(@as(u64, @intCast(@max(0, std.time.timestamp()))));
        for (new_hashes) |h| {
            var buf: [12]u8 = undefined;
            std.mem.writeInt(u32, buf[0..4], ts, .little);
            std.mem.writeInt(u64, buf[4..12], h, .little);
            try file.writeAll(&buf);
        }
    }
};

test "creates history directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lim = try TestLimiter.init(std.testing.allocator, tmp.dir);
    defer lim.deinit();
    var d = try tmp.dir.openDir("history", .{});
    defer d.close();
}

test "saveDay creates file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lim = try TestLimiter.init(std.testing.allocator, tmp.dir);
    defer lim.deinit();
    try lim.saveToFile("test_2024-12-05.json", &.{});
    try std.testing.expect(lim.fileExists("test_2024-12-05.json"));
}

test "hash roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lim = try TestLimiter.init(std.testing.allocator, tmp.dir);
    defer lim.deinit();
    const h = [_]u64{ 0xDEADBEEF, 0xCAFEBABE };
    try lim.saveNewHashes(&h);
    var loaded = try lim.loadSeenHashes();
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u32, 2), loaded.count());
    try std.testing.expect(loaded.contains(0xDEADBEEF));
}

test "empty hashes file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lim = try TestLimiter.init(std.testing.allocator, tmp.dir);
    defer lim.deinit();
    var h = try lim.loadSeenHashes();
    defer h.deinit();
    try std.testing.expectEqual(@as(u32, 0), h.count());
}

test "append hashes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lim = try TestLimiter.init(std.testing.allocator, tmp.dir);
    defer lim.deinit();
    try lim.saveNewHashes(&[_]u64{1});
    try lim.saveNewHashes(&[_]u64{2});
    var h = try lim.loadSeenHashes();
    defer h.deinit();
    try std.testing.expectEqual(@as(u32, 2), h.count());
}

test "pruneSeen rewrites file without crashing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lim = try TestLimiter.init(std.testing.allocator, tmp.dir);
    defer lim.deinit();

    var limiter = DailyLimiter{
        .allocator = std.testing.allocator,
        .state_dir = try std.testing.allocator.dupe(u8, lim.state_dir),
        .seen_ids_file = try std.testing.allocator.dupe(u8, lim.seen_ids_file),
        .group_name = "test",
        .day_start_hour = 0,
        .fetch_interval_days = 1,
    };
    defer limiter.deinit();

    // Seed the file with an old entry and a newer entry. Pruning should remove the old one
    // and rewrite the file (this used to trigger a double-close panic).
    {
        const file = try std.fs.cwd().createFile(lim.seen_ids_file, .{});
        defer file.close();

        const now_i64 = std.time.timestamp();
        const now_u64: u64 = if (now_i64 < 0) 0 else @intCast(now_i64);

        const old_u64 = if (now_u64 > 2 * 24 * 60 * 60) now_u64 - (2 * 24 * 60 * 60) else 0;
        const old_ts: u32 = @truncate(old_u64);
        const new_u64 = @min(now_u64 + 60 * 60, std.math.maxInt(u32));
        const new_ts: u32 = @truncate(new_u64);

        var buf: [12]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], old_ts, .little);
        std.mem.writeInt(u64, buf[4..12], 0x1111, .little);
        try file.writeAll(&buf);

        std.mem.writeInt(u32, buf[0..4], new_ts, .little);
        std.mem.writeInt(u64, buf[4..12], 0x2222, .little);
        try file.writeAll(&buf);
    }

    try limiter.pruneSeen(1);

    const file = try std.fs.cwd().openFile(lim.seen_ids_file, .{});
    defer file.close();
    try std.testing.expectEqual(@as(u64, 12), try file.getEndPos());
    try file.seekTo(0);
    var buf: [12]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 12), try file.readAll(&buf));
    try std.testing.expectEqual(@as(u64, 0x2222), std.mem.readInt(u64, buf[4..12], .little));
}

test "loadSeenHashes resets corrupted file without crashing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lim = try TestLimiter.init(std.testing.allocator, tmp.dir);
    defer lim.deinit();

    var limiter = DailyLimiter{
        .allocator = std.testing.allocator,
        .state_dir = try std.testing.allocator.dupe(u8, lim.state_dir),
        .seen_ids_file = try std.testing.allocator.dupe(u8, lim.seen_ids_file),
        .group_name = "test",
        .day_start_hour = 0,
        .fetch_interval_days = 1,
    };
    defer limiter.deinit();

    {
        const file = try std.fs.cwd().createFile(lim.seen_ids_file, .{});
        defer file.close();
        try file.writeAll("x"); // not a multiple of 12 bytes
    }

    var hashes = try limiter.loadSeenHashes();
    defer hashes.deinit();
    try std.testing.expectEqual(@as(u32, 0), hashes.count());

    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(lim.seen_ids_file, .{}));
}

test "pruneSeen deletes corrupted file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lim = try TestLimiter.init(std.testing.allocator, tmp.dir);
    defer lim.deinit();

    var limiter = DailyLimiter{
        .allocator = std.testing.allocator,
        .state_dir = try std.testing.allocator.dupe(u8, lim.state_dir),
        .seen_ids_file = try std.testing.allocator.dupe(u8, lim.seen_ids_file),
        .group_name = "test",
        .day_start_hour = 0,
        .fetch_interval_days = 1,
    };
    defer limiter.deinit();

    {
        const file = try std.fs.cwd().createFile(lim.seen_ids_file, .{});
        defer file.close();
        try file.writeAll("corruptdata!x");
    }

    try limiter.pruneSeen(1);

    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(lim.seen_ids_file, .{}));
}

test "pruneSeen no-op when all entries retained" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lim = try TestLimiter.init(std.testing.allocator, tmp.dir);
    defer lim.deinit();

    var limiter = DailyLimiter{
        .allocator = std.testing.allocator,
        .state_dir = try std.testing.allocator.dupe(u8, lim.state_dir),
        .seen_ids_file = try std.testing.allocator.dupe(u8, lim.seen_ids_file),
        .group_name = "test",
        .day_start_hour = 0,
        .fetch_interval_days = 1,
    };
    defer limiter.deinit();

    {
        const file = try std.fs.cwd().createFile(lim.seen_ids_file, .{});
        defer file.close();

        const now_i64 = std.time.timestamp();
        const now_u64: u64 = if (now_i64 < 0) 0 else @intCast(now_i64);
        const ts: u32 = @intCast(@min(now_u64, std.math.maxInt(u32)));

        var buf: [12]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], ts, .little);
        std.mem.writeInt(u64, buf[4..12], 0xAAAA, .little);
        try file.writeAll(&buf);
    }

    try limiter.pruneSeen(30);

    const file = try std.fs.cwd().openFile(lim.seen_ids_file, .{});
    defer file.close();
    try std.testing.expectEqual(@as(u64, 12), try file.getEndPos());
    try file.seekTo(0);
    var buf: [12]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 12), try file.readAll(&buf));
    try std.testing.expectEqual(@as(u64, 0xAAAA), std.mem.readInt(u64, buf[4..12], .little));
}

test "pruneSeen produces empty file when all entries expired" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lim = try TestLimiter.init(std.testing.allocator, tmp.dir);
    defer lim.deinit();

    var limiter = DailyLimiter{
        .allocator = std.testing.allocator,
        .state_dir = try std.testing.allocator.dupe(u8, lim.state_dir),
        .seen_ids_file = try std.testing.allocator.dupe(u8, lim.seen_ids_file),
        .group_name = "test",
        .day_start_hour = 0,
        .fetch_interval_days = 1,
    };
    defer limiter.deinit();

    {
        const file = try std.fs.cwd().createFile(lim.seen_ids_file, .{});
        defer file.close();

        var buf: [12]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], 1, .little);
        std.mem.writeInt(u64, buf[4..12], 0xBBBB, .little);
        try file.writeAll(&buf);
    }

    try limiter.pruneSeen(1);

    const file = try std.fs.cwd().openFile(lim.seen_ids_file, .{});
    defer file.close();
    try std.testing.expectEqual(@as(u64, 0), try file.getEndPos());
}
