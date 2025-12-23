const std = @import("std");

/// FeedConfig represents a feed configuration.
/// OWNERSHIP REQUIREMENT: Both `xmlUrl` and `text` must be owned by the given allocator.
/// They must have been allocated with allocator.dupe() or allocator.alloc().
/// DO NOT store static strings or strings from other allocators in these fields.
/// Additional fields store optional metadata from OPML import.
pub const FeedConfig = struct {
    xmlUrl: []const u8,
    text: ?[]const u8 = null,
    enabled: bool = true,
    title: ?[]const u8 = null, // OPML title attribute
    htmlUrl: ?[]const u8 = null, // OPML htmlUrl attribute
    description: ?[]const u8 = null, // OPML description attribute
    type: ?[]const u8 = null, // OPML type attribute
    language: ?[]const u8 = null, // OPML language attribute
    version: ?[]const u8 = null, // OPML version attribute

    // Conditional GET headers for caching
    etag: ?[]const u8 = null, // ETag from last successful response
    lastModified: ?[]const u8 = null, // Last-Modified from last successful response

    pub fn deinit(self: FeedConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.xmlUrl);
        if (self.text) |text| allocator.free(text);
        if (self.title) |title| allocator.free(title);
        if (self.htmlUrl) |html_url| allocator.free(html_url);
        if (self.description) |desc| allocator.free(desc);
        if (self.type) |t| allocator.free(t);
        if (self.language) |lang| allocator.free(lang);
        if (self.version) |ver| allocator.free(ver);
        if (self.etag) |etag| allocator.free(etag);
        if (self.lastModified) |lastMod| allocator.free(lastMod);
    }

    /// Clone a FeedConfig, duplicating all owned strings
    pub fn clone(self: FeedConfig, allocator: std.mem.Allocator) !FeedConfig {
        const xmlUrl = try allocator.dupe(u8, self.xmlUrl);
        errdefer allocator.free(xmlUrl);

        const text = if (self.text) |t| try allocator.dupe(u8, t) else null;
        errdefer if (text) |t| allocator.free(t);

        const title = if (self.title) |t| try allocator.dupe(u8, t) else null;
        errdefer if (title) |t| allocator.free(t);

        const htmlUrl = if (self.htmlUrl) |h| try allocator.dupe(u8, h) else null;
        errdefer if (htmlUrl) |h| allocator.free(h);

        const description = if (self.description) |d| try allocator.dupe(u8, d) else null;
        errdefer if (description) |d| allocator.free(d);

        const type_str = if (self.type) |t| try allocator.dupe(u8, t) else null;
        errdefer if (type_str) |t| allocator.free(t);

        const language = if (self.language) |l| try allocator.dupe(u8, l) else null;
        errdefer if (language) |l| allocator.free(l);

        const version = if (self.version) |v| try allocator.dupe(u8, v) else null;
        errdefer if (version) |v| allocator.free(v);

        const etag = if (self.etag) |e| try allocator.dupe(u8, e) else null;
        errdefer if (etag) |e| allocator.free(e);

        const lastModified = if (self.lastModified) |lm| try allocator.dupe(u8, lm) else null;
        errdefer if (lastModified) |lm| allocator.free(lm);

        return FeedConfig{
            .xmlUrl = xmlUrl,
            .text = text,
            .enabled = self.enabled,
            .title = title,
            .htmlUrl = htmlUrl,
            .description = description,
            .type = type_str,
            .language = language,
            .version = version,
            .etag = etag,
            .lastModified = lastModified,
        };
    }
};

/// FeedList is an alias for ArrayListUnmanaged(FeedConfig)
/// This provides a standard growable list for feed configurations
pub const FeedList = std.ArrayListUnmanaged(FeedConfig);

/// Helper function to clone a FeedList
pub fn cloneFeedList(allocator: std.mem.Allocator, source: FeedList) !FeedList {
    return cloneFeedListFromSlice(allocator, source.items);
}

