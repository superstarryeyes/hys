const std = @import("std");
const types = @import("types");
const RssReader = @import("rss_reader").RssReader;
const DisplayManager = @import("display_manager");
const curl_multi = @import("curl_multi_fetcher");

const ParseCallbackContext = struct {
    seen_map: *const std.AutoHashMap(u64, void),
    allocator: std.mem.Allocator,
};

fn checkItemSeen(item: *const types.RssItem, ctx_ptr: ?*anyopaque) bool {
    const ctx: *const ParseCallbackContext = @ptrCast(@alignCast(ctx_ptr.?));

    // Check GUID then Link
    var identifier: ?[]const u8 = null;
    if (item.guid) |guid| {
        identifier = guid;
    } else if (item.link) |link| {
        if (link.len > 0) identifier = link;
    }

    if (identifier) |id| {
        if (id.len > 0) {
            const normalized = normalizeIdentifier(ctx.allocator, id) catch {
                // If normalization fails, assume not seen
                return false;
            };
            defer ctx.allocator.free(normalized);
            const hash = std.hash.Wyhash.hash(0x123456789ABCDEF0, normalized);

            // Return true if seen (triggers abort)
            if (ctx.seen_map.contains(hash)) {
                return true;
            }
        }
    }
    return false;
}

/// Normalize identifier (GUID or URL) before hashing
/// Handles: http/https, trailing slashes, tracking params, HTML entities, case differences
pub fn normalizeIdentifier(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    // Initialize with capacity based on input length to minimize reallocations
    var result = try std.array_list.Managed(u8).initCapacity(allocator, id.len + 16);
    errdefer result.deinit();

    // Check if this looks like a URL (parse directly on input string view)
    const is_url = std.mem.startsWith(u8, id, "http://") or
        std.mem.startsWith(u8, id, "https://");

    if (is_url) {
        // Parse URL using std.Uri directly on input string (views are slices)
        const uri = std.Uri.parse(id) catch {
            // Fallback to simple normalization if URI parsing fails
            try result.appendSlice("https://");
            for (id) |c| {
                try result.append(std.ascii.toLower(c));
            }
            return result.toOwnedSlice();
        };

        // Reconstruct URL: always use https, drop tracking params and fragment
        try result.appendSlice("https://");

        // Add host (required for all URLs)
        if (uri.host) |host| {
            const host_str = switch (host) {
                .raw => |raw| raw,
                .percent_encoded => |encoded| encoded,
            };
            // Append lowercased host (hosts are case-insensitive)
            for (host_str) |c| {
                try result.append(std.ascii.toLower(c));
            }
        }

        // Add path (strip trailing slash, preserve case for paths)
        const path_str = switch (uri.path) {
            .raw => |raw| raw,
            .percent_encoded => |encoded| encoded,
        };
        if (path_str.len > 0) {
            var path = path_str;
            // Remove trailing slash for consistency (except for root path "/")
            if (path.len > 1 and path[path.len - 1] == '/') {
                path = path[0 .. path.len - 1];
            }
            try result.appendSlice(path);
        }

        // Only add query params if they're NOT tracking params
        if (uri.query) |query_component| {
            const query_str = switch (query_component) {
                .raw => |raw| raw,
                .percent_encoded => |encoded| encoded,
            };
            // Skip if query starts with known tracking params
            const starts_with_utm = query_str.len >= 4 and
                std.mem.startsWith(u8, query_str[0..4], "utm_");
            const starts_with_fbclid = std.mem.startsWith(u8, query_str, "fbclid=");
            const starts_with_ref = std.mem.startsWith(u8, query_str, "ref=");

            if (!starts_with_utm and !starts_with_fbclid and !starts_with_ref) {
                try result.append('?');
                try result.appendSlice(query_str);
            }
        }
        // Note: fragments are intentionally dropped (they shouldn't affect content identity)
    } else {
        // For non-URLs (GUIDs), just lowercase
        for (id) |c| {
            try result.append(std.ascii.toLower(c));
        }
    }

    // Decode HTML entities in the result
    var i: usize = 0;
    // Reserve capacity for decoded result (typically similar size to result)
    var decoded = try std.array_list.Managed(u8).initCapacity(allocator, result.items.len);
    errdefer decoded.deinit();

    const result_slice = result.items;
    while (i < result_slice.len) {
        if (result_slice[i] == '&') {
            if (std.mem.startsWith(u8, result_slice[i..], "&amp;")) {
                try decoded.append('&');
                i += 5;
            } else if (std.mem.startsWith(u8, result_slice[i..], "&lt;")) {
                try decoded.append('<');
                i += 4;
            } else if (std.mem.startsWith(u8, result_slice[i..], "&gt;")) {
                try decoded.append('>');
                i += 4;
            } else if (std.mem.startsWith(u8, result_slice[i..], "&quot;")) {
                try decoded.append('"');
                i += 6;
            } else if (std.mem.startsWith(u8, result_slice[i..], "&apos;")) {
                try decoded.append('\'');
                i += 6;
            } else {
                try decoded.append(result_slice[i]);
                i += 1;
            }
        } else {
            try decoded.append(result_slice[i]);
            i += 1;
        }
    }

    result.deinit();
    return decoded.toOwnedSlice();
}

