const std = @import("std");
const types = @import("types");
const RssReader = @import("rss_reader").RssReader;

const curl = @cImport({
    @cInclude("curl/curl.h");
});

/// Generate a dummy RSS feed with the specified number of items
fn generateDummyFeed(allocator: std.mem.Allocator, item_count: usize) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    try output.appendSlice(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<rss version="2.0">
        \\<channel>
        \\<title>Benchmark Feed</title>
        \\<link>https://example.com</link>
        \\<description>Performance testing feed</description>
        \\
    );

    var i: usize = 0;
    while (i < item_count) : (i += 1) {
        var item_buf: [512]u8 = undefined;
        const item_content = try std.fmt.bufPrint(&item_buf,
            \\<item>
            \\<title>Benchmark Item {d}</title>
            \\<link>https://example.com/article/{d}</link>
            \\<description>This is the description for benchmark item {d}. It contains some text to simulate real feed content with HTML entities &amp; special characters.</description>
            \\<pubDate>Wed, 02 Oct 2024 {d:0>2}:{d:0>2}:00 GMT</pubDate>
            \\<guid>benchmark-item-{d}</guid>
            \\</item>
            \\
        , .{ i, i, i, i % 24, i % 60, i });
        try output.appendSlice(item_content);
    }

    try output.appendSlice(
        \\</channel>
        \\</rss>
    );

    return output.toOwnedSlice();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const check = gpa.deinit();
        if (check == .leak) {
            std.debug.print("\n⚠️  WARNING: Memory leak detected during cleanup!\n", .{});
        }
    }
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var iterations: usize = 100;
    var items_per_feed: usize = 50;
    var num_feeds: usize = 10;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-i") or std.mem.eql(u8, args[i], "--iterations")) {
            if (i + 1 < args.len) {
                iterations = try std.fmt.parseInt(usize, args[i + 1], 10);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "-n") or std.mem.eql(u8, args[i], "--items")) {
            if (i + 1 < args.len) {
                items_per_feed = try std.fmt.parseInt(usize, args[i + 1], 10);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "-f") or std.mem.eql(u8, args[i], "--feeds")) {
            if (i + 1 < args.len) {
                num_feeds = try std.fmt.parseInt(usize, args[i + 1], 10);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            std.debug.print(
                \\Hys RSS Reader - Offline Performance Benchmark
                \\
                \\Usage: bench [OPTIONS]
                \\
                \\Options:
                \\  -i, --iterations <N>   Number of parse iterations (default: 100)
                \\  -n, --items <N>        Items per feed (default: 50)
                \\  -f, --feeds <N>        Number of feeds to simulate (default: 10)
                \\  -h, --help             Show this help message
                \\
                \\Example:
                \\  zig build bench -- -i 500 -n 100 -f 20
                \\
            , .{});
            return;
        }
    }

    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════\n", .{});
    std.debug.print("       HYS RSS READER - OFFLINE PERFORMANCE BENCHMARK\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Iterations:     {d}\n", .{iterations});
    std.debug.print("  Items/Feed:     {d}\n", .{items_per_feed});
    std.debug.print("  Number of Feeds: {d}\n", .{num_feeds});
    std.debug.print("\n", .{});

    // Generate test feeds
    std.debug.print("Generating {d} test feeds with {d} items each...\n", .{ num_feeds, items_per_feed });
    const feeds = try allocator.alloc([]u8, num_feeds);
    defer {
        for (feeds) |feed| {
            allocator.free(feed);
        }
        allocator.free(feeds);
    }

    var total_feed_size: usize = 0;
    for (feeds, 0..) |*feed, idx| {
        feed.* = try generateDummyFeed(allocator, items_per_feed);
        total_feed_size += feed.len;
        _ = idx;
    }

    std.debug.print("  Total feed data: {d} KB ({d} bytes)\n", .{ total_feed_size / 1024, total_feed_size });
    std.debug.print("\n", .{});

    // Warmup phase
    std.debug.print("Warming up (10 iterations)...\n", .{});
    {
        var warmup_i: usize = 0;
        while (warmup_i < 10) : (warmup_i += 1) {
            for (feeds) |feed_data| {
                var reader = RssReader.init(allocator);
                defer reader.deinit();

                var parsed = reader.parseXml(feed_data, null, null) catch continue;
                parsed.deinit();
            }
        }
    }

    // Benchmark: Parse XML
    std.debug.print("Running benchmark...\n", .{});
    std.debug.print("\n", .{});

    var total_items_parsed: usize = 0;
    var parse_times = try allocator.alloc(i64, iterations);
    defer allocator.free(parse_times);

    var overall_timer = try std.time.Timer.start();

    var iter: usize = 0;
    while (iter < iterations) : (iter += 1) {
        var iter_timer = try std.time.Timer.start();

        for (feeds) |feed_data| {
            var reader = RssReader.init(allocator);
            defer reader.deinit();

            var parsed = reader.parseXml(feed_data, null, null) catch {
                std.debug.print("  Warning: Parse failed on iteration {d}\n", .{iter});
                continue;
            };
            total_items_parsed += parsed.items.len;
            parsed.deinit();
        }

        const iter_time_ns = iter_timer.read();
        parse_times[iter] = @as(i64, @intCast(iter_time_ns));
    }

    // Calculate statistics
    const total_time_ns = overall_timer.read();
    const total_time_ms = @as(f64, @floatFromInt(total_time_ns)) / 1_000_000.0;
    const avg_iter_time_ns = @divTrunc(total_time_ns, @as(i128, @intCast(iterations)));
    const avg_iter_time_us = @as(f64, @floatFromInt(avg_iter_time_ns)) / 1_000.0;

    // Sort for percentiles
    std.mem.sort(i64, parse_times, {}, std.sort.asc(i64));

    const p50_idx = iterations / 2;
    const p95_idx = (iterations * 95) / 100;
    const p99_idx = (iterations * 99) / 100;

    const p50_us = @as(f64, @floatFromInt(parse_times[p50_idx])) / 1_000.0;
    const p95_us = @as(f64, @floatFromInt(parse_times[p95_idx])) / 1_000.0;
    const p99_us = @as(f64, @floatFromInt(parse_times[p99_idx])) / 1_000.0;
    const min_us = @as(f64, @floatFromInt(parse_times[0])) / 1_000.0;
    const max_us = @as(f64, @floatFromInt(parse_times[iterations - 1])) / 1_000.0;

    // Throughput calculations
    const total_items_expected = iterations * num_feeds * items_per_feed;
    const items_per_second = @as(f64, @floatFromInt(total_items_parsed)) / (total_time_ms / 1000.0);
    const kb_per_second = @as(f64, @floatFromInt(total_feed_size * iterations)) / (total_time_ms / 1000.0) / 1024.0;

    // Print results
    std.debug.print("═══════════════════════════════════════════════════════\n", .{});
    std.debug.print("                       RESULTS\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Timing (per iteration of {d} feeds):\n", .{num_feeds});
    std.debug.print("  Average:    {d:.2} µs\n", .{avg_iter_time_us});
    std.debug.print("  Median:     {d:.2} µs (p50)\n", .{p50_us});
    std.debug.print("  p95:        {d:.2} µs\n", .{p95_us});
    std.debug.print("  p99:        {d:.2} µs\n", .{p99_us});
    std.debug.print("  Min:        {d:.2} µs\n", .{min_us});
    std.debug.print("  Max:        {d:.2} µs\n", .{max_us});
    std.debug.print("\n", .{});
    std.debug.print("Throughput:\n", .{});
    std.debug.print("  Items parsed: {d} / {d} expected\n", .{ total_items_parsed, total_items_expected });
    std.debug.print("  Items/sec:    {d:.0}\n", .{items_per_second});
    std.debug.print("  KB/sec:       {d:.2}\n", .{kb_per_second});
    std.debug.print("\n", .{});
    std.debug.print("Total time: {d:.2} ms\n", .{total_time_ms});
    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════\n", .{});
    std.debug.print("\n✓ Benchmark complete. Memory status will be reported at exit.\n", .{});
}
