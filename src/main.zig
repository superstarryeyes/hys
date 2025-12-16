const std = @import("std");
const builtin = @import("builtin");
const zdt = @import("zdt");
const types = @import("types");
const config = @import("config");
const ConfigManager = config.ConfigManager;
const RssReader = @import("rss_reader").RssReader;
const DailyLimiter = @import("daily_limiter").DailyLimiter;
const OpmlManager = @import("opml").OpmlManager;
const CliParser = @import("cli_parser").CliParser;
const FeedProcessor = @import("feed_processor").FeedProcessor;
const DisplayManager = @import("display_manager").DisplayManager;

const curl = @cImport({
    @cInclude("curl/curl.h");
});

/// Helper function to check for a flag by both long and short names
fn hasAnyArg(cli: CliParser, long_name: []const u8, short_name: []const u8) bool {
    return cli.hasArg(long_name) or cli.hasArg(short_name);
}

/// Helper function to get argument value by either long or short name
fn getAnyArgValue(cli: CliParser, long_name: []const u8, short_name: []const u8) ?[]const u8 {
    return cli.getArgValue(long_name) orelse cli.getArgValue(short_name);
}

fn runLoadingAnimation(is_loading: *std.atomic.Value(bool), feed_count: usize, stdout: *std.io.Writer) void {
    var frame_index: usize = 0;
    while (is_loading.load(.acquire)) {
        const braille_frame = config.BRAILLE_ANIMATION[frame_index % config.BRAILLE_ANIMATION.len];
        stdout.print("\r{s}{s}{s} {s}Reading {d} feed(s)...{s}", .{
            config.COLORS.YELLOW,
            braille_frame,
            config.COLORS.RESET,
            config.COLORS.CYAN,
            feed_count,
            config.COLORS.RESET,
        }) catch {};
        stdout.flush() catch {};
        frame_index += 1;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}

pub fn main() !void {
    // Windows ANSI fix
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        const handle = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE) orelse w.INVALID_HANDLE_VALUE;
        var mode: w.DWORD = 0;
        if (w.kernel32.GetConsoleMode(handle, &mode) != 0) {
            // ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
            _ = w.kernel32.SetConsoleMode(handle, mode | 4);
        }
        // Also set UTF-8 output mode for emojis/CJK
        // CP_UTF8 = 65001
        _ = w.kernel32.SetConsoleOutputCP(65001);
    }

    // Initialize libcurl globally (must be done before any curl operations)
    if (curl.curl_global_init(curl.CURL_GLOBAL_ALL) != curl.CURLE_OK) {
        std.debug.print("Failed to initialize libcurl\n", .{});
        return;
    }
    defer curl.curl_global_cleanup();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_state = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_state.interface;

    defer stdout.flush() catch {};

    // Use GPA in debug builds to detect memory leaks, fallback to C allocator otherwise
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // Explicitly check for .leak
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;
    defer if (builtin.mode == .Debug) {
        const check = gpa.deinit();
        if (check == .leak) {
            std.log.err("Memory leak detected!", .{});
        }
    };

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    try runApp(allocator, args, stdout);
}