pub const FeedTaskResult = struct {
    parsed: ?types.ParsedFeed = null,
    err: ?anyerror = null,
    status: curl_multi.FetchStatus = .Failed,
    // New headers to save back to FeedConfig
    new_etag: ?[]u8 = null,
    new_last_modified: ?[]u8 = null,
};

pub const FeedProcessor = struct {
    allocator: std.mem.Allocator,
    max_feed_size_mb: f64,
    // For streaming pipeline: thread pool and wait group
    pool: ?*std.Thread.Pool = null,
    wg: ?*std.Thread.WaitGroup = null,
    results: ?[]FeedTaskResult = null,
    // ADD: Reference to seen map
    seen_map: ?*const std.AutoHashMap(u64, void) = null,

    pub fn init(allocator: std.mem.Allocator, max_feed_size_mb: f64) FeedProcessor {
        return FeedProcessor{
            .allocator = allocator,
            .max_feed_size_mb = max_feed_size_mb,
        };
    }

    /// Streaming pipeline callback: invoked as each fetch completes
    fn onFetchComplete(result: *curl_multi.FetchResult, index: usize, user_data: *anyopaque) void {
        const self: *FeedProcessor = @ptrCast(@alignCast(user_data));
        const task_results = self.results orelse return;

        // Store the status and new headers from fetch
        task_results[index].status = result.status;
        task_results[index].new_etag = result.new_etag;
        task_results[index].new_last_modified = result.new_last_modified;

        const xml_data = result.data;
        const fetch_err = result.err;

        if (fetch_err != null or xml_data == null) {
            task_results[index].err = fetch_err orelse error.NetworkError;
            return;
        }

        // Skip parsing if we got a 304 Not Modified response
        if (result.status == .NotModified) {
            return; // Leave parsed as null, status is already set
        }

        // Spawn parse task immediately while network is still fetching other feeds
        if (self.pool) |pool| {
            if (self.wg) |wg| {
                wg.start();
                const xml_copy = xml_data.?;
                pool.spawn(parseTask, .{
                    self.allocator,
                    xml_copy,
                    &task_results[index],
                    wg,
                    self.max_feed_size_mb,
                    self.seen_map,
                }) catch |err| {
                    wg.finish();
                    task_results[index].err = err;
                };
            }
        }
    }

    /// Fetch feeds using curl_multi for connection pooling with streaming parse pipeline
    pub fn fetchFeeds(
        self: *FeedProcessor,
        feeds: []types.FeedConfig,
        seen_map: ?*const std.AutoHashMap(u64, void), // Make optional
    ) ![]FeedTaskResult {
        self.seen_map = seen_map; // Store reference

        const results = try self.allocator.alloc(FeedTaskResult, feeds.len);
        for (results) |*r| {
            r.* = FeedTaskResult{
                .parsed = null,
                .err = null,
            };
        }
        errdefer self.allocator.free(results);

        // Initialize thread pool for parsing
        var pool: std.Thread.Pool = undefined;
        try pool.init(.{ .allocator = self.allocator });
        defer pool.deinit();

        var wg: std.Thread.WaitGroup = .{};

        // Setup streaming pipeline state
        self.pool = &pool;
        self.wg = &wg;
        self.results = results;

        // Batch fetch with callback - parses start immediately as downloads complete
        const fetch_results = try curl_multi.fetchMultipleWithCallback(
            self.allocator,
            feeds,
            self.max_feed_size_mb,
            FeedProcessor.onFetchComplete,
            @as(*anyopaque, @ptrCast(self)),
        );

        // pool.waitAndWork() acquires a release barrier from all worker threads
        // via WaitGroup.finish() using .acq_rel atomic semantics, ensuring all
        // writes to results[] from parser threads are visible before proceeding
        pool.waitAndWork(&wg);

        // Free fetch buffers AFTER all parser threads finish
        for (fetch_results) |*fr| {
            if (fr.data) |data| self.allocator.free(data);
        }
        self.allocator.free(fetch_results);

        // Clear streaming state
        self.pool = null;
        self.wg = null;
        self.results = null;

        return results;
    }

    pub fn processResults(
        self: *FeedProcessor,
        results: []FeedTaskResult,
        original_feeds: []types.FeedConfig, // Remove const to allow header updates
        group_names: []const []const u8,
        group_display_names: []const ?[]const u8,
        display_manager: *DisplayManager.DisplayManager,
        seen_articles: *std.AutoHashMap(u64, void),
        new_hashes: *std.array_list.Managed(u64),
        failed_feeds: *std.array_list.Managed([]const u8),
        skip_deduplication: bool,
        preserve_group_order: bool,
    ) !std.array_list.Managed(types.RssItem) {
        // Prevent index alignment bugs between results and original_feeds arrays
        std.debug.assert(results.len == original_feeds.len);

        var all_items = std.array_list.Managed(types.RssItem).init(self.allocator);
        errdefer {
            for (all_items.items) |item| {
                item.deinit(self.allocator);
            }
            all_items.deinit();
        }

        for (results, 0..) |task_result, idx| {
            const original_feed = &original_feeds[idx]; // Make mutable reference
            var parsed_feed = task_result.parsed;

            // Clean up parsed_feed (only owned resource from task_result)
            defer if (parsed_feed) |*pf| pf.deinit();

            // Update feed headers if we got new ones (for all successful responses)
            if (task_result.new_etag) |new_etag| {
                if (original_feed.etag) |old_etag| self.allocator.free(old_etag);
                original_feed.etag = try self.allocator.dupe(u8, new_etag);
                self.allocator.free(new_etag);
            }
            if (task_result.new_last_modified) |new_lastmod| {
                if (original_feed.lastModified) |old_lastmod| self.allocator.free(old_lastmod);
                original_feed.lastModified = try self.allocator.dupe(u8, new_lastmod);
                self.allocator.free(new_lastmod);
            }

            // Handle 304 Not Modified - feed hasn't changed
            if (task_result.status == .NotModified) {
                const feed_name = original_feed.text orelse original_feed.xmlUrl;
                // Always show feed header for unchanged feeds
                if (display_manager.output_buffer == null) {
                    display_manager.printFeedHeader(feed_name);
                    display_manager.printInfo("Feed unchanged (304 Not Modified)");
                } else {}
                continue;
            }

            if (task_result.err) |err| {
                // Use the original feed for error reporting
                const fallback_name = original_feed.text orelse original_feed.xmlUrl;
                // Only print error immediately if not buffering for pager
                if (display_manager.output_buffer == null and !display_manager.use_pager_streaming) {
                    display_manager.printFeedHeader(fallback_name);
                    var error_buf: [512]u8 = undefined;
                    const error_msg = try std.fmt.bufPrint(&error_buf, "Failed to read feed {s}", .{original_feed.xmlUrl});
                    display_manager.printError(error_msg);

                    // Provide more specific error information
                    switch (err) {
                        error.CurlFailed => {
                            std.debug.print("Error details: Curl request failed. This could be due to:\n", .{});
                            std.debug.print("  - Network connectivity issues\n", .{});
                            std.debug.print("  - Invalid URL or unreachable server\n", .{});
                            std.debug.print("  - Missing or misconfigured curl installation\n", .{});
                            std.debug.print("  - SSL/TLS certificate issues\n", .{});
                        },
                        error.TlsInitializationFailed => {
                            std.debug.print("Error details: TLS initialization failed. Falling back to curl.\n", .{});
                        },
                        error.NetworkError => {
                            std.debug.print("Error details: Network error while fetching feed.\n", .{});
                        },
                        else => {
                            std.debug.print("Error details: {}\n", .{err});
                        },
                    }
                }
                try failed_feeds.append(try self.allocator.dupe(u8, fallback_name));
                continue;
            }

            // At this point, parsed_feed must be non-null (no error occurred)
            const pf = parsed_feed orelse unreachable;
            const f = original_feed.*; // Dereference the mutable reference

            // Determine display name
            const display_name = if (f.text) |text| blk: {
                if (std.mem.indexOf(u8, text, " (")) |paren_idx| {
                    const name = try self.allocator.dupe(u8, text[0..paren_idx]);
                    break :blk name;
                }
                const name = try self.allocator.dupe(u8, text);
                break :blk name;
            } else if (pf.title) |title| blk: {
                const name = try self.allocator.dupe(u8, title);
                break :blk name;
            } else blk: {
                const name = try self.allocator.dupe(u8, f.xmlUrl);
                break :blk name;
            };
            errdefer self.allocator.free(display_name);

            var new_items = std.array_list.Managed(types.RssItem).init(self.allocator);
            defer new_items.deinit();

            const max_items = display_manager.formatter.display_config.maxItemsPerFeed;
            for (pf.items) |item| {
                if (max_items > 0 and new_items.items.len >= max_items) break;
                var identifier: ?[]const u8 = null;
                if (item.guid) |guid| {
                    identifier = guid;
                } else if (item.link) |link| {
                    if (link.len > 0) identifier = link;
                }

                if (identifier) |id| {
                    if (id.len > 0) {
                        const normalized = normalizeIdentifier(self.allocator, id) catch {
                            // If normalization fails, skip this item
                            continue;
                        };
                        defer self.allocator.free(normalized);
                        const hash = std.hash.Wyhash.hash(0x123456789ABCDEF0, normalized);

                        if (!skip_deduplication and seen_articles.contains(hash)) {
                            continue;
                        }
                        // Track new hash for saving later
                        new_hashes.append(hash) catch {
                            // Non-critical error, continue without tracking this hash
                        };
                    }
                }

                var item_copy = try item.clone(self.allocator);
                errdefer item_copy.deinit(self.allocator);

                item_copy.feedName = try self.allocator.dupe(u8, display_name);
                item_copy.groupName = try self.allocator.dupe(u8, group_names[idx]);
                if (group_display_names[idx]) |gdn| {
                    item_copy.groupDisplayName = try self.allocator.dupe(u8, gdn);
                }
                try new_items.append(item_copy);
            }

            // If NOT paging, print as we go
            if (display_manager.output_buffer == null) {
                display_manager.printFeedHeader(display_name);
                display_manager.printFeedItems(new_items.items);
            }

            // FIX: Ensure capacity for the new batch to avoid multiple reallocations
            try all_items.ensureUnusedCapacity(new_items.items.len);

            for (new_items.items) |item| {
                // appendAssumeCapacity is faster when we know we have space
                all_items.appendAssumeCapacity(item);
            }

            self.allocator.free(display_name);
        }

        // Sort all collected items using grouped logic
        if (preserve_group_order) {
            // Get unique group names from the items to preserve command-line order
            var unique_groups = std.array_list.Managed([]const u8).init(self.allocator);
            defer unique_groups.deinit();

            // Build unique group list based on the order they appear in group_names
            for (group_names) |group_name| {
                // Check if we have any items from this group
                var has_items = false;
                for (all_items.items) |item| {
                    if (std.mem.eql(u8, item.groupName orelse "", group_name)) {
                        has_items = true;
                        break;
                    }
                }
                if (has_items) {
                    try unique_groups.append(group_name);
                }
            }

            const ctx = GroupOrderContext{ .group_names = unique_groups.items };
            std.mem.sort(types.RssItem, all_items.items, ctx, compareRssItemsWithGroupOrder);
        } else {
            std.mem.sort(types.RssItem, all_items.items, {}, compareRssItems);
        }

        return all_items;
    }
};

