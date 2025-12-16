const std = @import("std");
const types = @import("types");

// OPML round-trip and type preservation tests
// Run with: zig build test-opml
// 
// Note: OpmlManager's helper functions (escapeXml, sanitizeXmlContent, collapseSpaces)
// are private. These tests focus on the public API and type behavior.

// ============================================================================
// FEEDCONFIG FIELD PRESERVATION TESTS
// ============================================================================

test "FeedConfig preserves all OPML fields" {
    const feed = types.FeedConfig{
        .xmlUrl = "https://example.com/feed.xml",
        .text = "Example Feed",
        .enabled = true,
        .title = "Example Title",
        .htmlUrl = "https://example.com",
        .description = "A test description",
        .type = "rss",
        .language = "en",
        .version = "2.0",
    };

    // Verify all fields are accessible
    try std.testing.expectEqualStrings("https://example.com/feed.xml", feed.xmlUrl);
    try std.testing.expectEqualStrings("Example Feed", feed.text.?);
    try std.testing.expectEqualStrings("Example Title", feed.title.?);
    try std.testing.expectEqualStrings("https://example.com", feed.htmlUrl.?);
    try std.testing.expectEqualStrings("A test description", feed.description.?);
    try std.testing.expectEqualStrings("rss", feed.type.?);
    try std.testing.expectEqualStrings("en", feed.language.?);
    try std.testing.expectEqualStrings("2.0", feed.version.?);
}

test "FeedConfig clone preserves OPML metadata" {
    const allocator = std.testing.allocator;

    const original = types.FeedConfig{
        .xmlUrl = try allocator.dupe(u8, "https://example.com/feed.xml"),
        .text = try allocator.dupe(u8, "Feed Name"),
        .enabled = true,
        .title = try allocator.dupe(u8, "Feed Title"),
        .htmlUrl = try allocator.dupe(u8, "https://example.com"),
        .description = try allocator.dupe(u8, "Feed description"),
        .type = try allocator.dupe(u8, "rss"),
        .language = try allocator.dupe(u8, "en-US"),
        .version = try allocator.dupe(u8, "2.0"),
    };
    defer original.deinit(allocator);

    const cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    // Verify all OPML fields are preserved
    try std.testing.expectEqualStrings(original.xmlUrl, cloned.xmlUrl);
    try std.testing.expectEqualStrings(original.text.?, cloned.text.?);
    try std.testing.expectEqualStrings(original.title.?, cloned.title.?);
    try std.testing.expectEqualStrings(original.htmlUrl.?, cloned.htmlUrl.?);
    try std.testing.expectEqualStrings(original.description.?, cloned.description.?);
    try std.testing.expectEqualStrings(original.type.?, cloned.type.?);
    try std.testing.expectEqualStrings(original.language.?, cloned.language.?);
    try std.testing.expectEqualStrings(original.version.?, cloned.version.?);
}

test "FeedConfig handles null optional fields" {
    const feed = types.FeedConfig{
        .xmlUrl = "https://example.com/feed.xml",
        .text = null,
        .enabled = true,
        .title = null,
        .htmlUrl = null,
        .description = null,
        .type = null,
        .language = null,
        .version = null,
    };

    try std.testing.expect(feed.text == null);
    try std.testing.expect(feed.title == null);
    try std.testing.expect(feed.htmlUrl == null);
    try std.testing.expect(feed.description == null);
    try std.testing.expect(feed.type == null);
    try std.testing.expect(feed.language == null);
    try std.testing.expect(feed.version == null);
}

// ============================================================================
// FEEDGROUP TESTS
// ============================================================================

test "FeedGroup stores display_name separately from name" {
    const group = types.FeedGroup{
        .name = "tech_news",
        .display_name = "Technology News",
        .feeds = &.{},
    };

    try std.testing.expectEqualStrings("tech_news", group.name);
    try std.testing.expectEqualStrings("Technology News", group.display_name.?);
    try std.testing.expectEqualStrings("Technology News", group.getDisplayName());
}

test "FeedGroup.getDisplayName falls back to name when display_name is null" {
    const group = types.FeedGroup{
        .name = "tech",
        .display_name = null,
        .feeds = &.{},
    };

    try std.testing.expectEqualStrings("tech", group.getDisplayName());
}

// ============================================================================
// FEEDLIST OPERATIONS
// ============================================================================

test "cloneFeedListFromSlice preserves all feeds" {
    const allocator = std.testing.allocator;

    var feeds: [2]types.FeedConfig = .{
        types.FeedConfig{
            .xmlUrl = "https://feed1.com/rss",
            .text = "Feed 1",
        },
        types.FeedConfig{
            .xmlUrl = "https://feed2.com/rss",
            .text = "Feed 2",
        },
    };

    var cloned = try types.cloneFeedListFromSlice(allocator, &feeds);
    defer types.deinitFeedList(allocator, &cloned);

    try std.testing.expectEqual(@as(usize, 2), cloned.items.len);
    try std.testing.expectEqualStrings("https://feed1.com/rss", cloned.items[0].xmlUrl);
    try std.testing.expectEqualStrings("https://feed2.com/rss", cloned.items[1].xmlUrl);
}

// ============================================================================
// SPECIAL CHARACTER HANDLING (at types level)
// ============================================================================

test "FeedConfig handles special XML characters in fields" {
    const allocator = std.testing.allocator;

    const feed = types.FeedConfig{
        .xmlUrl = try allocator.dupe(u8, "https://example.com/feed?a=1&b=2"),
        .text = try allocator.dupe(u8, "Tom & Jerry <Show>"),
        .description = try allocator.dupe(u8, "Contains \"quotes\" and 'apostrophes'"),
    };
    defer feed.deinit(allocator);

    // Verify special characters are stored correctly
    try std.testing.expect(std.mem.indexOf(u8, feed.xmlUrl, "&") != null);
    try std.testing.expect(std.mem.indexOf(u8, feed.text.?, "&") != null);
    try std.testing.expect(std.mem.indexOf(u8, feed.text.?, "<") != null);
    try std.testing.expect(std.mem.indexOf(u8, feed.description.?, "\"") != null);
}

test "FeedConfig handles unicode in text fields" {
    const allocator = std.testing.allocator;

    const feed = types.FeedConfig{
        .xmlUrl = try allocator.dupe(u8, "https://example.com/feed"),
        .text = try allocator.dupe(u8, "日本語ニュース 🚀"),
        .description = try allocator.dupe(u8, "émoji et français"),
    };
    defer feed.deinit(allocator);

    try std.testing.expectEqualStrings("日本語ニュース 🚀", feed.text.?);
    try std.testing.expectEqualStrings("émoji et français", feed.description.?);
}

// ============================================================================
// EDGE CASES
// ============================================================================

test "empty FeedList is valid" {
    const allocator = std.testing.allocator;
    var list = types.FeedList{};
    defer types.deinitFeedList(allocator, &list);

    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "FeedConfig with very long URL" {
    const allocator = std.testing.allocator;

    // Create a very long URL (1000+ characters)
    var long_url_buf: [1200]u8 = undefined;
    var i: usize = 0;
    const prefix = "https://example.com/very/long/path/";
    @memcpy(long_url_buf[0..prefix.len], prefix);
    i = prefix.len;
    while (i < 1100) : (i += 1) {
        long_url_buf[i] = 'a';
    }

    const long_url = try allocator.dupe(u8, long_url_buf[0..i]);
    defer allocator.free(long_url);

    const feed = types.FeedConfig{
        .xmlUrl = long_url,
    };

    try std.testing.expectEqual(i, feed.xmlUrl.len);
}