/// Helper function to clone a FeedList from a slice
pub fn cloneFeedListFromSlice(allocator: std.mem.Allocator, items: []const FeedConfig) !FeedList {
    var list = FeedList{};
    try list.ensureTotalCapacity(allocator, items.len);

    var cloned_count: usize = 0;
    errdefer {
        for (list.items[0..cloned_count]) |feed| {
            feed.deinit(allocator);
        }
        list.deinit(allocator);
    }

    for (items) |feed| {
        const cloned_feed = try feed.clone(allocator);
        list.appendAssumeCapacity(cloned_feed);
        cloned_count += 1;
    }

    // ASSERTION: Ownership transfer is complete.
    // No fallible operations are allowed past this point.
    // This compile-time assertion prevents double-frees if error handling is added later.
    errdefer comptime unreachable;

    return list;
}

/// Helper function to filter enabled feeds
pub fn filterEnabledFeeds(allocator: std.mem.Allocator, source: FeedList) !FeedList {
    // Count enabled feeds first
    var enabled_count: usize = 0;
    for (source.items) |feed| {
        if (feed.enabled) {
            enabled_count += 1;
        }
    }

    var list = FeedList{};
    try list.ensureTotalCapacity(allocator, enabled_count);

    var cloned_count: usize = 0;
    errdefer {
        for (list.items[0..cloned_count]) |feed| {
            feed.deinit(allocator);
        }
        list.deinit(allocator);
    }

    for (source.items) |feed| {
        if (feed.enabled) {
            const cloned_feed = try feed.clone(allocator);
            list.appendAssumeCapacity(cloned_feed);
            cloned_count += 1;
        }
    }

    // ASSERTION: Ownership transfer is complete.
    // No fallible operations are allowed past this point.
    // This compile-time assertion prevents double-frees if error handling is added later.
    errdefer comptime unreachable;

    return list;
}

/// Helper function to deinit a FeedList and all its contained strings
pub fn deinitFeedList(allocator: std.mem.Allocator, list: *FeedList) void {
    for (list.items) |feed| {
        feed.deinit(allocator);
    }
    list.deinit(allocator);
}

pub const DisplayConfig = struct {
    maxTitleLength: usize = 120,
    maxDescriptionLength: usize = 300,
    maxItemsPerFeed: usize = 20,
    showPublishDate: bool = true,
    showDescription: bool = true,
    showLink: bool = true,
    truncateUrls: bool = true,
    pagerMode: bool = true,
    underlineUrls: bool = true,
    dateFormat: []const u8 = "%Y-%m-%d", // Format for dates older than a week
};

pub const HistoryConfig = struct {
    retentionDays: u32 = 50, // Default to 50 days
    fetchIntervalDays: u32 = 1, // How often to fetch feeds in days (1 = daily)
    dayStartHour: u8 = 0, // Hour of the day regarding when the next day starts (0-23)
};

pub const NetworkConfig = struct {
    maxFeedSizeMB: f64 = 0.2, // Default to 200KB per feed
};

/// GlobalConfig represents the global application configuration.
pub const GlobalConfig = struct {
    display: DisplayConfig,
    history: HistoryConfig = HistoryConfig{},
    network: NetworkConfig = NetworkConfig{},
};

/// FeedGroup represents a collection of feeds with a name and display title.
pub const FeedGroup = struct {
    name: []const u8,
    display_name: ?[]const u8,
    feeds: []FeedConfig,

    pub fn deinit(self: FeedGroup, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.display_name) |display| {
            allocator.free(display);
        }
        for (self.feeds) |feed| {
            feed.deinit(allocator);
        }
        allocator.free(self.feeds);
    }

    pub fn getDisplayName(self: FeedGroup) []const u8 {
        return self.display_name orelse self.name;
    }
};