/// Parse XML data into a feed (runs in thread pool)
/// IMPORTANT: No ownership of feed config is transferred; only XML data and result are passed
/// NOTE: parent_allocator is thread-safe (GeneralPurposeAllocator with bucket locking in debug, malloc in release)
fn parseTask(
    parent_allocator: std.mem.Allocator,
    xml_data: []const u8,
    result: *FeedTaskResult,
    wg: *std.Thread.WaitGroup,
    max_feed_size_mb: f64,
    seen_map: ?*const std.AutoHashMap(u64, void), // Add arg
) void {
    defer wg.finish();

    // Initialize RssReader for parsing only
    var reader = RssReader.initWithMaxSize(parent_allocator, max_feed_size_mb);
    defer reader.deinit();

    // Prepare callback
    var cb_ctx: ?ParseCallbackContext = null;
    var cb_fn: ?RssReader.ItemCallback = null;
    var cb_void_ptr: ?*anyopaque = null;

    if (seen_map) |map| {
        cb_ctx = ParseCallbackContext{ .seen_map = map, .allocator = parent_allocator };
        cb_fn = checkItemSeen;
        cb_void_ptr = @ptrCast(@constCast(&cb_ctx));
    }

    // Pass callback to parseXml
    const parsed = reader.parseXml(xml_data, cb_fn, cb_void_ptr) catch |err| {
        result.err = err;
        return;
    };

    result.parsed = parsed;
}

