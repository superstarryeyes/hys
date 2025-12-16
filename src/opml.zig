const std = @import("std");
const types = @import("types");
const rss_reader = @import("rss_reader");

const c = @cImport({
    @cInclude("expat.h");
});

const curl = @cImport({
    @cInclude("curl/curl.h");
});

const CurlWriteContext = struct {
    buffer: *std.array_list.Managed(u8),
    max_bytes: usize,
    exceeded_limit: bool,
};

fn curlWriteCallback(data: [*c]const u8, size: usize, nmemb: usize, user_data: ?*anyopaque) callconv(.c) usize {
    if (user_data == null) return 0;
    const ptr = user_data.?;
    std.debug.assert(std.mem.isAligned(@intFromPtr(ptr), @alignOf(CurlWriteContext)));
    const ctx: *CurlWriteContext = @ptrCast(@alignCast(ptr));
    const total_size: usize = size * nmemb;
    if (ctx.exceeded_limit) return 0;
    if (ctx.buffer.items.len + total_size > ctx.max_bytes) {
        const remaining = ctx.max_bytes - ctx.buffer.items.len;
        if (remaining > 0) {
            ctx.buffer.appendSlice(data[0..remaining]) catch return 0;
        }
        ctx.exceeded_limit = true;
        return 0;
    }
    ctx.buffer.appendSlice(data[0..total_size]) catch return 0;
    return total_size;
}

