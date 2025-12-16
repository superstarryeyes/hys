const std = @import("std");
const types = @import("types");
const formatter = @import("formatter");
const config = @import("config");

// ============================================================================
// TYPES TESTS
// ============================================================================

test "FeedConfig clone preserves all fields" {
    const allocator = std.testing.allocator;

    const original = types.FeedConfig{
        .xmlUrl = try allocator.dupe(u8, "https://example.com/feed.xml"),
        .text = try allocator.dupe(u8, "Example Feed"),
        .enabled = true,
        .title = try allocator.dupe(u8, "Example Title"),
        .htmlUrl = try allocator.dupe(u8, "https://example.com"),
        .description = try allocator.dupe(u8, "A test feed"),
        .type = try allocator.dupe(u8, "rss"),
        .language = try allocator.dupe(u8, "en"),
        .version = try allocator.dupe(u8, "2.0"),
    };
    defer original.deinit(allocator);

    const cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expectEqualStrings(original.xmlUrl, cloned.xmlUrl);
    try std.testing.expectEqualStrings(original.text.?, cloned.text.?);
    try std.testing.expect(original.enabled == cloned.enabled);
    try std.testing.expectEqualStrings(original.title.?, cloned.title.?);
    try std.testing.expectEqualStrings(original.htmlUrl.?, cloned.htmlUrl.?);
    try std.testing.expectEqualStrings(original.description.?, cloned.description.?);
    try std.testing.expectEqualStrings(original.type.?, cloned.type.?);
    try std.testing.expectEqualStrings(original.language.?, cloned.language.?);
    try std.testing.expectEqualStrings(original.version.?, cloned.version.?);

    // Ensure they're different allocations
    try std.testing.expect(original.xmlUrl.ptr != cloned.xmlUrl.ptr);
}

test "FeedConfig with null fields" {
    const allocator = std.testing.allocator;

    const feed = types.FeedConfig{
        .xmlUrl = try allocator.dupe(u8, "https://example.com/feed.xml"),
        .text = null,
        .enabled = false,
    };
    defer feed.deinit(allocator);

    try std.testing.expect(feed.text == null);
    try std.testing.expect(!feed.enabled);
    try std.testing.expectEqualStrings("https://example.com/feed.xml", feed.xmlUrl);
}

test "cloneFeedList copies all feeds" {
    const allocator = std.testing.allocator;

    var original = types.FeedList{};
    defer types.deinitFeedList(allocator, &original);

    try original.append(allocator, types.FeedConfig{
        .xmlUrl = try allocator.dupe(u8, "https://feed1.com/rss"),
        .text = try allocator.dupe(u8, "Feed 1"),
    });
    try original.append(allocator, types.FeedConfig{
        .xmlUrl = try allocator.dupe(u8, "https://feed2.com/rss"),
        .text = try allocator.dupe(u8, "Feed 2"),
    });

    var cloned = try types.cloneFeedList(allocator, original);
    defer types.deinitFeedList(allocator, &cloned);

    try std.testing.expectEqual(original.items.len, cloned.items.len);
    try std.testing.expectEqualStrings(original.items[0].xmlUrl, cloned.items[0].xmlUrl);
    try std.testing.expectEqualStrings(original.items[1].xmlUrl, cloned.items[1].xmlUrl);
}

test "filterEnabledFeeds only returns enabled feeds" {
    const allocator = std.testing.allocator;

    var source = types.FeedList{};
    defer types.deinitFeedList(allocator, &source);

    try source.append(allocator, types.FeedConfig{
        .xmlUrl = try allocator.dupe(u8, "https://feed1.com/rss"),
        .enabled = true,
    });
    try source.append(allocator, types.FeedConfig{
        .xmlUrl = try allocator.dupe(u8, "https://feed2.com/rss"),
        .enabled = false,
    });
    try source.append(allocator, types.FeedConfig{
        .xmlUrl = try allocator.dupe(u8, "https://feed3.com/rss"),
        .enabled = true,
    });

    var filtered = try types.filterEnabledFeeds(allocator, source);
    defer types.deinitFeedList(allocator, &filtered);

    try std.testing.expectEqual(@as(usize, 2), filtered.items.len);
    try std.testing.expect(filtered.items[0].enabled);
    try std.testing.expect(filtered.items[1].enabled);
}

test "RssItem clone preserves all fields" {
    const allocator = std.testing.allocator;

    const original = types.RssItem{
        .title = try allocator.dupe(u8, "Article Title"),
        .description = try allocator.dupe(u8, "Article description"),
        .link = try allocator.dupe(u8, "https://example.com/article"),
        .pubDate = try allocator.dupe(u8, "2024-12-05"),
        .timestamp = 1733356800,
        .guid = try allocator.dupe(u8, "guid-12345"),
        .feedName = try allocator.dupe(u8, "Example Feed"),
    };
    defer original.deinit(allocator);

    const cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expectEqualStrings(original.title.?, cloned.title.?);
    try std.testing.expectEqualStrings(original.description.?, cloned.description.?);
    try std.testing.expectEqualStrings(original.link.?, cloned.link.?);
    try std.testing.expectEqual(original.timestamp, cloned.timestamp);
}