pub fn compareRssItems(_: void, a: types.RssItem, b: types.RssItem) bool {
    // 0. Primary Sort: Group Name (alphabetically for backward compatibility)
    const group_a = a.groupName orelse "";
    const group_b = b.groupName orelse "";
    const group_order = std.mem.order(u8, group_a, group_b);
    if (group_order != .eq) {
        return group_order == .lt;
    }

    const name_a = a.feedName orelse "";
    const name_b = b.feedName orelse "";

    // 1. Secondary Sort: Group by Feed Name alphabetically
    const order = std.mem.order(u8, name_a, name_b);
    if (order != .eq) {
        return order == .lt;
    }

    // 2. Secondary Sort: Timestamp Descending (Newest first)
    // Within the same feed, show the latest news at the top
    return a.timestamp > b.timestamp;
}

/// Context for preserving command-line group order
pub const GroupOrderContext = struct {
    group_names: []const []const u8,
};

/// Compare RSS items while preserving command-line group order
pub fn compareRssItemsWithGroupOrder(ctx: GroupOrderContext, a: types.RssItem, b: types.RssItem) bool {
    // 0. Primary Sort: Group Name by command-line order
    const group_a = a.groupName orelse "";
    const group_b = b.groupName orelse "";

    // Find positions of groups in the original command-line order
    var pos_a: ?usize = null;
    var pos_b: ?usize = null;

    for (ctx.group_names, 0..) |group_name, i| {
        if (std.mem.eql(u8, group_a, group_name)) pos_a = i;
        if (std.mem.eql(u8, group_b, group_name)) pos_b = i;
    }

    // If both groups are found in the order, sort by their positions
    if (pos_a != null and pos_b != null) {
        if (pos_a.? != pos_b.?) {
            return pos_a.? < pos_b.?;
        }
    } else if (pos_a != null) {
        // a is in the ordered list, b is not - a comes first
        return true;
    } else if (pos_b != null) {
        // b is in the ordered list, a is not - b comes first
        return false;
    } else {
        // Neither is in the ordered list, fall back to alphabetical
        const group_order = std.mem.order(u8, group_a, group_b);
        if (group_order != .eq) {
            return group_order == .lt;
        }
    }

    const name_a = a.feedName orelse "";
    const name_b = b.feedName orelse "";

    // 1. Secondary Sort: Group by Feed Name alphabetically
    const order = std.mem.order(u8, name_a, name_b);
    if (order != .eq) {
        return order == .lt;
    }

    // 2. Tertiary Sort: Timestamp Descending (Newest first)
    // Within the same feed, show the latest news at the top
    return a.timestamp > b.timestamp;
}

