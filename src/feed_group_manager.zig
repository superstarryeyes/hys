const std = @import("std");
const types = @import("types");
const rss_reader = @import("rss_reader");

/// FeedGroupManager handles loading, saving, and managing feed groups.
/// OWNERSHIP REQUIREMENT: feeds_dir must be owned by the allocator.
pub const FeedGroupManager = struct {
    allocator: std.mem.Allocator,
    feeds_dir: []u8,

    pub fn init(allocator: std.mem.Allocator, base_dir: []const u8) !FeedGroupManager {
        const feeds_dir = try std.fs.path.join(allocator, &.{ base_dir, "feeds" });

        var manager = FeedGroupManager{
            .allocator = allocator,
            .feeds_dir = feeds_dir,
        };

        try manager.ensureFeedsDir();
        return manager;
    }

    pub fn deinit(self: FeedGroupManager) void {
        self.allocator.free(self.feeds_dir);
    }

    fn ensureFeedsDir(self: FeedGroupManager) !void {
        std.fs.cwd().makePath(self.feeds_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    /// Load a complete feed group with metadata
    pub fn loadGroupWithMetadata(self: FeedGroupManager, group_name: []const u8) !types.FeedGroup {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.json", .{group_name});
        defer self.allocator.free(filename);

        const file_path = try std.fs.path.join(self.allocator, &.{ self.feeds_dir, filename });
        defer self.allocator.free(file_path);

        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // Return empty group for non-existent groups
                return types.FeedGroup{
                    .name = try self.allocator.dupe(u8, group_name),
                    .display_name = null,
                    .feeds = &.{},
                };
            },
            else => return err,
        };
        defer file.close();

        const file_size = try file.getEndPos();
        const contents = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(contents);
        _ = try file.readAll(contents);

        return self.parseGroupWithMetadata(group_name, contents);
    }

    /// Update the display name of a group
    pub fn setGroupDisplayName(self: FeedGroupManager, group_name: []const u8, display_name: ?[]const u8) !void {
        var group = try self.loadGroupWithMetadata(group_name);
        defer group.deinit(self.allocator);

        // Update display name
        if (group.display_name) |old_name| {
            self.allocator.free(old_name);
        }
        group.display_name = if (display_name) |name| try self.allocator.dupe(u8, name) else null;

        try self.saveGroupWithMetadata(group);
    }

    /// Get the display name of a group
    pub fn getGroupDisplayName(self: FeedGroupManager, group_name: []const u8) !?[]const u8 {
        const group = try self.loadGroupWithMetadata(group_name);
        defer group.deinit(self.allocator);

        return if (group.display_name) |name| try self.allocator.dupe(u8, name) else null;
    }

    /// Save a complete feed group with metadata
    pub fn saveGroupWithMetadata(self: FeedGroupManager, group: types.FeedGroup) !void {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.json", .{group.name});
        defer self.allocator.free(filename);

        const file_path = try std.fs.path.join(self.allocator, &.{ self.feeds_dir, filename });
        defer self.allocator.free(file_path);

        // Create group data structure for JSON serialization
        // Use 'text' for display name to match FeedConfig convention
        const GroupData = struct {
            text: ?[]const u8,
            feeds: []const types.FeedConfig,
        };

        const group_data = GroupData{
            .text = group.display_name,
            .feeds = group.feeds,
        };

        const json_string = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(group_data, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        })});
        defer self.allocator.free(json_string);

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(json_string);
    }

    /// Check if a group exists
    pub fn groupExists(self: FeedGroupManager, group_name: []const u8) bool {
        const filename = std.fmt.allocPrint(self.allocator, "{s}.json", .{group_name}) catch return false;
        defer self.allocator.free(filename);

        const file_path = std.fs.path.join(self.allocator, &.{ self.feeds_dir, filename }) catch return false;
        defer self.allocator.free(file_path);

        std.fs.cwd().access(file_path, .{}) catch return false;
        return true;
    }

    /// Add a feed to a specific group
    pub fn addFeedToGroup(self: FeedGroupManager, group_name: []const u8, url: []const u8, name: ?[]const u8) !void {
        // Validate URL before processing
        try rss_reader.validateFeedUrl(url);

        var group = try self.loadGroupWithMetadata(group_name);
        defer group.deinit(self.allocator);

        // Check if feed already exists
        for (group.feeds) |feed| {
            if (std.mem.eql(u8, feed.xmlUrl, url)) {
                return error.FeedAlreadyExists;
            }
        }

        // Sanitize URL and text before storage
        const sanitized_url = try rss_reader.RssReader.sanitizeFeedData(url, self.allocator);
        errdefer self.allocator.free(sanitized_url);

        var sanitized_name: ?[]const u8 = null;
        if (name) |n| {
            const san = try rss_reader.RssReader.sanitizeFeedData(n, self.allocator);
            errdefer self.allocator.free(san);
            sanitized_name = san;
        }

        // Create a new feeds slice with the additional feed
        var feeds_list = try types.cloneFeedListFromSlice(self.allocator, group.feeds);
        defer types.deinitFeedList(self.allocator, &feeds_list);

        try feeds_list.append(self.allocator, types.FeedConfig{
            .xmlUrl = sanitized_url,
            .text = sanitized_name,
            .enabled = true,
        });

        // Create updated group and save
        const updated_group = types.FeedGroup{
            .name = group.name,
            .display_name = group.display_name,
            .feeds = feeds_list.items,
        };

        try self.saveGroupWithMetadata(updated_group);
    }

    /// Add a feed config (with all metadata) to a specific group
    pub fn addFeedConfigToGroup(self: FeedGroupManager, group_name: []const u8, feed_config: types.FeedConfig) !void {
        // Validate URL before processing
        try rss_reader.validateFeedUrl(feed_config.xmlUrl);

        var group = try self.loadGroupWithMetadata(group_name);
        defer group.deinit(self.allocator);

        // Check if feed already exists
        for (group.feeds) |feed| {
            if (std.mem.eql(u8, feed.xmlUrl, feed_config.xmlUrl)) {
                return error.FeedAlreadyExists;
            }
        }

        // Create a new feeds slice with the additional feed
        var feeds_list = try types.cloneFeedListFromSlice(self.allocator, group.feeds);
        defer types.deinitFeedList(self.allocator, &feeds_list);

        // Clone the feed config to persist all metadata
        const xmlUrl = try self.allocator.dupe(u8, feed_config.xmlUrl);
        errdefer self.allocator.free(xmlUrl);

        const text = if (feed_config.text) |t| try self.allocator.dupe(u8, t) else null;
        errdefer if (text) |t| self.allocator.free(t);

        const title = if (feed_config.title) |t| try self.allocator.dupe(u8, t) else null;
        errdefer if (title) |t| self.allocator.free(t);

        const htmlUrl = if (feed_config.htmlUrl) |h| try self.allocator.dupe(u8, h) else null;
        errdefer if (htmlUrl) |h| self.allocator.free(h);

        const description = if (feed_config.description) |d| try self.allocator.dupe(u8, d) else null;
        errdefer if (description) |d| self.allocator.free(d);

        const language = if (feed_config.language) |l| try self.allocator.dupe(u8, l) else null;
        errdefer if (language) |l| self.allocator.free(l);

        const version = if (feed_config.version) |v| try self.allocator.dupe(u8, v) else null;
        errdefer if (version) |v| self.allocator.free(v);

        const etag = if (feed_config.etag) |e| try self.allocator.dupe(u8, e) else null;
        errdefer if (etag) |e| self.allocator.free(e);

        const lastModified = if (feed_config.lastModified) |lm| try self.allocator.dupe(u8, lm) else null;
        errdefer if (lastModified) |lm| self.allocator.free(lm);

        try feeds_list.append(self.allocator, types.FeedConfig{
            .xmlUrl = xmlUrl,
            .text = text,
            .enabled = feed_config.enabled,
            .title = title,
            .htmlUrl = htmlUrl,
            .description = description,
            .language = language,
            .version = version,
            .etag = etag,
            .lastModified = lastModified,
        });

        // Create updated group and save
        const updated_group = types.FeedGroup{
            .name = group.name,
            .display_name = group.display_name,
            .feeds = feeds_list.items,
        };

        try self.saveGroupWithMetadata(updated_group);
    }

    /// Get enabled feeds from a specific group
    pub fn getEnabledFeeds(self: FeedGroupManager, group_name: []const u8) !types.FeedList {
        var group = try self.loadGroupWithMetadata(group_name);
        defer group.deinit(self.allocator);

        return try types.filterEnabledFeeds(self.allocator, types.FeedList{
            .items = group.feeds,
            .capacity = group.feeds.len,
        });
    }

    /// Get a list of all available group names by scanning the feeds directory
    pub fn getAllGroupNames(self: FeedGroupManager) ![]const []const u8 {
        var dir = std.fs.cwd().openDir(self.feeds_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return &[_][]const u8{},
            else => return err,
        };
        defer dir.close();

        var groups = std.array_list.Managed([]const u8).init(self.allocator);
        errdefer {
            for (groups.items) |name| self.allocator.free(name);
            groups.deinit();
        }

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                // Skip hidden files
                if (std.mem.startsWith(u8, entry.name, ".")) continue;

                // Strip .json extension
                const name_len = entry.name.len - 5; // ".json".len
                const group_name = try self.allocator.dupe(u8, entry.name[0..name_len]);
                try groups.append(group_name);
            }
        }

        // Sort alphabetically for consistent output
        std.mem.sort([]const u8, groups.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);

        return groups.toOwnedSlice();
    }

    fn parseGroupWithMetadata(self: FeedGroupManager, group_name: []const u8, contents: []const u8) !types.FeedGroup {
        // Parse the group data format with metadata
        const GroupData = struct {
            text: ?[]const u8 = null,
            feeds: []const struct {
                xmlUrl: []const u8,
                text: ?[]const u8 = null,
                enabled: bool = true,
                title: ?[]const u8 = null,
                htmlUrl: ?[]const u8 = null,
                description: ?[]const u8 = null,
                language: ?[]const u8 = null,
                version: ?[]const u8 = null,
                etag: ?[]const u8 = null,
                lastModified: ?[]const u8 = null,
            },
        };

        // Use arena allocator to avoid parse-then-copy overhead
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const parsed = std.json.parseFromSliceLeaky(GroupData, arena.allocator(), contents, .{
            .ignore_unknown_fields = true,
        }) catch {
            // Try parsing as legacy array format
            return self.parseLegacyFeedArray(group_name, contents, arena.allocator());
        };

        // Convert feeds
        var feeds = try self.allocator.alloc(types.FeedConfig, parsed.feeds.len);
        errdefer self.allocator.free(feeds);

        for (parsed.feeds, 0..) |raw_feed, i| {
            const xmlUrl = try self.allocator.dupe(u8, raw_feed.xmlUrl);
            errdefer self.allocator.free(xmlUrl);
            const text = if (raw_feed.text) |t| try self.allocator.dupe(u8, t) else null;
            errdefer if (text) |t| self.allocator.free(t);

            const title = if (raw_feed.title) |t| try self.allocator.dupe(u8, t) else null;
            errdefer if (title) |t| self.allocator.free(t);

            const htmlUrl = if (raw_feed.htmlUrl) |h| try self.allocator.dupe(u8, h) else null;
            errdefer if (htmlUrl) |h| self.allocator.free(h);

            const description = if (raw_feed.description) |d| try self.allocator.dupe(u8, d) else null;
            errdefer if (description) |d| self.allocator.free(d);

            const language = if (raw_feed.language) |l| try self.allocator.dupe(u8, l) else null;
            errdefer if (language) |l| self.allocator.free(l);

            const version = if (raw_feed.version) |v| try self.allocator.dupe(u8, v) else null;
            errdefer if (version) |v| self.allocator.free(v);

            const etag = if (raw_feed.etag) |e| try self.allocator.dupe(u8, e) else null;
            errdefer if (etag) |e| self.allocator.free(e);

            const lastModified = if (raw_feed.lastModified) |lm| try self.allocator.dupe(u8, lm) else null;
            errdefer if (lastModified) |lm| self.allocator.free(lm);

            feeds[i] = types.FeedConfig{
                .xmlUrl = xmlUrl,
                .text = text,
                .enabled = raw_feed.enabled,
                .title = title,
                .htmlUrl = htmlUrl,
                .description = description,
                .language = language,
                .version = version,
                .etag = etag,
                .lastModified = lastModified,
            };
        }

        return types.FeedGroup{
            .name = try self.allocator.dupe(u8, group_name),
            .display_name = if (parsed.text) |t| try self.allocator.dupe(u8, t) else null,
            .feeds = feeds,
        };
    }

    /// Parse legacy array format [{ xmlUrl, text, ... }] and convert to FeedGroup
    fn parseLegacyFeedArray(self: FeedGroupManager, group_name: []const u8, contents: []const u8, arena_allocator: std.mem.Allocator) !types.FeedGroup {
        const RawFeedConfig = struct {
            xmlUrl: []const u8,
            text: ?[]const u8 = null,
            enabled: bool = true,
            title: ?[]const u8 = null,
            htmlUrl: ?[]const u8 = null,
            description: ?[]const u8 = null,
            language: ?[]const u8 = null,
            version: ?[]const u8 = null,
            etag: ?[]const u8 = null,
            lastModified: ?[]const u8 = null,
        };

        const parsed = std.json.parseFromSliceLeaky([]RawFeedConfig, arena_allocator, contents, .{
            .ignore_unknown_fields = true,
        }) catch {
            return error.ParseFailed;
        };

        // Convert to FeedGroup format
        var feeds = try self.allocator.alloc(types.FeedConfig, parsed.len);
        errdefer self.allocator.free(feeds);

        for (parsed, 0..) |raw_feed, i| {
            const xmlUrl = try self.allocator.dupe(u8, raw_feed.xmlUrl);
            errdefer self.allocator.free(xmlUrl);

            const text = if (raw_feed.text) |t| try self.allocator.dupe(u8, t) else null;
            errdefer if (text) |t| self.allocator.free(t);

            const title = if (raw_feed.title) |t| try self.allocator.dupe(u8, t) else null;
            errdefer if (title) |t| self.allocator.free(t);

            const htmlUrl = if (raw_feed.htmlUrl) |h| try self.allocator.dupe(u8, h) else null;
            errdefer if (htmlUrl) |h| self.allocator.free(h);

            const description = if (raw_feed.description) |d| try self.allocator.dupe(u8, d) else null;
            errdefer if (description) |d| self.allocator.free(d);

            const language = if (raw_feed.language) |l| try self.allocator.dupe(u8, l) else null;
            errdefer if (language) |l| self.allocator.free(l);

            const version = if (raw_feed.version) |v| try self.allocator.dupe(u8, v) else null;
            errdefer if (version) |v| self.allocator.free(v);

            const etag = if (raw_feed.etag) |e| try self.allocator.dupe(u8, e) else null;
            errdefer if (etag) |e| self.allocator.free(e);

            const lastModified = if (raw_feed.lastModified) |lm| try self.allocator.dupe(u8, lm) else null;
            errdefer if (lastModified) |lm| self.allocator.free(lm);

            feeds[i] = types.FeedConfig{
                .xmlUrl = xmlUrl,
                .text = text,
                .enabled = raw_feed.enabled,
                .title = title,
                .htmlUrl = htmlUrl,
                .description = description,
                .language = language,
                .version = version,
                .etag = etag,
                .lastModified = lastModified,
            };
        }

        return types.FeedGroup{
            .name = try self.allocator.dupe(u8, group_name),
            .display_name = null,
            .feeds = feeds,
        };
    }
};