/// ParsedFeed represents a successfully parsed RSS/Atom feed.
/// Owns its memory through an ArenaAllocator to avoid double allocation.
pub const ParsedFeed = struct {
    arena: std.heap.ArenaAllocator,
    title: ?[]const u8,
    description: ?[]const u8 = null,
    link: ?[]const u8 = null,
    language: ?[]const u8 = null,
    generator: ?[]const u8 = null,
    lastBuildDate: ?[]const u8 = null,
    items: []RssItem,
    author_name: ?[]const u8 = null, // YouTube channel name
    author_uri: ?[]const u8 = null, // YouTube channel URL

    pub fn deinit(self: *ParsedFeed) void {
        self.arena.deinit();
    }
};

/// RssItem represents a parsed RSS feed item.
/// OWNERSHIP REQUIREMENT: All string fields must be owned by the given allocator
/// if they are not null. They must have been allocated with allocator.dupe() or allocator.alloc().
pub const RssItem = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    link: ?[]const u8 = null,
    pubDate: ?[]const u8 = null,
    timestamp: i64 = 0,
    guid: ?[]const u8 = null,
    feedName: ?[]const u8 = null,
    groupName: ?[]const u8 = null,
    groupDisplayName: ?[]const u8 = null,

    pub fn deinit(self: RssItem, allocator: std.mem.Allocator) void {
        if (self.title) |t| allocator.free(t);
        if (self.description) |d| allocator.free(d);
        if (self.link) |l| allocator.free(l);
        if (self.pubDate) |p| allocator.free(p);
        if (self.guid) |g| allocator.free(g);
        if (self.feedName) |f| allocator.free(f);
        if (self.groupName) |g| allocator.free(g);
        if (self.groupDisplayName) |gdn| allocator.free(gdn);
    }

    pub fn clone(self: RssItem, allocator: std.mem.Allocator) !RssItem {
        const title = if (self.title) |t| try allocator.dupe(u8, t) else null;
        errdefer if (title) |t| allocator.free(t);

        const description = if (self.description) |d| try allocator.dupe(u8, d) else null;
        errdefer if (description) |d| allocator.free(d);

        const link = if (self.link) |l| try allocator.dupe(u8, l) else null;
        errdefer if (link) |l| allocator.free(l);

        const pubDate = if (self.pubDate) |p| try allocator.dupe(u8, p) else null;
        errdefer if (pubDate) |p| allocator.free(p);

        const guid = if (self.guid) |g| try allocator.dupe(u8, g) else null;
        errdefer if (guid) |g| allocator.free(g);

        const feedName = if (self.feedName) |f| try allocator.dupe(u8, f) else null;
        errdefer if (feedName) |f| allocator.free(f);

        const groupName = if (self.groupName) |g| try allocator.dupe(u8, g) else null;
        errdefer if (groupName) |g| allocator.free(g);

        const groupDisplayName = if (self.groupDisplayName) |gdn| try allocator.dupe(u8, gdn) else null;
        errdefer if (groupDisplayName) |gdn| allocator.free(gdn);

        return RssItem{
            .title = title,
            .description = description,
            .link = link,
            .pubDate = pubDate,
            .timestamp = self.timestamp,
            .guid = guid,
            .feedName = feedName,
            .groupName = groupName,
            .groupDisplayName = groupDisplayName,
        };
    }
};

/// LastRunState stores items from the previous run.
pub const LastRunState = struct {
    timestamp: ?i64 = null,
    items: []const RssItem = &.{},
    /// Date string from the history filename (YYYY-MM-DD format), used for accurate "days ago" display
    file_date: ?[]const u8 = null,

    pub fn deinit(self: LastRunState, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            item.deinit(allocator);
        }
        allocator.free(self.items);
        if (self.file_date) |fd| {
            allocator.free(fd);
        }
    }
};

/// CurlError represents an error from the curl fallback.
pub const CurlError = struct {
    message: []const u8,

    pub fn init(allocator: std.mem.Allocator, msg: []const u8) !CurlError {
        return CurlError{
            .message = try allocator.dupe(u8, msg),
        };
    }

    pub fn deinit(self: CurlError, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};