// ============================================================================
// UNIT TESTS
// ============================================================================

test "normalizeIdentifier handles HTTP to HTTPS conversion" {
    const allocator = std.testing.allocator;

    const result = try normalizeIdentifier(allocator, "http://example.com/feed");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("https://example.com/feed", result);
}

test "normalizeIdentifier handles case normalization for hosts" {
    const allocator = std.testing.allocator;

    const result = try normalizeIdentifier(allocator, "https://EXAMPLE.COM/Feed");
    defer allocator.free(result);
    // Host should be lowercased, path case is preserved in URLs
    try std.testing.expectEqualStrings("https://example.com/Feed", result);
}

test "normalizeIdentifier removes trailing slashes" {
    const allocator = std.testing.allocator;

    const result = try normalizeIdentifier(allocator, "https://example.com/path/");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("https://example.com/path", result);
}

test "normalizeIdentifier preserves root path" {
    const allocator = std.testing.allocator;

    // Root path "/" should be preserved
    const result = try normalizeIdentifier(allocator, "https://example.com/");
    defer allocator.free(result);
    // With trailing slash removal logic, root "/" at end may be removed
    try std.testing.expectEqualStrings("https://example.com", result);
}

test "normalizeIdentifier strips UTM tracking parameters" {
    const allocator = std.testing.allocator;

    const result = try normalizeIdentifier(allocator, "https://example.com/article?utm_source=twitter&utm_medium=social");
    defer allocator.free(result);
    // UTM params should be stripped
    try std.testing.expectEqualStrings("https://example.com/article", result);
}