fn runApp(allocator: std.mem.Allocator, args: [][:0]u8, stdout: *std.io.Writer) !void {
    var cli = CliParser.init(allocator, args);

    if (cli.hasArg("--version") or cli.hasArg("-v")) {
        try stdout.print("hys 0.1.0\n", .{});
        return;
    }

    if (cli.hasArg("--help") or cli.hasArg("-h")) {
        CliParser.printHelp();
        return;
    }

    var config_manager = try ConfigManager.init(allocator);
    defer config_manager.deinit();

    // Handle config flag (shows config file location)
    if (hasAnyArg(cli, "--config", "-c")) {
        const config_path = config_manager.getConfigPath();
        try stdout.print("Configuration file location:\n", .{});
        try stdout.print("  {s}\n", .{config_path});
        try stdout.print("Edit this file to customize feeds and display settings.\n", .{});
        return;
    }

    if (hasAnyArg(cli, "--groups", "-g")) {
        const group_names = config_manager.getAllGroupNames() catch |err| {
            try stdout.print("Failed to load group list: {}\n", .{err});
            return;
        };
        defer {
            for (group_names) |name| allocator.free(name);
            allocator.free(group_names);
        }

        if (group_names.len == 0) {
            try stdout.print("No feed groups found. Use --sub to create one.\n", .{});
            return;
        }

        try stdout.print("Available feed groups:\n", .{});
        for (group_names) |name| {
            // Get display name if available
            const display_name = config_manager.getGroupDisplayName(name) catch null;
            defer if (display_name) |dn| allocator.free(dn);

            if (display_name) |dn| {
                try stdout.print("  {s} ({s})\n", .{ name, dn });
            } else {
                try stdout.print("  {s}\n", .{name});
            }
        }
        return;
    }

    // Parse group names (supports comma-separated list)
    const parsed_groups = cli.parseGroupNames() catch |err| {
        try stdout.print("Failed to parse arguments: {}\n", .{err});
        return;
    };
    defer allocator.free(parsed_groups);

    // --- NEW LOGIC START ---
    var group_names: []const []const u8 = undefined;
    var groups_need_free = false; // Track if we need to free the list from getAllGroupNames

    if (hasAnyArg(cli, "--all", "-a")) {
        // If --all is passed, ignore positional group names and load everything
        group_names = config_manager.getAllGroupNames() catch |err| {
            try stdout.print("Failed to load group list: {}\n", .{err});
            return;
        };
        groups_need_free = true;

        if (group_names.len == 0) {
            try stdout.print("No feed groups found. Use --sub to create one.\n", .{});
            return;
        }
    } else {
        // Default behavior
        group_names = if (parsed_groups.len > 0) parsed_groups else &[_][]const u8{"main"};
    }

    // Clean up group_names at end of scope if they came from getAllGroupNames
    defer if (groups_need_free) {
        for (group_names) |name| allocator.free(name);
        allocator.free(group_names);
    };
    // --- NEW LOGIC END ---

    // We use the first group for operations that need a single context (like CLI flags that apply to one group)
    const primary_group_name = group_names[0];

    var global_config = try config_manager.loadGlobalConfig();

    // Check flags
    if (cli.hasArg("--pager")) {
        global_config.display.pagerMode = true;
    }
    if (cli.hasArg("--no-pager")) {
        global_config.display.pagerMode = false;
    }

    // Initialize the primary limiter using the first group (used for global operations like seen hashes)
    var limiter = try DailyLimiter.init(allocator, primary_group_name, global_config.history.dayStartHour, global_config.history.fetchIntervalDays);
    defer limiter.deinit();

    var reader = RssReader.init(allocator);
    defer reader.deinit();

    if (hasAnyArg(cli, "--reset", "-r")) {
        // Reset for ALL specified groups
        for (group_names) |g_name| {
            var group_limiter = try DailyLimiter.init(allocator, g_name, global_config.history.dayStartHour, global_config.history.fetchIntervalDays);
            defer group_limiter.deinit();
            group_limiter.reset() catch |err| {
                try stdout.print("Failed to reset daily limitation for group '{s}'\n", .{g_name});
                try stdout.print("Error details: {}\n", .{err});
                continue;
            };

            // Also clear etags and lastModified headers from feeds in this group
            var group = config_manager.loadGroupWithMetadata(g_name) catch |err| {
                try stdout.print("Warning: Failed to load group '{s}' for etag clearing: {}\n", .{ g_name, err });
                try stdout.print("Daily limitation reset for group '{s}'.\n", .{g_name});
                continue;
            };
            defer group.deinit(allocator);

            // Clear etags and lastModified from all feeds
            for (group.feeds) |*feed| {
                if (feed.etag) |etag| {
                    allocator.free(etag);
                    feed.etag = null;
                }
                if (feed.lastModified) |last_mod| {
                    allocator.free(last_mod);
                    feed.lastModified = null;
                }
            }

            // Save the updated group with cleared etags
            config_manager.feed_group_manager.saveGroupWithMetadata(group) catch |err| {
                try stdout.print("Warning: Failed to save cleared etags for group '{s}': {}\n", .{ g_name, err });
            };

            try stdout.print("Daily limitation reset for group '{s}'.\n", .{g_name});
        }
        return;
    }

    var display_manager = try DisplayManager.init(allocator, global_config.display, stdout);
    defer display_manager.deinit();
    defer display_manager.flush() catch {};
    // Handle --sub: Subscribe to a feed URL or import OPML file to the current group
    // Creates the group if it doesn't exist. Applies to primary_group_name only.
    if (hasAnyArg(cli, "--sub", "-s")) {
        if (group_names.len > 1) {
            try stdout.print("Error: --sub can only be used with a single group.\n", .{});
            return;
        }
        const group_name = primary_group_name;

        const input = getAnyArgValue(cli, "--sub", "-s") orelse {
            try stdout.print("Error: Please provide a feed URL or OPML file path: --sub <url|file>\n", .{});
            return;
        };

        // Detect if input is an OPML file or a URL
        const is_url = std.mem.startsWith(u8, input, "http://") or std.mem.startsWith(u8, input, "https://");
        const is_opml = std.mem.endsWith(u8, input, ".opml");

        if (is_opml) {
            // Import OPML file/URL to the current group
            var opml = OpmlManager.init(allocator);
            defer opml.deinit();

            const added_count = opml.importToGroup(input, group_name, &config_manager.feed_group_manager) catch |err| {
                try stdout.print("Error: Failed to import OPML {s} to group '{s}'\n", .{ if (is_url) "URL" else "file", group_name });
                try stdout.print("Error details: {}\n", .{err});
                return;
            };

            try stdout.print("Successfully added {d} feed(s) from OPML to group '{s}'.\n", .{ added_count, group_name });
        } else {
            // It's a feed URL
            // Normalize the feed URL (handle feed:// scheme conversion)
            const normalized_url = RssReader.normalizeFeedUrl(allocator, input) catch |err| {
                std.debug.print("Error: Invalid feed URL\n", .{});
                std.debug.print("Error details: {}\n", .{err});
                return;
            };
            defer allocator.free(normalized_url);

            // Check if there's an optional feed name after the URL
            // Args: ... --sub <url> [optional_name]
            var feed_name: ?[]const u8 = null;

            // Find the --sub or -s flag and check if there's a second argument after it
            for (cli.args, 0..) |arg, i| {
                if ((std.mem.eql(u8, arg, "--sub") or std.mem.eql(u8, arg, "-s")) and i + 2 < cli.args.len) {
                    // Check if the argument after the URL looks like a name (not a flag)
                    const potential_name = cli.args[i + 2];
                    if (!std.mem.startsWith(u8, potential_name, "--") and !std.mem.startsWith(u8, potential_name, "-")) {
                        feed_name = potential_name;
                    }
                }
            }

            var parsed_feed_result: ?types.ParsedFeed = null;
            defer if (parsed_feed_result) |*p| p.deinit();

            try stdout.print("Fetching feed to retrieve metadata...\n", .{});
            if (reader.readFeed(normalized_url)) |p| {
                parsed_feed_result = p;
                // Show the title that will actually be used
                const display_title = if (p.author_name != null and
                    (p.title == null or std.mem.eql(u8, p.title.?, "Videos")))
                    p.author_name.?
                else
                    p.title orelse "Unknown";
                try stdout.print("Detected title: {s}\n", .{display_title});
            } else |err| {
                try stdout.print("Error: Could not fetch feed to get metadata (error: {})\n", .{err});
                try stdout.print("Feed not added.\n", .{});
                return;
            }

            var final_text: ?[]const u8 = feed_name;
            if (final_text == null) {
                if (parsed_feed_result) |*p| {
                    // For YouTube playlist feeds, prefer author name over generic "Videos" title
                    if (p.author_name != null and
                        (p.title == null or std.mem.eql(u8, p.title.?, "Videos")))
                    {
                        final_text = p.author_name;
                    } else {
                        final_text = p.title;
                    }
                }
            }
            // Fallback to URL if still null
            if (final_text == null) {
                final_text = normalized_url;
            }

            const p_ptr = if (parsed_feed_result) |*p| p else null;

            const new_config = types.FeedConfig{
                .xmlUrl = normalized_url,
                .text = final_text,
                .enabled = true,
                .title = if (p_ptr) |p| (p.author_name orelse p.title) else null,
                .description = if (p_ptr) |p| p.description else null,
                .htmlUrl = if (p_ptr) |p| (p.author_uri orelse p.link) else null,
                .language = if (p_ptr) |p| p.language else null,
                .version = if (p_ptr) |p| p.lastBuildDate else null,
            };

            config_manager.addFeedConfigToGroup(group_name, new_config) catch |err| switch (err) {
                error.FeedAlreadyExists => {
                    try stdout.print("Error: Feed already exists in group '{s}'\n", .{group_name});
                    return;
                },
                else => {
                    try stdout.print("Error: Failed to add feed\n", .{});
                    try stdout.print("Error details: {}\n", .{err});
                    return;
                },
            };

            try stdout.print("Feed added successfully to group '{s}'!\n", .{group_name});
        }
        return;
    }

    // Handle --import: Import OPML file to the current group
    if (hasAnyArg(cli, "--import", "-i")) {
        if (group_names.len > 1) {
            try stdout.print("Error: --import can only be used with a single group.\n", .{});
            return;
        }
        const group_name = primary_group_name;

        const file_path = getAnyArgValue(cli, "--import", "-i") orelse {
            try stdout.print("Error: Please provide an OPML file path: --import <file>\n", .{});
            return;
        };

        var opml = OpmlManager.init(allocator);
        defer opml.deinit();

        const added_count = opml.importToGroup(file_path, group_name, &config_manager.feed_group_manager) catch |err| {
            try stdout.print("Error: Failed to import OPML file to group '{s}'\n", .{group_name});
            try stdout.print("Error details: {}\n", .{err});
            return;
        };

        try stdout.print("Successfully added {d} feed(s) from OPML to group '{s}'.\n", .{ added_count, group_name });
        return;
    }

    if (hasAnyArg(cli, "--export", "-e")) {
        const file_path = getAnyArgValue(cli, "--export", "-e") orelse {
            try stdout.print("Error: Please provide a destination path: --export <file>\n", .{});
            return;
        };

        if (group_names.len > 1) {
            try stdout.print("Error: --export can only be used with a single group.\n", .{});
            return;
        }
        const local_group_name = primary_group_name;

        var enabled_feeds = config_manager.getEnabledFeedsFromGroup(local_group_name) catch |err| {
            try stdout.print("Error: Failed to load configuration\n", .{});
            try stdout.print("Error details: {}\n", .{err});
            return;
        };
        defer types.deinitFeedList(allocator, &enabled_feeds);

        if (enabled_feeds.items.len == 0) {
            try stdout.print("Warning: No feeds found in group '{s}' to export.\n", .{local_group_name});
            return;
        }

        // Get group display name to use as OPML title
        const opml_title = config_manager.getGroupDisplayName(local_group_name) catch null;
        defer if (opml_title) |title| allocator.free(title);

        var opml = OpmlManager.init(allocator);
        defer opml.deinit();

        opml.exportToFile(file_path, enabled_feeds, opml_title) catch |err| {
            try stdout.print("Error: Failed to export OPML to '{s}'\n", .{file_path});
            try stdout.print("Error details: {}\n", .{err});
            return;
        };

        try stdout.print("Successfully exported {d} feeds to '{s}'\n", .{ enabled_feeds.items.len, file_path });
        return;
    }

    // Auto-detect OPML file/URL passed directly (e.g., `hys feeds /path/to/file.opml` or `hys feeds https://example.com/feeds.opml`)
    if (cli.getOpmlFilePath()) |source| {
        if (group_names.len > 1) {
            try stdout.print("Error: OPML import can only be used with a single group.\n", .{});
            return;
        }
        const group_name = primary_group_name;

        var opml = OpmlManager.init(allocator);
        defer opml.deinit();

        const added_count = opml.importToGroup(source, group_name, &config_manager.feed_group_manager) catch |err| {
            const source_type = if (std.mem.startsWith(u8, source, "http://") or std.mem.startsWith(u8, source, "https://")) "URL" else "file";
            try stdout.print("Error: Failed to import OPML {s} to group '{s}'\n", .{ source_type, group_name });
            try stdout.print("Error details: {}\n", .{err});
            return;
        };

        try stdout.print("Successfully added {d} feed(s) from OPML to group '{s}'.\n", .{ added_count, group_name });
        return;
    }

    if (hasAnyArg(cli, "--name", "-n")) {
        const display_name = getAnyArgValue(cli, "--name", "-n") orelse {
            try stdout.print("Error: Please provide a display name: --name <name>\n", .{});
            return;
        };

        if (group_names.len > 1) {
            try stdout.print("Error: --name can only be used with a single group.\n", .{});
            return;
        }
        const group_name = primary_group_name;

        config_manager.setGroupDisplayName(group_name, display_name) catch |err| {
            try stdout.print("Error: Failed to set group display name\n", .{});
            try stdout.print("Error details: {}\n", .{err});
            return;
        };

        try stdout.print("Display name for group '{s}' set to '{s}'\n", .{ group_name, display_name });
        return;
    }

    // Load group display name for later use in headers (use primary group for header title)
    // For multiple groups, we might want a combined title or just use the first/generic.
    const group_display_name = config_manager.getGroupDisplayName(primary_group_name) catch null;
    defer if (group_display_name) |display| allocator.free(display);

    if (hasAnyArg(cli, "--day", "-d")) {
        const day_str = getAnyArgValue(cli, "--day", "-d") orelse "0";
        const day_offset = std.fmt.parseInt(i32, day_str, 10) catch 0;

        var all_cached_items = std.array_list.Managed(types.RssItem).init(allocator);
        defer {
            for (all_cached_items.items) |item| item.deinit(allocator);
            all_cached_items.deinit();
        }

        for (group_names) |g_name| {
            var group_limiter = try DailyLimiter.init(allocator, g_name, global_config.history.dayStartHour, global_config.history.fetchIntervalDays);
            defer group_limiter.deinit();

            const state = group_limiter.loadRunByOffset(day_offset) catch |err| {
                // Warn but continue
                try stdout.print("Warning: Failed to load history for group '{s}' (offset {d}): {}\n", .{ g_name, day_offset, err });
                continue;
            };
            defer state.deinit(allocator);

            // Get group display name
            const g_display_name = config_manager.getGroupDisplayName(g_name) catch null;
            defer if (g_display_name) |d| allocator.free(d);

            // Add all cached items from this group with group info
            for (state.items) |item| {
                var item_copy = try item.clone(allocator);
                // Set group info for display
                item_copy.groupName = try allocator.dupe(u8, g_name);
                if (g_display_name) |dn| {
                    item_copy.groupDisplayName = try allocator.dupe(u8, dn);
                }
                try all_cached_items.append(item_copy);
            }
        }

        if (all_cached_items.items.len > 0) {
            if (display_manager.output_buffer) |buf| {
                buf.clearRetainingCapacity();

                // Get current timestamp for the header
                const timestamp = std.time.timestamp();

                var combined_title: []u8 = undefined;
                if (group_names.len == 1) {
                    combined_title = try allocator.dupe(u8, group_display_name orelse primary_group_name);
                } else {
                    var title_builder = std.array_list.Managed(u8).init(allocator);
                    defer title_builder.deinit();

                    for (group_names, 0..) |g_name, i| {
                        if (i > 0) try title_builder.appendSlice(", ");
                        // Try to get display name
                        const dn = config_manager.getGroupDisplayName(g_name) catch null;
                        defer if (dn) |d| allocator.free(d);

                        try title_builder.appendSlice(dn orelse g_name);
                    }
                    combined_title = try title_builder.toOwnedSlice();
                }
                const display_title = combined_title;
                defer allocator.free(display_title);

                display_manager.printHysDigestHeader(display_title, timestamp);

                try display_manager.printCachedItems(all_cached_items.items);
                try display_manager.pipeToLess();
                display_manager.clearBuffer();
            } else {
                try display_manager.printCachedItems(all_cached_items.items);
            }
        } else {
            display_manager.printInfo("No items found.");
        }
        return;
    }

    const cmd_line_feeds = cli.getCmdLineFeeds() catch |err| {
        display_manager.printError("Failed to parse command line feeds");
        std.debug.print("Error details: {}\n", .{err});
        return;
    };
    defer {
        for (cmd_line_feeds) |feed| {
            feed.deinit(allocator);
        }
        allocator.free(cmd_line_feeds);
    }

    // Check if we can show cached results (only if NOT using command line feeds)
    // Store these for use later in the function
    var cached_items_for_mixing = std.array_list.Managed(types.RssItem).init(allocator);
    var has_cached_items = false;

    // Clean up cached items at the end if we have them
    defer if (has_cached_items) {
        for (cached_items_for_mixing.items) |item| item.deinit(allocator);
        cached_items_for_mixing.deinit();
    };

    if (cmd_line_feeds.len == 0) {
        // 1. Separate groups into cached and fresh
        var cached_groups = std.array_list.Managed([]const u8).init(allocator);
        defer cached_groups.deinit();
        var fresh_groups = std.array_list.Managed([]const u8).init(allocator);
        defer fresh_groups.deinit();

        for (group_names) |g_name| {
            var group_limiter = try DailyLimiter.init(allocator, g_name, global_config.history.dayStartHour, global_config.history.fetchIntervalDays);
            defer group_limiter.deinit();

            const within = group_limiter.isWithinFetchInterval() catch false;
            const can_load_cache = within and blk: {
                // Test if cache actually exists and is loadable
                const test_state = group_limiter.loadLatestRun() catch break :blk false;
                test_state.deinit(allocator);
                break :blk true;
            };

            if (can_load_cache) {
                try cached_groups.append(g_name);
            } else {
                try fresh_groups.append(g_name);
            }
        }

        // 2. If ALL groups are cached, show cache and return early
        if (fresh_groups.items.len == 0 and cached_groups.items.len > 0) {
            var cached_aggregation = std.array_list.Managed(types.RssItem).init(allocator);
            defer {
                for (cached_aggregation.items) |item| item.deinit(allocator);
                cached_aggregation.deinit();
            }

            for (cached_groups.items) |g_name| {
                var group_limiter = try DailyLimiter.init(allocator, g_name, global_config.history.dayStartHour, global_config.history.fetchIntervalDays);
                defer group_limiter.deinit();

                const latest_state = group_limiter.loadLatestRun() catch continue;
                defer latest_state.deinit(allocator);

                // Get group display name
                const g_display_name = config_manager.getGroupDisplayName(g_name) catch null;
                defer if (g_display_name) |d| allocator.free(d);

                for (latest_state.items) |item| {
                    var copy = try item.clone(allocator);
                    // Set group info for display
                    copy.groupName = try allocator.dupe(u8, g_name);
                    if (g_display_name) |dn| {
                        copy.groupDisplayName = try allocator.dupe(u8, dn);
                    }
                    try cached_aggregation.append(copy);
                }
            }

            // Display cached items
            if (display_manager.output_buffer) |buf| {
                buf.clearRetainingCapacity();
                const timestamp = std.time.timestamp();

                var combined_title: []u8 = undefined;
                if (group_names.len == 1) {
                    combined_title = try allocator.dupe(u8, group_display_name orelse primary_group_name);
                } else {
                    var title_builder = std.array_list.Managed(u8).init(allocator);
                    defer title_builder.deinit();

                    for (group_names, 0..) |g_name, i| {
                        if (i > 0) try title_builder.appendSlice(", ");
                        const dn = config_manager.getGroupDisplayName(g_name) catch null;
                        defer if (dn) |d| allocator.free(d);
                        try title_builder.appendSlice(dn orelse g_name);
                    }
                    combined_title = try title_builder.toOwnedSlice();
                }
                const display_title = combined_title;
                defer allocator.free(display_title);

                display_manager.printHysDigestHeader(display_title, timestamp);

                if (cached_aggregation.items.len > 0) {
                    try display_manager.printCachedItems(cached_aggregation.items);
                } else {
                    display_manager.printInfo("No cached items found.");
                }
                try display_manager.pipeToLess();
                display_manager.clearBuffer();
            } else {
                if (cached_aggregation.items.len > 0) {
                    try display_manager.printCachedItems(cached_aggregation.items);
                } else {
                    display_manager.printInfo("No cached items found.");
                }
            }
            return;
        }

        // 3. Handle mixed cached/fresh groups properly
        if (cached_groups.items.len > 0) {
            has_cached_items = true;

            // Load cached items
            for (cached_groups.items) |g_name| {
                var group_limiter = try DailyLimiter.init(allocator, g_name, global_config.history.dayStartHour, global_config.history.fetchIntervalDays);
                defer group_limiter.deinit();

                const latest_state = group_limiter.loadLatestRun() catch continue;
                defer latest_state.deinit(allocator);

                // Get group display name
                const g_display_name = config_manager.getGroupDisplayName(g_name) catch null;
                defer if (g_display_name) |d| allocator.free(d);

                for (latest_state.items) |item| {
                    var copy = try item.clone(allocator);
                    // Set group info for display
                    copy.groupName = try allocator.dupe(u8, g_name);
                    if (g_display_name) |dn| {
                        copy.groupDisplayName = try allocator.dupe(u8, dn);
                    }
                    try cached_items_for_mixing.append(copy);
                }
            }

            // If no fresh groups needed, show only cached items
            if (fresh_groups.items.len == 0) {
                defer {
                    for (cached_items_for_mixing.items) |item| item.deinit(allocator);
                    cached_items_for_mixing.deinit();
                }

                // Display cached items and return
                if (display_manager.output_buffer) |buf| {
                    buf.clearRetainingCapacity();
                    const timestamp = std.time.timestamp();

                    var combined_title: []u8 = undefined;
                    if (group_names.len == 1) {
                        combined_title = try allocator.dupe(u8, group_display_name orelse primary_group_name);
                    } else {
                        var title_builder = std.array_list.Managed(u8).init(allocator);
                        defer title_builder.deinit();

                        for (group_names, 0..) |g_name, i| {
                            if (i > 0) try title_builder.appendSlice(", ");
                            const dn = config_manager.getGroupDisplayName(g_name) catch null;
                            defer if (dn) |d| allocator.free(d);
                            try title_builder.appendSlice(dn orelse g_name);
                        }
                        combined_title = try title_builder.toOwnedSlice();
                    }
                    const display_title = combined_title;
                    defer allocator.free(display_title);

                    display_manager.printHysDigestHeader(display_title, timestamp);

                    if (cached_items_for_mixing.items.len > 0) {
                        try display_manager.printCachedItems(cached_items_for_mixing.items);
                    } else {
                        display_manager.printInfo("No cached items found.");
                    }
                    try display_manager.pipeToLess();
                    display_manager.clearBuffer();
                } else {
                    if (cached_items_for_mixing.items.len > 0) {
                        try display_manager.printCachedItems(cached_items_for_mixing.items);
                    } else {
                        display_manager.printInfo("No cached items found.");
                    }
                }
                return;
            }
        }
    }

    var aggregated_feeds = std.array_list.Managed(types.FeedConfig).init(allocator);
    defer {
        for (aggregated_feeds.items) |f| f.deinit(allocator);
        aggregated_feeds.deinit();
    }

    var feed_group_names = std.array_list.Managed([]const u8).init(allocator);
    defer feed_group_names.deinit();

    var feed_group_display_names = std.array_list.Managed(?[]const u8).init(allocator);
    defer {
        for (feed_group_display_names.items) |name| {
            if (name) |n| allocator.free(n);
        }
        feed_group_display_names.deinit();
    }

    var has_valid_feeds = false;

    if (cmd_line_feeds.len > 0) {
        // Just use cmd line feeds
        for (cmd_line_feeds) |feed| {
            const copy = try feed.clone(allocator);
            try aggregated_feeds.append(copy);
            try feed_group_names.append("main");
            try feed_group_display_names.append(null);
        }
        has_valid_feeds = true;
    } else {
        // Iterate groups and collect feeds
        for (group_names) |g_name| {
            // If we have cached items, only process groups that need fresh fetching
            if (has_cached_items) {
                // Check if this group is in the fresh_groups list
                var is_fresh_group = false;
                if (cmd_line_feeds.len == 0) {
                    // We need to recreate the fresh groups logic here
                    var group_limiter = try DailyLimiter.init(allocator, g_name, global_config.history.dayStartHour, global_config.history.fetchIntervalDays);
                    defer group_limiter.deinit();

                    const within = group_limiter.isWithinFetchInterval() catch false;
                    const can_load_cache = within and blk: {
                        const test_state = group_limiter.loadLatestRun() catch break :blk false;
                        test_state.deinit(allocator);
                        break :blk true;
                    };

                    is_fresh_group = !can_load_cache;
                }

                // Skip cached groups since we already loaded their items
                if (!is_fresh_group) {
                    continue;
                }
            }

            if (!config_manager.groupExists(g_name) and !std.mem.eql(u8, g_name, "main")) {
                const msg = try std.fmt.allocPrint(allocator, "Group '{s}' does not exist. Use --sub to create it.", .{g_name});
                defer allocator.free(msg);
                display_manager.printWarning(msg);
                continue;
            }

            var feeds = config_manager.getEnabledFeedsFromGroup(g_name) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to get feeds from group '{s}'", .{g_name});
                defer allocator.free(msg);
                display_manager.printError(msg);
                std.debug.print("Error details: {}\n", .{err});
                continue;
            };
            defer types.deinitFeedList(allocator, &feeds); // We clone them out

            if (feeds.items.len == 0) {
                // Just warn
                // Only verify main group content if it's the only one
                if (group_names.len == 1) {
                    const msg = try std.fmt.allocPrint(allocator, "No feeds in group '{s}'. Use --sub to add feeds.", .{g_name});
                    defer allocator.free(msg);
                    display_manager.printError(msg);
                    return;
                }
                continue;
            }

            // Get group display name once
            const g_display_name = config_manager.getGroupDisplayName(g_name) catch null;
            defer if (g_display_name) |d| allocator.free(d);

            // Clone feeds (no group info stored in FeedConfig)
            for (feeds.items) |feed| {
                const copy = try feed.clone(allocator);
                try aggregated_feeds.append(copy);
                try feed_group_names.append(g_name);
                var display_name_copy: ?[]const u8 = null;
                if (g_display_name) |dn| {
                    display_name_copy = try allocator.dupe(u8, dn);
                }
                try feed_group_display_names.append(display_name_copy);
            }
            has_valid_feeds = true;
        }
    }

    if (!has_valid_feeds and cmd_line_feeds.len == 0) {
        return;
    }

    const feeds_to_read = aggregated_feeds.items;

    // 1. Create an atomic flag to control the animation loop
    var is_loading = std.atomic.Value(bool).init(true);

    // 2. Spawn a background thread to handle the visual animation
    const anim_thread = try std.Thread.spawn(.{}, runLoadingAnimation, .{ &is_loading, feeds_to_read.len, stdout });

    var seen_articles = limiter.loadSeenHashes() catch |err| blk: {
        display_manager.printError("Failed to load seen articles hash file");
        try stdout.print("Error details: {}\n", .{err});
        break :blk std.AutoHashMap(u64, void).init(allocator);
    };
    defer seen_articles.deinit();

    var new_hashes = std.array_list.Managed(u64).init(allocator);
    defer new_hashes.deinit();

    var failed_feeds = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (failed_feeds.items) |name| {
            allocator.free(name);
        }
        failed_feeds.deinit();
    }

    var feed_processor = FeedProcessor.init(allocator, global_config.network.maxFeedSizeMB);

    // 3. Perform the blocking fetch on the main thread
    const results = try feed_processor.fetchFeeds(feeds_to_read, if (cmd_line_feeds.len > 0) null else &seen_articles);

    // 4. Signal the animation thread to stop and wait for it to join
    is_loading.store(false, .release);
    anim_thread.join();

    // Clear the loading animation line completely
    try stdout.print("\r                                                                                \r", .{});
    try stdout.flush();

    defer {
        // processResults takes ownership of feed_config and parsed, so they are cleaned up
        // inside processResults. Here we only free the results array itself.
        allocator.free(results);
    }

    // Determine if we should preserve command-line group order
    // Preserve order when groups were explicitly specified (not --all) and there are multiple groups
    const preserve_order = !cli.hasArg("--all") and group_names.len > 1;

    // Process results - takes ownership of feed_config and parsed from results
    var all_items = try feed_processor.processResults(
        results,
        feeds_to_read,
        feed_group_names.items,
        feed_group_display_names.items,
        &display_manager,
        &seen_articles,
        &new_hashes,
        &failed_feeds,
        cmd_line_feeds.len > 0,
        preserve_order,
    );
    defer {
        for (all_items.items) |item| {
            item.deinit(allocator);
        }
        all_items.deinit();
    }

    // If we have cached items to mix in, combine them with fresh items
    if (cmd_line_feeds.len == 0 and has_cached_items) {
        // Move cached items into all_items
        for (cached_items_for_mixing.items) |cached_item| {
            try all_items.append(cached_item);
        }

        // Clear the cached list without deiniting items (they're now in all_items)
        cached_items_for_mixing.items.len = 0;

        // Re-sort the combined list to maintain proper ordering
        if (preserve_order) {
            // Get unique group names from the items to preserve command-line order
            var unique_groups = std.array_list.Managed([]const u8).init(allocator);
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

            const GroupOrderContext = @import("feed_processor").GroupOrderContext;
            const compareRssItemsWithGroupOrder = @import("feed_processor").compareRssItemsWithGroupOrder;
            const ctx = GroupOrderContext{ .group_names = unique_groups.items };
            std.mem.sort(types.RssItem, all_items.items, ctx, compareRssItemsWithGroupOrder);
        } else {
            const compareRssItems = @import("feed_processor").compareRssItems;
            std.mem.sort(types.RssItem, all_items.items, {}, compareRssItems);
        }
    }

    // Save updated feed configurations with new ETags/Last-Modified headers
    // Only do this for persistent groups (not command-line feeds)
    if (cmd_line_feeds.len == 0) {
        for (group_names) |g_name| {
            // Filter feeds for this group
            var group_feeds = std.array_list.Managed(types.FeedConfig).init(allocator);
            defer group_feeds.deinit();

            for (feeds_to_read, 0..) |feed, idx| {
                if (std.mem.eql(u8, feed_group_names.items[idx], g_name)) {
                    try group_feeds.append(feed);
                }
            }

            // Get display name for saving
            const d_name = config_manager.getGroupDisplayName(g_name) catch null;
            defer if (d_name) |d| allocator.free(d);

            // Create updated feed group with modified feed configurations
            const updated_group = types.FeedGroup{
                .name = try allocator.dupe(u8, g_name),
                .display_name = if (d_name) |d| try allocator.dupe(u8, d) else null,
                .feeds = group_feeds.items, // These now contain updated ETags/Last-Modified
            };
            // Manually free only what we allocated for the wrapper struct
            defer {
                allocator.free(updated_group.name);
                if (updated_group.display_name) |d| allocator.free(d);
            }

            // Save the updated group configuration
            config_manager.feed_group_manager.saveGroupWithMetadata(updated_group) catch {
                const msg = try std.fmt.allocPrint(allocator, "Failed to save updated configuration for group '{s}'", .{g_name});
                defer allocator.free(msg);
                display_manager.printError(msg);
            };

            // Filter items for history
            var group_items = std.array_list.Managed(types.RssItem).init(allocator);
            defer group_items.deinit();

            for (all_items.items) |item| {
                if (std.mem.eql(u8, item.groupName orelse "", g_name)) {
                    try group_items.append(item);
                }
            }

            // Save Day History per group
            var group_limiter = try DailyLimiter.init(allocator, g_name, global_config.history.dayStartHour, global_config.history.fetchIntervalDays);
            defer group_limiter.deinit();

            // Only save if there are items, or if the day's file doesn't exist yet (new day)
            const should_save = group_items.items.len > 0 or blk: {
                // Duplicate date formatting logic from DailyLimiter
                var local_tz = zdt.Timezone.tzLocal(allocator) catch break :blk true;
                defer local_tz.deinit();
                var now = zdt.Datetime.now(.{ .tz = &local_tz }) catch break :blk true;
                if (global_config.history.dayStartHour > 0) {
                    const hour_offset: i64 = -@as(i64, @intCast(global_config.history.dayStartHour));
                    const duration = zdt.Duration.fromTimespanMultiple(hour_offset, .hour);
                    now = now.add(duration) catch break :blk true;
                }
                var date_buf: [32]u8 = undefined;
                const date_str = std.fmt.bufPrint(&date_buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
                    @abs(now.year),
                    @as(u5, @intCast(now.month)),
                    @as(u5, @intCast(now.day)),
                }) catch break :blk true;
                var filename_buf: [256]u8 = undefined;
                const filename_only = std.fmt.bufPrint(&filename_buf, "{s}_{s}.json", .{ g_name, date_str }) catch break :blk true;
                const filename = std.fs.path.join(allocator, &.{ group_limiter.state_dir, filename_only }) catch break :blk true;
                defer allocator.free(filename);
                // If file doesn't exist, save even if empty (new day)
                std.fs.cwd().access(filename, .{}) catch break :blk true;
                // File exists, don't overwrite with empty
                break :blk false;
            };

            if (should_save) {
                group_limiter.saveDay(group_items.items) catch {
                    const msg = try std.fmt.allocPrint(allocator, "Failed to save history for group '{s}'", .{g_name});
                    defer allocator.free(msg);
                    display_manager.printError(msg);
                };
            }

            group_limiter.pruneHistory(global_config.history.retentionDays) catch {
                // Silently fail on pruning
            };
        }

        // Global operations (using primary limiter is fine)
        limiter.saveNewHashes(new_hashes.items) catch {
            display_manager.printError("Failed to save new hashes to persistent storage");
        };

        limiter.pruneSeen(global_config.history.retentionDays) catch {
            display_manager.printError("Failed to prune old hashes from deduplication storage");
        };
    }

    // If using streaming pager mode, output is written directly as items are processed
    if (display_manager.use_pager_streaming) {
        if (all_items.items.len == 0) {
            display_manager.printInfo("No new items found.");
        }

        if (failed_feeds.items.len > 0) {
            var error_msg = std.array_list.Managed(u8).init(allocator);
            defer error_msg.deinit();

            try error_msg.appendSlice("RSS feeds read with ");
            const count_str = try std.fmt.allocPrint(allocator, "{d}", .{failed_feeds.items.len});
            defer allocator.free(count_str);
            try error_msg.appendSlice(count_str);
            try error_msg.appendSlice(" failure(s): ");

            for (failed_feeds.items, 0..) |name, i| {
                if (i > 0) try error_msg.appendSlice(", ");
                try error_msg.appendSlice(name);
            }

            display_manager.printError(error_msg.items);
        }
        // Pager will close and display naturally when deinit is called
    } else if (display_manager.output_buffer == null) {
        // Non-pager mode: output directly to stdout
        if (failed_feeds.items.len > 0) {
            var error_msg = std.array_list.Managed(u8).init(allocator);
            defer error_msg.deinit();

            try error_msg.appendSlice("RSS feeds read with ");
            const count_str = try std.fmt.allocPrint(allocator, "{d}", .{failed_feeds.items.len});
            defer allocator.free(count_str);
            try error_msg.appendSlice(count_str);
            try error_msg.appendSlice(" failure(s): ");

            for (failed_feeds.items, 0..) |name, i| {
                if (i > 0) try error_msg.appendSlice(", ");
                try error_msg.appendSlice(name);
            }

            display_manager.printError(error_msg.items);
        } else {
            display_manager.printSuccess("RSS feeds read successfully!");
        }
        try display_manager.flush();
    } else {
        // Buffered fallback mode (if pager failed to spawn)
        if (display_manager.output_buffer) |buf| {
            buf.clearRetainingCapacity();

            // Only print header if not in preview mode (cmd_line_feeds.len == 0 means no preview)
            if (cmd_line_feeds.len == 0) {
                // Get current timestamp for the header
                const timestamp = std.time.timestamp();

                var combined_title: []u8 = undefined;
                if (group_names.len == 1) {
                    combined_title = try allocator.dupe(u8, group_display_name orelse primary_group_name);
                } else {
                    var title_builder = std.array_list.Managed(u8).init(allocator);
                    defer title_builder.deinit();

                    for (group_names, 0..) |g_name, i| {
                        if (i > 0) try title_builder.appendSlice(", ");
                        const dn = config_manager.getGroupDisplayName(g_name) catch null;
                        defer if (dn) |d| allocator.free(d);
                        try title_builder.appendSlice(dn orelse g_name);
                    }
                    combined_title = try title_builder.toOwnedSlice();
                }
                const display_title = combined_title;
                defer allocator.free(display_title);

                display_manager.printHysDigestHeader(display_title, timestamp);
            }

            if (all_items.items.len == 0) {
                display_manager.printInfo("No new items found.");
            } else {
                display_manager.renderFeedsToBuffer(all_items.items) catch {
                    display_manager.printError("Failed to render feeds to buffer");
                    return;
                };
            }

            if (failed_feeds.items.len > 0) {
                var error_msg = std.array_list.Managed(u8).init(allocator);
                defer error_msg.deinit();

                try error_msg.appendSlice("RSS feeds read with ");
                const count_str = try std.fmt.allocPrint(allocator, "{d}", .{failed_feeds.items.len});
                defer allocator.free(count_str);
                try error_msg.appendSlice(count_str);
                try error_msg.appendSlice(" failure(s): ");

                for (failed_feeds.items, 0..) |name, i| {
                    if (i > 0) try error_msg.appendSlice(", ");
                    try error_msg.appendSlice(name);
                }

                display_manager.printError(error_msg.items);
            }

            try display_manager.pipeToLess();
            display_manager.clearBuffer();
        }
    }

    try stdout.flush();
}