test "DisplayConfig has sensible defaults" {
    const display = types.DisplayConfig{};
    try std.testing.expectEqual(@as(usize, 120), display.maxTitleLength);
    try std.testing.expectEqual(@as(usize, 300), display.maxDescriptionLength);
    try std.testing.expectEqual(@as(usize, 20), display.maxItemsPerFeed);
    try std.testing.expect(display.showPublishDate);
    try std.testing.expect(display.showDescription);
    try std.testing.expect(display.showLink);
    try std.testing.expect(display.truncateUrls);
}

test "NetworkConfig has sensible defaults" {
    const network = types.NetworkConfig{};
    try std.testing.expectEqual(0.2, network.maxFeedSizeMB);
}

test "HistoryConfig has sensible defaults" {
    const history = types.HistoryConfig{};
    try std.testing.expectEqual(@as(u32, 50), history.retentionDays);
}

// ============================================================================
// FORMATTER TESTS
// ============================================================================

test "getCodepointDisplayWidth handles ASCII" {
    try std.testing.expectEqual(@as(usize, 1), formatter.getCodepointDisplayWidth('a'));
    try std.testing.expectEqual(@as(usize, 1), formatter.getCodepointDisplayWidth('Z'));
    try std.testing.expectEqual(@as(usize, 1), formatter.getCodepointDisplayWidth('5'));
}

test "getCodepointDisplayWidth handles CJK" {
    // Hangul Jamo
    try std.testing.expectEqual(@as(usize, 2), formatter.getCodepointDisplayWidth(0x1100));
    // CJK Unified Ideographs
    try std.testing.expectEqual(@as(usize, 2), formatter.getCodepointDisplayWidth(0x4E00));
    // Hangul Syllables
    try std.testing.expectEqual(@as(usize, 2), formatter.getCodepointDisplayWidth(0xAC00));
}

test "getCodepointDisplayWidth handles combining marks" {
    // Combining Diacritical Marks
    try std.testing.expectEqual(@as(usize, 0), formatter.getCodepointDisplayWidth(0x0300));
}

test "Formatter creates with default values" {
    const allocator = std.testing.allocator;

    const display = types.DisplayConfig{};
    const fmt = formatter.Formatter.init(allocator, display);

    // Terminal width is dynamically detected from environment
    // Can be 0 for piped output or a positive value if terminal detected
    try std.testing.expect(fmt.terminal_width >= 0);
    try std.testing.expect(fmt.terminal_width < 1000);
    try std.testing.expect(fmt.writer == null);
}

test "Formatter.initDirect sets writer" {
    const allocator = std.testing.allocator;

    const display = types.DisplayConfig{};
    var buf: [4096]u8 = undefined;
    var writer_state = std.fs.File.stdout().writer(&buf);
    const writer = &writer_state.interface;
    const fmt = formatter.Formatter.initDirect(allocator, display, writer.*);

    try std.testing.expect(fmt.writer != null);
}

// ============================================================================
// CONFIG TESTS
// ============================================================================

test "COLORS constants are non-empty" {
    try std.testing.expect(config.COLORS.RESET.len > 0);
    try std.testing.expect(config.COLORS.BOLD.len > 0);
    try std.testing.expect(config.COLORS.RED.len > 0);
    try std.testing.expect(config.COLORS.GREEN.len > 0);
    try std.testing.expect(config.COLORS.YELLOW.len > 0);
    try std.testing.expect(config.COLORS.BLUE.len > 0);
    try std.testing.expect(config.COLORS.CYAN.len > 0);
    try std.testing.expect(config.COLORS.GRAY.len > 0);
}

// ============================================================================
// INTEGRATION TESTS
// ============================================================================

test "GlobalConfig default creation" {
    const global = types.GlobalConfig{
        .display = types.DisplayConfig{},
        .history = types.HistoryConfig{},
        .network = types.NetworkConfig{},
    };

    try std.testing.expectEqual(@as(usize, 120), global.display.maxTitleLength);
    try std.testing.expectEqual(@as(u32, 50), global.history.retentionDays);
    try std.testing.expectEqual(0.2, global.network.maxFeedSizeMB);
}

test "FeedGroup.getDisplayName returns display_name when set" {
    const allocator = std.testing.allocator;

    var feeds = types.FeedList{};
    defer types.deinitFeedList(allocator, &feeds);

    const group = types.FeedGroup{
        .name = try allocator.dupe(u8, "tech"),
        .display_name = try allocator.dupe(u8, "Technology News"),
        .feeds = &.{},
    };
    defer group.deinit(allocator);

    const display_name = group.getDisplayName();
    try std.testing.expectEqualStrings("Technology News", display_name);
}