pub const OpmlManager = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) OpmlManager {
        return OpmlManager{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *OpmlManager) void {
        self.arena.deinit();
    }

    /// Fetch OPML content from a URL using libcurl
    /// Returns the raw OPML content as a string
    pub fn fetchFromUrl(self: *OpmlManager, url: []const u8) ![]u8 {
        const url_z = self.allocator.allocSentinel(u8, url.len, 0) catch return error.OutOfMemory;
        defer self.allocator.free(url_z);
        @memcpy(url_z, url);

        const handle = curl.curl_easy_init() orelse return error.CurlFailed;
        defer curl.curl_easy_cleanup(handle);

        var response_buffer = std.array_list.Managed(u8).init(self.allocator);

        var write_ctx = CurlWriteContext{
            .buffer = &response_buffer,
            .max_bytes = 10 * 1024 * 1024, // 10MB limit for OPML files
            .exceeded_limit = false,
        };

        const setup_ok = blk: {
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_URL, url_z.ptr) != curl.CURLE_OK) break :blk false;
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEFUNCTION, @as(curl.curl_write_callback, @ptrCast(&curlWriteCallback))) != curl.CURLE_OK) break :blk false;
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&write_ctx))) != curl.CURLE_OK) break :blk false;
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)) != curl.CURLE_OK) break :blk false;
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_MAXREDIRS, @as(c_long, 10)) != curl.CURLE_OK) break :blk false;
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_CONNECTTIMEOUT, @as(c_long, 10)) != curl.CURLE_OK) break :blk false;
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_TIMEOUT, @as(c_long, 30)) != curl.CURLE_OK) break :blk false;
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_ACCEPT_ENCODING, "") != curl.CURLE_OK) break :blk false;
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_USERAGENT, "hys-rss/0.1.0") != curl.CURLE_OK) break :blk false;
            break :blk true;
        };

        if (!setup_ok) {
            response_buffer.deinit();
            return error.CurlFailed;
        }

        const result = curl.curl_easy_perform(handle);

        if (result != curl.CURLE_OK) {
            response_buffer.deinit();
            return error.NetworkError;
        }

        var http_code: c_long = 0;
        _ = curl.curl_easy_getinfo(handle, curl.CURLINFO_RESPONSE_CODE, &http_code);
        if (http_code >= 400) {
            response_buffer.deinit();
            return error.HttpError;
        }

        if (response_buffer.items.len == 0) {
            response_buffer.deinit();
            return error.NetworkError;
        }

        return response_buffer.toOwnedSlice();
    }

    /// Import feeds from an OPML source (file path or URL) using libexpat
    /// Returns a FeedList (flat list of all feeds)
    pub fn importFromSource(self: *OpmlManager, source: []const u8) !types.FeedList {
        const is_url = std.mem.startsWith(u8, source, "http://") or std.mem.startsWith(u8, source, "https://");

        const raw_content = if (is_url) blk: {
            // Fetch from URL
            break :blk try self.fetchFromUrl(source);
        } else blk: {
            // Read from file
            const file = try std.fs.cwd().openFile(source, .{});
            defer file.close();

            const file_size = try file.getEndPos();
            const content = try self.allocator.alloc(u8, file_size);
            errdefer self.allocator.free(content);
            _ = try file.readAll(content);
            break :blk content;
        };
        defer self.allocator.free(raw_content);

        // Sanitize XML content (fix unescaped ampersands)
        const content = try self.sanitizeXmlContent(raw_content);
        defer self.allocator.free(content);
        
        // Skip leading whitespace before XML declaration
        const trimmed_content = std.mem.trimLeft(u8, content, " \t\n\r");

        // Parse using arena allocator for temporary storage
        const arena_allocator = self.arena.allocator();

        // Initialize Context
        var context = try ParserContext.init(arena_allocator);

        // Create Parser
        const parser = c.XML_ParserCreate(null);
        if (parser == null) {
            context.deinit();
            return error.OutOfMemory;
        }
        defer c.XML_ParserFree(parser);

        c.XML_SetUserData(parser, &context);
        c.XML_SetElementHandler(parser, startElementHandler, null);

        // Parse
        if (c.XML_Parse(parser, trimmed_content.ptr, @intCast(trimmed_content.len), 1) == c.XML_STATUS_ERROR) {
            context.deinit();
            return error.XmlParseError;
        }

        // Clone to parent allocator (persist the data outside the arena/context)
        const result = try types.cloneFeedListFromSlice(self.allocator, context.feeds.items);

        // Explicitly deinit context (arena will be cleaned up when OpmlManager is deinit'd)
        context.deinit();

        return result;
    }

    /// Import all feeds from an OPML source (file or URL) into a specific group (flattens group structure)
    pub fn importToGroup(self: *OpmlManager, source: []const u8, group_name: []const u8, feed_group_manager: anytype) !usize {
        if (group_name.len == 0) return error.InvalidGroupName;

        // Parse OPML to get flat list of feeds
        var feed_list = try self.importFromSource(source);
        defer types.deinitFeedList(self.allocator, &feed_list);

        var added_count: usize = 0;

        // Add each feed to the target group
        for (feed_list.items) |feed| {
            feed_group_manager.addFeedConfigToGroup(group_name, feed) catch |err| switch (err) {
                error.FeedAlreadyExists => continue, // Skip duplicates
                else => return err,
            };
            added_count += 1;
        }

        return added_count;
    }

    /// Import feeds from an OPML source (file or URL) and organize into groups
    /// Returns an ArrayList of FeedGroups
    pub fn importFromSourceWithGroups(self: *OpmlManager, source: []const u8, feed_group_manager: anytype) !void {
        const is_url = std.mem.startsWith(u8, source, "http://") or std.mem.startsWith(u8, source, "https://");

        const raw_content = if (is_url) blk: {
            // Fetch from URL
            break :blk try self.fetchFromUrl(source);
        } else blk: {
            // Read from file
            const file = try std.fs.cwd().openFile(source, .{});
            defer file.close();

            const file_size = try file.getEndPos();
            const content = try self.allocator.alloc(u8, file_size);
            errdefer self.allocator.free(content);
            _ = try file.readAll(content);
            break :blk content;
        };
        defer self.allocator.free(raw_content);

        // Sanitize XML content (fix unescaped ampersands)
        const content = try self.sanitizeXmlContent(raw_content);
        defer self.allocator.free(content);
        
        // Skip leading whitespace before XML declaration
        const trimmed_content = std.mem.trimLeft(u8, content, " \t\n\r");

        // Parse using arena allocator for temporary storage
        const arena_allocator = self.arena.allocator();

        // Initialize Context for group parsing
        var context = try GroupParserContext.init(arena_allocator);

        // Create Parser
        const parser = c.XML_ParserCreate(null);
        if (parser == null) {
            context.deinit();
            return error.OutOfMemory;
        }
        defer c.XML_ParserFree(parser);

        c.XML_SetUserData(parser, &context);
        c.XML_SetElementHandler(parser, startElementHandlerWithGroups, endElementHandlerWithGroups);

        // Parse
        if (c.XML_Parse(parser, trimmed_content.ptr, @intCast(trimmed_content.len), 1) == c.XML_STATUS_ERROR) {
            context.deinit();
            return error.XmlParseError;
        }

        // Save groups to feed group manager
        for (context.groups.items) |group| {
            // Convert group name to filename (collapse spaces)
            const filename = try self.collapseSpaces(group.name);
            defer self.allocator.free(filename);

            if (filename.len == 0) return error.InvalidFileName;

            // Clone feeds to parent allocator
            var feed_list = try types.cloneFeedListFromSlice(self.allocator, group.feeds.items);
            defer types.deinitFeedList(self.allocator, &feed_list);

            // Create FeedGroup with display_name
            var display_name: ?[]const u8 = null;
            if (group.display_name) |dn| {
                display_name = try self.allocator.dupe(u8, dn);
            }
            errdefer if (display_name) |dn| self.allocator.free(dn);

            const feeds_slice = try feed_list.toOwnedSlice(self.allocator);
            const feed_group = types.FeedGroup{
                .name = try self.allocator.dupe(u8, filename),
                .display_name = display_name,
                .feeds = feeds_slice,
            };

            try feed_group_manager.saveGroupWithMetadata(feed_group);
            feed_group.deinit(self.allocator);
        }

        // Explicitly deinit context (arena will be cleaned up when OpmlManager is deinit'd)
        context.deinit();
    }

    // --- Expat Handling for flat import ---

    const ParserContext = struct {
        allocator: std.mem.Allocator,
        feeds: std.array_list.Managed(types.FeedConfig),

        fn init(allocator: std.mem.Allocator) !ParserContext {
            return ParserContext{
                .allocator = allocator,
                .feeds = std.array_list.Managed(types.FeedConfig).init(allocator),
            };
        }

        fn deinit(self: *ParserContext) void {
            self.feeds.deinit();
        }
    };

    fn startElementHandler(user_data: ?*anyopaque, name: [*c]const u8, attrs: [*c]const [*c]const u8) callconv(.c) void {
        const ctx: *ParserContext = @ptrCast(@alignCast(user_data orelse return));
        const tag_name = std.mem.span(name);

        // We only care about <outline ...> tags
        if (!std.ascii.eqlIgnoreCase(tag_name, "outline")) return;

        var xmlUrl: ?[]const u8 = null;
        var text: ?[]const u8 = null;
        var title: ?[]const u8 = null;
        var htmlUrl: ?[]const u8 = null;
        var description: ?[]const u8 = null;
        var feed_type: ?[]const u8 = null;
        var language: ?[]const u8 = null;
        var version: ?[]const u8 = null;

        // Iterate attributes
        // attrs is an array of strings: name, value, name, value, NULL
        var i: usize = 0;
        while (attrs[i] != null and attrs[i + 1] != null) : (i += 2) {
            const attr_name = std.mem.span(attrs[i]);
            const attr_val = std.mem.span(attrs[i + 1]);

            if (std.ascii.eqlIgnoreCase(attr_name, "xmlUrl")) {
                xmlUrl = attr_val;
            } else if (std.ascii.eqlIgnoreCase(attr_name, "text")) {
                text = attr_val;
            } else if (std.ascii.eqlIgnoreCase(attr_name, "title")) {
                title = attr_val;
            } else if (std.ascii.eqlIgnoreCase(attr_name, "htmlUrl")) {
                htmlUrl = attr_val;
            } else if (std.ascii.eqlIgnoreCase(attr_name, "description")) {
                description = attr_val;
            } else if (std.ascii.eqlIgnoreCase(attr_name, "type")) {
                feed_type = attr_val;
            } else if (std.ascii.eqlIgnoreCase(attr_name, "language")) {
                language = attr_val;
            } else if (std.ascii.eqlIgnoreCase(attr_name, "version")) {
                version = attr_val;
            }
        }

        if (xmlUrl) |url| {
            // Determine the text: prefer title, fallback to text
            const feed_text_raw = if (title) |t| t else text;

            // Normalize the feed URL (handle feed:// scheme conversion)
            const normalized_url = rss_reader.RssReader.normalizeFeedUrl(ctx.allocator, url) catch return;
            defer ctx.allocator.free(normalized_url);

            // Sanitize data (Expat handles XML entities, but we still need to prevent terminal injection)
            // We use the context allocator (Arena) here. The final cloneFeeds will move it to the main allocator.
            const clean_url = rss_reader.RssReader.sanitizeFeedData(normalized_url, ctx.allocator) catch return;

            var clean_text: ?[]const u8 = null;
            if (feed_text_raw) |raw_text| {
                clean_text = rss_reader.RssReader.sanitizeFeedData(raw_text, ctx.allocator) catch null;
            }

            // Clone OPML metadata if available - use ctx.allocator to clone from arena
            const opml_title = if (title) |t| ctx.allocator.dupe(u8, t) catch null else null;
            const opml_html_url = if (htmlUrl) |h| ctx.allocator.dupe(u8, h) catch null else null;
            const opml_description = if (description) |d| ctx.allocator.dupe(u8, d) catch null else null;
            const opml_language = if (language) |l| ctx.allocator.dupe(u8, l) catch null else null;
            const opml_version = if (version) |v| ctx.allocator.dupe(u8, v) catch null else null;

            ctx.feeds.append(types.FeedConfig{
                .xmlUrl = clean_url,
                .text = clean_text,
                .enabled = true,
                .title = opml_title,
                .htmlUrl = opml_html_url,
                .description = opml_description,
                .language = opml_language,
                .version = opml_version,
            }) catch {};
        }
    }

    // --- Expat Handling for group import ---

    const OutlineData = struct {
        allocator: std.mem.Allocator,
        text: ?[]const u8 = null,
        title: ?[]const u8 = null,
        xmlUrl: ?[]const u8 = null,
        htmlUrl: ?[]const u8 = null,
        description: ?[]const u8 = null,
        type: ?[]const u8 = null,
        language: ?[]const u8 = null,
        version: ?[]const u8 = null,

        fn clone(self: OutlineData) !OutlineData {
            return OutlineData{
                .allocator = self.allocator,
                .text = if (self.text) |t| try self.allocator.dupe(u8, t) else null,
                .title = if (self.title) |t| try self.allocator.dupe(u8, t) else null,
                .xmlUrl = if (self.xmlUrl) |u| try self.allocator.dupe(u8, u) else null,
                .htmlUrl = if (self.htmlUrl) |u| try self.allocator.dupe(u8, u) else null,
                .description = if (self.description) |d| try self.allocator.dupe(u8, d) else null,
                .type = if (self.type) |t| try self.allocator.dupe(u8, t) else null,
                .language = if (self.language) |l| try self.allocator.dupe(u8, l) else null,
                .version = if (self.version) |v| try self.allocator.dupe(u8, v) else null,
            };
        }

        fn deinit(self: OutlineData) void {
            if (self.text) |t| self.allocator.free(t);
            if (self.title) |t| self.allocator.free(t);
            if (self.xmlUrl) |u| self.allocator.free(u);
            if (self.htmlUrl) |u| self.allocator.free(u);
            if (self.description) |d| self.allocator.free(d);
            if (self.type) |t| self.allocator.free(t);
            if (self.language) |l| self.allocator.free(l);
            if (self.version) |v| self.allocator.free(v);
        }
    };

    const GroupData = struct {
        allocator: std.mem.Allocator,
        name: []const u8,
        display_name: ?[]const u8,
        feeds: std.array_list.Managed(types.FeedConfig),

        fn deinit(self: *GroupData) void {
            self.allocator.free(self.name);
            if (self.display_name) |name| {
                self.allocator.free(name);
            }
            self.feeds.deinit();
        }
    };

    const GroupParserContext = struct {
        allocator: std.mem.Allocator,
        groups: std.array_list.Managed(GroupData),
        current_group: ?*GroupData = null,
        depth: usize = 0,
        group_depth: ?usize = null, // Depth at which the current group was created

        fn init(allocator: std.mem.Allocator) !GroupParserContext {
            return GroupParserContext{
                .allocator = allocator,
                .groups = std.array_list.Managed(GroupData).init(allocator),
            };
        }

        fn deinit(self: *GroupParserContext) void {
            self.groups.deinit();
        }
    };

    fn startElementHandlerWithGroups(user_data: ?*anyopaque, name: [*c]const u8, attrs: [*c]const [*c]const u8) callconv(.c) void {
        var ctx: *GroupParserContext = @ptrCast(@alignCast(user_data orelse return));
        const tag_name = std.mem.span(name);

        // Increment depth for every element
        ctx.depth += 1;

        // We only care about <outline ...> tags
        if (!std.ascii.eqlIgnoreCase(tag_name, "outline")) return;

        // Parse attributes
        var xmlUrl: ?[]const u8 = null;
        var text: ?[]const u8 = null;
        var title: ?[]const u8 = null;
        var htmlUrl: ?[]const u8 = null;
        var description: ?[]const u8 = null;
        var feed_type: ?[]const u8 = null;
        var language: ?[]const u8 = null;
        var version: ?[]const u8 = null;

        var i: usize = 0;
        while (attrs[i] != null and attrs[i + 1] != null) : (i += 2) {
            const attr_name = std.mem.span(attrs[i]);
            const attr_val = std.mem.span(attrs[i + 1]);

            if (std.ascii.eqlIgnoreCase(attr_name, "text")) {
                text = attr_val;
            } else if (std.ascii.eqlIgnoreCase(attr_name, "title")) {
                title = attr_val;
            } else if (std.ascii.eqlIgnoreCase(attr_name, "xmlUrl")) {
                xmlUrl = attr_val;
            } else if (std.ascii.eqlIgnoreCase(attr_name, "htmlUrl")) {
                htmlUrl = attr_val;
            } else if (std.ascii.eqlIgnoreCase(attr_name, "description")) {
                description = attr_val;
            } else if (std.ascii.eqlIgnoreCase(attr_name, "type")) {
                feed_type = attr_val;
            } else if (std.ascii.eqlIgnoreCase(attr_name, "language")) {
                language = attr_val;
            } else if (std.ascii.eqlIgnoreCase(attr_name, "version")) {
                version = attr_val;
            }
        }

        // Check if this is a feed (has xmlUrl) or a group
        if (xmlUrl != null) {
            // This is a feed - add to current group, or create "main" group for flat OPML files
            if (ctx.current_group == null) {
                // No group exists yet - create a "main" group for flat OPML imports
                const new_group = GroupData{
                    .allocator = ctx.allocator,
                    .name = ctx.allocator.dupe(u8, "main") catch return,
                    .display_name = null,
                    .feeds = std.array_list.Managed(types.FeedConfig).init(ctx.allocator),
                };

                ctx.groups.append(new_group) catch {
                    var mut_group = new_group;
                    mut_group.deinit();
                    return;
                };

                ctx.current_group = &ctx.groups.items[ctx.groups.items.len - 1];
                // Don't set group_depth since this is an implicit group that should stay active
            }

            if (ctx.current_group) |group| {
                const feed_text_raw = if (title) |t| t else text;

                // Normalize the feed URL (handle feed:// scheme conversion)
                const normalized_url = rss_reader.RssReader.normalizeFeedUrl(ctx.allocator, xmlUrl.?) catch return;
                defer ctx.allocator.free(normalized_url);

                const clean_url = rss_reader.RssReader.sanitizeFeedData(normalized_url, ctx.allocator) catch return;
                var clean_text: ?[]const u8 = null;
                if (feed_text_raw) |raw_text| {
                    clean_text = rss_reader.RssReader.sanitizeFeedData(raw_text, ctx.allocator) catch null;
                }

                // Clone OPML metadata
                const opml_title = if (title) |t| ctx.allocator.dupe(u8, t) catch null else null;
                const opml_html_url = if (htmlUrl) |h| ctx.allocator.dupe(u8, h) catch null else null;
                const opml_description = if (description) |d| ctx.allocator.dupe(u8, d) catch null else null;
                const opml_language = if (language) |l| ctx.allocator.dupe(u8, l) catch null else null;
                const opml_version = if (version) |v| ctx.allocator.dupe(u8, v) catch null else null;

                const feed_config = types.FeedConfig{
                    .xmlUrl = clean_url,
                    .text = clean_text,
                    .enabled = true,
                    .title = opml_title,
                    .htmlUrl = opml_html_url,
                    .description = opml_description,
                    .language = opml_language,
                    .version = opml_version,
                };

                group.feeds.append(feed_config) catch {};
            }
        } else {
            // This is a group - always create a new group when we see one at depth > group_depth (or group_depth is null)
            const should_create_group = if (ctx.group_depth) |gd| ctx.depth <= gd else true;

            if (should_create_group) {
                const group_name = if (text) |t| t else "Ungrouped";
                const group_display_name = if (title) |t| t else null;

                const new_group = GroupData{
                    .allocator = ctx.allocator,
                    .name = ctx.allocator.dupe(u8, group_name) catch return,
                    .display_name = if (group_display_name) |n| ctx.allocator.dupe(u8, n) catch null else null,
                    .feeds = std.array_list.Managed(types.FeedConfig).init(ctx.allocator),
                };

                ctx.groups.append(new_group) catch {
                    var mut_group = new_group;
                    mut_group.deinit();
                    return;
                };

                ctx.current_group = &ctx.groups.items[ctx.groups.items.len - 1];
                ctx.group_depth = ctx.depth;
            }
        }
    }

    fn endElementHandlerWithGroups(user_data: ?*anyopaque, name: [*c]const u8) callconv(.c) void {
        var ctx: *GroupParserContext = @ptrCast(@alignCast(user_data orelse return));
        const tag_name = std.mem.span(name);

        // Decrement depth for every element
        if (ctx.depth > 0) {
            ctx.depth -= 1;
        }

        // Check if we're closing a group outline
        if (std.ascii.eqlIgnoreCase(tag_name, "outline")) {
            if (ctx.group_depth) |gd| {
                if (ctx.depth < gd) {
                    // We've exited the group
                    ctx.current_group = null;
                    ctx.group_depth = null;
                }
            }
        }
    }

    // --- Export functions ---

    /// Export feeds to an OPML file path (flat structure)
    /// title: Optional title for the OPML head, defaults to "Hys RSS Feeds"
    pub fn exportToFile(self: *OpmlManager, file_path: []const u8, feeds: types.FeedList, title: ?[]const u8) !void {
        var output = std.array_list.Managed(u8).init(self.allocator);
        defer output.deinit();

        const opml_title = title orelse "Hys RSS Feeds";
        const safe_title = try self.escapeXml(opml_title);
        defer self.allocator.free(safe_title);

        try std.fmt.format(output.writer(),
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<opml version="2.0">
            \\<head>
            \\    <title>{s}</title>
            \\</head>
            \\<body>
            \\
        , .{safe_title});

        for (feeds.items) |feed| {
            // Basic XML escaping for attributes
            const safe_url = try self.escapeXml(feed.xmlUrl);
            defer self.allocator.free(safe_url);

            const text = feed.text orelse "Unknown Feed";
            const safe_text = try self.escapeXml(text);
            defer self.allocator.free(safe_text);

            // Use feed.title if available, otherwise use text
            const feed_title = feed.title orelse text;
            const safe_feed_title = try self.escapeXml(feed_title);
            defer self.allocator.free(safe_feed_title);

            // Build outline with all available metadata
            var outline_buf = std.array_list.Managed(u8).init(self.allocator);
            defer outline_buf.deinit();

            try std.fmt.format(outline_buf.writer(), "    <outline type=\"rss\" text=\"{s}\" title=\"{s}\" xmlUrl=\"{s}\"", .{ safe_text, safe_feed_title, safe_url });

            if (feed.htmlUrl) |html_url| {
                const safe_html_url = try self.escapeXml(html_url);
                defer self.allocator.free(safe_html_url);
                try std.fmt.format(outline_buf.writer(), " htmlUrl=\"{s}\"", .{safe_html_url});
            }

            if (feed.description) |desc| {
                const safe_desc = try self.escapeXml(desc);
                defer self.allocator.free(safe_desc);
                try std.fmt.format(outline_buf.writer(), " description=\"{s}\"", .{safe_desc});
            }

            if (feed.language) |lang| {
                const safe_lang = try self.escapeXml(lang);
                defer self.allocator.free(safe_lang);
                try std.fmt.format(outline_buf.writer(), " language=\"{s}\"", .{safe_lang});
            }

            try output.appendSlice(outline_buf.items);
            try output.appendSlice(" />\n");
        }

        try output.appendSlice(
            \\</body>
            \\</opml>
        );

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(output.items);
    }

    /// Export groups to an OPML file with nested structure
    /// title: Optional title for the OPML head, defaults to "Hys RSS Feeds"
    pub fn exportGroupsToFile(self: *OpmlManager, file_path: []const u8, groups: []const types.FeedGroup, title: ?[]const u8) !void {
        var output = std.array_list.Managed(u8).init(self.allocator);
        defer output.deinit();

        const opml_title = title orelse "Hys RSS Feeds";
        const safe_title = try self.escapeXml(opml_title);
        defer self.allocator.free(safe_title);

        try std.fmt.format(output.writer(),
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<opml version="2.0">
            \\<head>
            \\    <title>{s}</title>
            \\</head>
            \\<body>
            \\
        , .{safe_title});

        for (groups) |group| {
            // Use display_name as the group title if available
            const group_title = group.display_name orelse group.name;
            const safe_group_title = try self.escapeXml(group_title);
            defer self.allocator.free(safe_group_title);

            try std.fmt.format(output.writer(), "    <outline text=\"{s}\" title=\"{s}\">\n", .{ safe_group_title, safe_group_title });

            for (group.feeds) |feed| {
                const safe_url = try self.escapeXml(feed.xmlUrl);
                defer self.allocator.free(safe_url);

                const feed_title = feed.title orelse feed.text orelse "Unknown Feed";
                const safe_feed_title = try self.escapeXml(feed_title);
                defer self.allocator.free(safe_feed_title);

                const feed_text = feed.text orelse "Unknown Feed";
                const safe_feed_text = try self.escapeXml(feed_text);
                defer self.allocator.free(safe_feed_text);

                // Build outline with available attributes
                var outline_buf = std.array_list.Managed(u8).init(self.allocator);
                defer outline_buf.deinit();

                try std.fmt.format(outline_buf.writer(), "        <outline text=\"{s}\" title=\"{s}\" xmlUrl=\"{s}\"", .{ safe_feed_text, safe_feed_title, safe_url });

                if (feed.htmlUrl) |html_url| {
                    const safe_html_url = try self.escapeXml(html_url);
                    defer self.allocator.free(safe_html_url);
                    try std.fmt.format(outline_buf.writer(), " htmlUrl=\"{s}\"", .{safe_html_url});
                }

                if (feed.description) |desc| {
                    const safe_desc = try self.escapeXml(desc);
                    defer self.allocator.free(safe_desc);
                    try std.fmt.format(outline_buf.writer(), " description=\"{s}\"", .{safe_desc});
                }

                // Hardcode type="rss" for OPML export
                try outline_buf.appendSlice(" type=\"rss\"");

                if (feed.language) |lang| {
                    const safe_lang = try self.escapeXml(lang);
                    defer self.allocator.free(safe_lang);
                    try std.fmt.format(outline_buf.writer(), " language=\"{s}\"", .{safe_lang});
                }

                try output.appendSlice(outline_buf.items);
                try output.appendSlice(" />\n");
            }

            try output.appendSlice("    </outline>\n");
        }

        try output.appendSlice(
            \\</body>
            \\</opml>
        );

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(output.items);
    }

    fn escapeXml(self: *OpmlManager, input: []const u8) ![]u8 {
        var out = std.array_list.Managed(u8).init(self.allocator);
        defer out.deinit();

        for (input) |char| {
            switch (char) {
                '&' => try out.appendSlice("&amp;"),
                '<' => try out.appendSlice("&lt;"),
                '>' => try out.appendSlice("&gt;"),
                '"' => try out.appendSlice("&quot;"),
                '\'' => try out.appendSlice("&apos;"),
                else => try out.append(char),
            }
        }
        return out.toOwnedSlice();
    }

    /// Collapse spaces in a string for use as a filename
    fn collapseSpaces(self: *OpmlManager, input: []const u8) ![]u8 {
        var out = std.array_list.Managed(u8).init(self.allocator);
        defer out.deinit();

        var prev_space = false;
        for (input) |char| {
            if (char == ' ' or char == '\t' or char == '\n' or char == '\r') {
                if (!prev_space) {
                    try out.append('_');
                    prev_space = true;
                }
            } else {
                try out.append(char);
                prev_space = false;
            }
        }

        return out.toOwnedSlice();
    }

    /// Sanitize XML content by escaping bare ampersands
    /// Many OPML exporters produce invalid XML with unescaped & characters
    fn sanitizeXmlContent(self: *OpmlManager, input: []const u8) ![]u8 {
        var out = std.array_list.Managed(u8).init(self.allocator);
        defer out.deinit();

        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '&') {
                // Check if this is already an XML entity
                const remaining = input[i..];
                const is_entity = blk: {
                    // Check for common XML entities: &amp; &lt; &gt; &quot; &apos;
                    if (std.mem.startsWith(u8, remaining, "&amp;")) break :blk true;
                    if (std.mem.startsWith(u8, remaining, "&lt;")) break :blk true;
                    if (std.mem.startsWith(u8, remaining, "&gt;")) break :blk true;
                    if (std.mem.startsWith(u8, remaining, "&quot;")) break :blk true;
                    if (std.mem.startsWith(u8, remaining, "&apos;")) break :blk true;
                    // Check for numeric entities: &#123; or &#x1F;
                    if (remaining.len > 2 and remaining[1] == '#') {
                        // Find the semicolon
                        var j: usize = 2;
                        var is_hex = false;
                        if (j < remaining.len and remaining[j] == 'x') {
                            is_hex = true;
                            j += 1;
                        }
                        while (j < remaining.len and j < 10) : (j += 1) {
                            if (remaining[j] == ';') break :blk true;
                            if (is_hex) {
                                if (!std.ascii.isHex(remaining[j])) break;
                            } else {
                                if (!std.ascii.isDigit(remaining[j])) break;
                            }
                        }
                    }
                    break :blk false;
                };

                if (is_entity) {
                    try out.append('&');
                } else {
                    try out.appendSlice("&amp;");
                }
            } else {
                try out.append(input[i]);
            }
            i += 1;
        }

        return out.toOwnedSlice();
    }
};