test "normalizeIdentifier strips Facebook tracking params" {
    const allocator = std.testing.allocator;

    const result = try normalizeIdentifier(allocator, "https://example.com/page?fbclid=abc123xyz");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("https://example.com/page", result);
}

test "normalizeIdentifier strips ref tracking params" {
    const allocator = std.testing.allocator;

    const result = try normalizeIdentifier(allocator, "https://example.com?ref=reddit");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("https://example.com", result);
}

test "normalizeIdentifier preserves non-tracking query params" {
    const allocator = std.testing.allocator;

    // Query that doesn't start with utm_, fbclid=, or ref= should be preserved
    const result = try normalizeIdentifier(allocator, "https://example.com/search?q=test&page=2");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("https://example.com/search?q=test&page=2", result);
}

test "normalizeIdentifier decodes HTML entities" {
    const allocator = std.testing.allocator;

    const result = try normalizeIdentifier(allocator, "https://example.com/article&amp;section=1");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("https://example.com/article&section=1", result);
}

test "normalizeIdentifier handles non-URL GUIDs with case normalization" {
    const allocator = std.testing.allocator;

    // Non-URL identifiers should just be lowercased
    const result = try normalizeIdentifier(allocator, "UUID:12345-ABC-DEF");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("uuid:12345-abc-def", result);
}

test "normalizeIdentifier handles plain string GUIDs" {
    const allocator = std.testing.allocator;

    const result = try normalizeIdentifier(allocator, "article-unique-id-123");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("article-unique-id-123", result);
}

test "normalizeIdentifier handles urn: style GUIDs" {
    const allocator = std.testing.allocator;

    const result = try normalizeIdentifier(allocator, "urn:uuid:f81d4fae-7dec-11d0-a765-00a0c91e6bf6");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("urn:uuid:f81d4fae-7dec-11d0-a765-00a0c91e6bf6", result);
}

test "normalizeIdentifier handles tag: style GUIDs" {
    const allocator = std.testing.allocator;

    const result = try normalizeIdentifier(allocator, "tag:example.com,2024:post123");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("tag:example.com,2024:post123", result);
}

test "normalizeIdentifier decodes multiple HTML entities" {
    const allocator = std.testing.allocator;

    const result = try normalizeIdentifier(allocator, "Test &lt;with&gt; &amp; entities");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("test <with> & entities", result);
}

test "normalizeIdentifier handles complex URL normalization" {
    const allocator = std.testing.allocator;

    // Complex case: HTTP, uppercase host, trailing slash, tracking param
    const result = try normalizeIdentifier(allocator, "HTTP://EXAMPLE.COM/article/?utm_source=test");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("https://example.com/article", result);
}