test "FeedGroup.getDisplayName returns name when display_name is null" {
    const allocator = std.testing.allocator;

    const group = types.FeedGroup{
        .name = try allocator.dupe(u8, "tech"),
        .display_name = null,
        .feeds = &.{},
    };
    defer group.deinit(allocator);

    const display_name = group.getDisplayName();
    try std.testing.expectEqualStrings("tech", display_name);
}

test "LastRunState initialization" {
    const state = types.LastRunState{
        .timestamp = 1733356800,
        .items = &.{},
    };

    try std.testing.expectEqual(@as(i64, 1733356800), state.timestamp.?);
    try std.testing.expectEqual(@as(usize, 0), state.items.len);
}

test "CurlError initialization and deinitialization" {
    const allocator = std.testing.allocator;

    const err = try types.CurlError.init(allocator, "Test error message");
    defer err.deinit(allocator);

    try std.testing.expectEqualStrings("Test error message", err.message);
}

// ============================================================================
// MEMORY SAFETY TESTS
// ============================================================================

test "FeedConfig deinit frees all strings" {
    const allocator = std.testing.allocator;

    const feed = types.FeedConfig{
        .xmlUrl = try allocator.dupe(u8, "https://example.com/feed.xml"),
        .text = try allocator.dupe(u8, "Example Feed"),
        .title = try allocator.dupe(u8, "Title"),
        .htmlUrl = try allocator.dupe(u8, "https://example.com"),
        .description = try allocator.dupe(u8, "Description"),
        .type = try allocator.dupe(u8, "rss"),
        .language = try allocator.dupe(u8, "en"),
        .version = try allocator.dupe(u8, "2.0"),
    };

    feed.deinit(allocator);
    // If deinit didn't free properly, teardownAllocator will catch memory leaks
}

test "RssItem deinit frees all strings" {
    const allocator = std.testing.allocator;

    const item = types.RssItem{
        .title = try allocator.dupe(u8, "Title"),
        .description = try allocator.dupe(u8, "Description"),
        .link = try allocator.dupe(u8, "https://example.com"),
        .pubDate = try allocator.dupe(u8, "2024-12-05"),
        .guid = try allocator.dupe(u8, "guid"),
        .feedName = try allocator.dupe(u8, "Feed"),
    };

    item.deinit(allocator);
}

// ============================================================================
// EDGE CASE TESTS
// ============================================================================

test "Empty feed list is valid" {
    const allocator = std.testing.allocator;

    var list = types.FeedList{};
    defer types.deinitFeedList(allocator, &list);

    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "All disabled feeds returns empty list" {
    const allocator = std.testing.allocator;

    var source = types.FeedList{};
    defer types.deinitFeedList(allocator, &source);

    try source.append(allocator, types.FeedConfig{
        .xmlUrl = try allocator.dupe(u8, "https://feed1.com/rss"),
        .enabled = false,
    });
    try source.append(allocator, types.FeedConfig{
        .xmlUrl = try allocator.dupe(u8, "https://feed2.com/rss"),
        .enabled = false,
    });

    var filtered = try types.filterEnabledFeeds(allocator, source);
    defer types.deinitFeedList(allocator, &filtered);

    try std.testing.expectEqual(@as(usize, 0), filtered.items.len);
}

test "RssItem with all null fields" {
    const allocator = std.testing.allocator;

    const item = types.RssItem{};
    defer item.deinit(allocator);

    try std.testing.expect(item.title == null);
    try std.testing.expect(item.description == null);
    try std.testing.expect(item.link == null);
    try std.testing.expect(item.pubDate == null);
    try std.testing.expect(item.guid == null);
    try std.testing.expect(item.feedName == null);
    try std.testing.expectEqual(@as(i64, 0), item.timestamp);
}

test "Very long feed URL" {
    const allocator = std.testing.allocator;

    const long_url = try std.fmt.allocPrint(allocator, "https://example.com/{s}", .{
        "a" ** 1000, // 1000 'a' characters
    });
    defer allocator.free(long_url);

    const feed = types.FeedConfig{
        .xmlUrl = try allocator.dupe(u8, long_url),
    };
    defer feed.deinit(allocator);

    try std.testing.expectEqual(long_url.len, feed.xmlUrl.len);
}

test "Unicode in feed name" {
    const allocator = std.testing.allocator;

    const feed = types.FeedConfig{
        .xmlUrl = try allocator.dupe(u8, "https://example.com/feed"),
        .text = try allocator.dupe(u8, "🚀 Rocket News 日本語"),
    };
    defer feed.deinit(allocator);

    try std.testing.expectEqualStrings("🚀 Rocket News 日本語", feed.text.?);
}

// ============================================================================
// TEST SUMMARY
// ============================================================================

pub fn main() !void {
    std.debug.print("Running comprehensive test suite for Hys\n", .{});
    std.debug.print("========================================\n\n", .{});
}
