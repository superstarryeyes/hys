const std = @import("std");
const zdt = @import("zdt");
const types = @import("types");

const c = @cImport({
    @cInclude("expat.h");
});

const curl = @cImport({
    @cInclude("curl/curl.h");
});

/// RssReader error set - domain-specific errors for feed reading operations
pub const RssReaderError = error{
    /// Network request failed (TLS, HTTP, timeout)
    NetworkError,
    /// Invalid URL or unsupported scheme
    InvalidUrl,
    /// HTTP error response received
    HttpError,
    /// Response body too large
    FileTooLarge,
    /// Too many redirects encountered
    TooManyRedirects,
    /// Missing Location header in redirect
    RedirectWithoutLocation,
    /// Curl fallback command failed
    CurlFailed,
    /// Write operation failed
    WriteFailed,
    /// Memory allocation failed
    OutOfMemory,
    /// Invalid UTF-8 encoding in feed data
    InvalidUtf8,
};

/// Validate a feed URL before storing it.
/// Ensures the URL:
/// - Starts with http://, https://, or file://
/// - Does not contain spaces or other invalid characters
pub fn validateFeedUrl(url: []const u8) RssReaderError!void {
    // Check for valid scheme
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "file://")) {
        return error.InvalidUrl;
    }

    // Check for spaces and other whitespace
    for (url) |char| {
        if (char == ' ' or char == '\t' or char == '\n' or char == '\r') {
            return error.InvalidUrl;
        }
    }

    // Check minimum length
    // file:///a is 8 chars, http://a is 7 chars, https://a is 8 chars
    if (url.len < 7) {
        return error.InvalidUrl;
    }

    // Check for empty domain part after scheme
    // For "https://..." that's 8 chars minimum
    // For "http://..." that's 7 chars minimum
    // For "file://..." that's 8 chars minimum (file:/// + at least 1 char)
    if (std.mem.startsWith(u8, url, "https://")) {
        if (url.len <= 8) {
            return error.InvalidUrl;
        }
    } else if (std.mem.startsWith(u8, url, "file://")) {
        if (url.len <= 8) {
            return error.InvalidUrl;
        }
    } else {
        // http://
        if (url.len <= 7) {
            return error.InvalidUrl;
        }
    }
}

pub const RssReader = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    max_feed_size_mb: f64 = 1,

    pub const ItemCallback = *const fn (item: *const types.RssItem, context: ?*anyopaque) bool;

    // Compile-time constant: HTML entity map for efficient lookups
    const html_entities = std.StaticStringMap([]const u8).initComptime(.{
        .{ "amp", "&" },
        .{ "lt", "<" },
        .{ "gt", ">" },
        .{ "quot", "\"" },
        .{ "apos", "'" },
        .{ "nbsp", " " },
        .{ "rsquo", "\xE2\x80\x99" },
        .{ "lsquo", "\xE2\x80\x98" },
        .{ "rdquo", "\xE2\x80\x9D" },
        .{ "ldquo", "\xE2\x80\x9C" },
        .{ "hellip", "\xE2\x80\xA6" },
        .{ "ndash", "\xE2\x80\x93" },
        .{ "mdash", "\xE2\x80\x94" },
        .{ "bull", "\xE2\x80\xA2" },
        .{ "middot", "\xC2\xB7" },
    });

    /// Strip ANSI underline codes from text while preserving other formatting
    /// This is used when underlineUrls config is disabled
    pub fn stripUnderlineCodes(text: []const u8, allocator: std.mem.Allocator) ![]u8 {
        var result = std.array_list.Managed(u8).init(allocator);
        errdefer result.deinit();

        var pos: usize = 0;
        while (pos < text.len) {
            // Find next underline start code: \x1b[4m
            if (std.mem.indexOf(u8, text[pos..], "\x1b[4m")) |offset| {
                const seq_start = pos + offset;
                // Append text before the sequence
                try result.appendSlice(text[pos..seq_start]);
                // Skip the sequence
                pos = seq_start + 4;
                continue;
            }
            // Find next underline end code: \x1b[24m
            if (std.mem.indexOf(u8, text[pos..], "\x1b[24m")) |offset| {
                const seq_start = pos + offset;
                // Append text before the sequence
                try result.appendSlice(text[pos..seq_start]);
                // Skip the sequence
                pos = seq_start + 5;
                continue;
            }
            // No more sequences, append the rest
            try result.appendSlice(text[pos..]);
            break;
        }
        return result.toOwnedSlice();
    }

    /// Normalize a feed URL by converting feed:// to http:// and duplicating the URL.
    /// Ownership: The caller owns the returned string and must free it.
    pub fn normalizeFeedUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
        if (std.mem.startsWith(u8, url, "feed://")) {
            // Replace "feed://" (7 chars) with "http://" (7 chars)
            // Since lengths are identical, we can just dupe and overwrite
            const new_url = try allocator.alloc(u8, url.len);
            @memcpy(new_url[0..7], "http://");
            @memcpy(new_url[7..], url[7..]);
            return new_url;
        }
        return allocator.dupe(u8, url);
    }

    pub fn init(allocator: std.mem.Allocator) RssReader {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .max_feed_size_mb = 1,
        };
    }

    // Initialize with custom max feed size
    pub fn initWithMaxSize(allocator: std.mem.Allocator, max_feed_size_mb: f64) RssReader {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .max_feed_size_mb = max_feed_size_mb,
        };
    }

    pub fn deinit(self: *RssReader) void {
        self.arena.deinit();
    }

    /// Reset the arena allocator to free all memory allocated during the last feed parse
    pub fn resetArena(self: *RssReader) void {
        _ = self.arena.reset(.free_all);
    }

    pub fn readFeed(self: *RssReader, url: []const u8) !types.ParsedFeed {
        // Reset arena from any previous use
        self.resetArena();

        // 1. Fetch Data
        const xml_data = try self.fetchFeed(url);
        defer self.allocator.free(xml_data);

        // 2. Parse the fetched XML
        return self.parseXml(xml_data, null, null);
    }

    /// Parse pre-fetched XML data into a ParsedFeed.
    /// This is useful when XML has been fetched externally (e.g., via curl_multi batch fetch).
    /// Transfers arena ownership to the returned ParsedFeed to avoid double allocation.
    pub fn parseXml(
        self: *RssReader,
        xml_data: []const u8,
        callback: ?ItemCallback,
        callback_ctx: ?*anyopaque,
    ) !types.ParsedFeed {
        // Early validation: check if content looks like XML before spending time parsing
        if (!looksLikeXml(xml_data)) {
            return error.NetworkError;
        }
        
        // Reset arena from any previous use
        self.resetArena();

        // Parse using Expat and the Arena allocator
        const arena_allocator = self.arena.allocator();

        // Create parser FIRST
        const parser = c.XML_ParserCreate(null);
        if (parser == null) return error.OutOfMemory;
        defer c.XML_ParserFree(parser);

        // Pass parser to init
        var context = try ParserContext.init(arena_allocator, parser);
        context.on_item_callback = callback;
        context.callback_context = callback_ctx;

        c.XML_SetUserData(parser, @ptrCast(&context));
        c.XML_SetElementHandler(parser, startElementHandler, endElementHandler);
        c.XML_SetCharacterDataHandler(parser, charDataHandler);

        if (c.XML_Parse(parser, xml_data.ptr, @intCast(xml_data.len), 1) == c.XML_STATUS_ERROR) {
            const err_code = c.XML_GetErrorCode(parser);
            // If aborted explicitly, treat as Success (we found the boundary)
            if (err_code != c.XML_ERROR_ABORTED) {
                // For truncated feeds, return partial results if we have items
                if (context.feed.items.items.len == 0) {
                    return error.NetworkError; // Or specific parse error
                }
                // Continue with partial results
            }
        }

        if (context.parse_error) |err| {
            return err;
        }

        // Convert items list to owned slice
        const items_slice = try context.feed.items.toOwnedSlice();

        // Transfer arena ownership to ParsedFeed and return
        const result = types.ParsedFeed{
            .arena = self.arena,
            .title = context.feed.title,
            .description = context.feed.description,
            .link = context.feed.link,
            .language = context.feed.language,
            .generator = context.feed.generator,
            .lastBuildDate = context.feed.lastBuildDate,
            .items = items_slice,
            .author_name = context.feed.author_name,
            .author_uri = context.feed.author_uri,
        };

        // Re-initialize arena for next run
        self.arena = std.heap.ArenaAllocator.init(self.allocator);

        return result;
    }

    /// Quick check if content looks like XML/feed data before attempting full parse
    fn looksLikeXml(content: []const u8) bool {
        if (content.len == 0) return false;
        
        // Skip UTF-8 BOM if present
        var start: usize = 0;
        if (content.len >= 3 and content[0] == 0xEF and content[1] == 0xBB and content[2] == 0xBF) {
            start = 3;
        }
        
        // Skip whitespace
        while (start < content.len and std.ascii.isWhitespace(content[start])) {
            start += 1;
        }
        
        if (start >= content.len) return false;
        
        // Must start with < (XML declaration or root element)
        if (content[start] != '<') {
            return false;
        }
        
        // Look for common feed tags within first 1KB to avoid scanning large HTML documents
        const scan_limit = @min(content.len, 1024);
        const scan_slice = content[0..scan_limit];
        
        // Check for known feed/RSS/Atom indicators
        return std.mem.indexOfAny(u8, scan_slice, "<rss") != null or
               std.mem.indexOfAny(u8, scan_slice, "<feed") != null or
               std.mem.indexOfAny(u8, scan_slice, "<RDF") != null or
               std.mem.indexOfAny(u8, scan_slice, "<?xml") != null;
    }

    // --- State Management ---

    const TagType = enum {
        None,
        Title,
        Link,
        Description,
        PubDate,
        Guid,
        Id, // Atom
        Updated, // Atom
        Summary, // Atom
        Content, // Atom
        Language, // RSS
        Generator, // RSS/Atom
        AuthorName, // YouTube Atom <author><name>
        AuthorUri, // YouTube Atom <author><uri>
    };

    const TempFeed = struct {
        title: ?[]const u8,
        description: ?[]const u8,
        link: ?[]const u8,
        language: ?[]const u8,
        generator: ?[]const u8,
        lastBuildDate: ?[]const u8,
        items: std.array_list.Managed(types.RssItem),
        author_name: ?[]const u8, // YouTube channel name from <author><name>
        author_uri: ?[]const u8, // YouTube channel URL from <author><uri>
    };

    const ParserContext = struct {
        allocator: std.mem.Allocator,
        feed: TempFeed,

        // State
        current_item: ?types.RssItem,
        current_tag: TagType,
        char_buffer: std.array_list.Managed(u8),

        // Depth tracking to avoid capturing sub-element text inappropriately
        tag_depth: usize,
        target_depth: usize, // Depth of the tag we are currently capturing

        // Author context tracking
        inside_author: bool,
        author_depth: usize,

        // Error tracking
        parse_error: ?anyerror = null,

        // ADD THESE 3 FIELDS:
        parser: c.XML_Parser,
        on_item_callback: ?ItemCallback = null,
        callback_context: ?*anyopaque = null,

        fn init(allocator: std.mem.Allocator, parser: c.XML_Parser) !ParserContext {
            return ParserContext{
                .allocator = allocator,
                .feed = TempFeed{
                    .title = null,
                    .description = null,
                    .link = null,
                    .language = null,
                    .generator = null,
                    .lastBuildDate = null,
                    .items = std.array_list.Managed(types.RssItem).init(allocator),
                    .author_name = null,
                    .author_uri = null,
                },
                .current_item = null,
                .current_tag = .None,
                .char_buffer = std.array_list.Managed(u8).init(allocator),
                .tag_depth = 0,
                .target_depth = 0,
                .inside_author = false,
                .author_depth = 0,
                .parser = parser, // Store parser
                .on_item_callback = null,
                .callback_context = null,
            };
        }

        fn deinit(self: *ParserContext) void {
            self.feed.items.deinit();
            self.char_buffer.deinit();
        }
    };

    // --- Expat Callbacks ---

    fn startElementHandler(user_data: ?*anyopaque, name: [*c]const u8, attrs: [*c]const [*c]const u8) callconv(.c) void {
        if (user_data == null) return;
        const ptr = user_data.?;
        std.debug.assert(std.mem.isAligned(@intFromPtr(ptr), @alignOf(ParserContext)));
        var ctx: *ParserContext = @ptrCast(@alignCast(ptr));
        const tag_name = std.mem.span(name);
        ctx.tag_depth += 1;

        // Track author elements
        if (eqlIgnoreCase(tag_name, "author")) {
            ctx.inside_author = true;
            ctx.author_depth = ctx.tag_depth;
        }

        // Detect Start of Item/Entry
        if (eqlIgnoreCase(tag_name, "item") or eqlIgnoreCase(tag_name, "entry")) {
            // Initialize new item with null fields - efficient, no allocations needed
            ctx.current_item = types.RssItem{
                .title = null,
                .description = null,
                .link = null,
                .pubDate = null,
                .timestamp = 0,
                .guid = null,
                .feedName = null,
            };
            return;
        }

        // Map tags to enum for easier handling
        var new_tag = TagType.None;
        if (eqlIgnoreCase(tag_name, "title")) new_tag = .Title;
        if (eqlIgnoreCase(tag_name, "link")) new_tag = .Link;
        if (eqlIgnoreCase(tag_name, "description")) new_tag = .Description;
        if (eqlIgnoreCase(tag_name, "content:encoded")) new_tag = .Description;
        if (eqlIgnoreCase(tag_name, "media:description")) new_tag = .Description;
        if (eqlIgnoreCase(tag_name, "pubDate")) new_tag = .PubDate;
        if (eqlIgnoreCase(tag_name, "published")) new_tag = .PubDate;
        if (eqlIgnoreCase(tag_name, "dc:date")) new_tag = .PubDate;
        if (eqlIgnoreCase(tag_name, "date")) new_tag = .PubDate;
        if (eqlIgnoreCase(tag_name, "updated")) new_tag = .Updated;
        if (eqlIgnoreCase(tag_name, "guid")) new_tag = .Guid;
        if (eqlIgnoreCase(tag_name, "id")) new_tag = .Id;
        if (eqlIgnoreCase(tag_name, "summary")) new_tag = .Summary;
        if (eqlIgnoreCase(tag_name, "content")) new_tag = .Content;
        if (eqlIgnoreCase(tag_name, "subtitle")) new_tag = .Description;
        if (eqlIgnoreCase(tag_name, "language")) new_tag = .Language;
        if (eqlIgnoreCase(tag_name, "generator")) new_tag = .Generator;
        if (eqlIgnoreCase(tag_name, "lastBuildDate")) new_tag = .PubDate;
        // Only capture name and uri when inside author elements
        if (eqlIgnoreCase(tag_name, "name") and ctx.inside_author) new_tag = .AuthorName;
        if (eqlIgnoreCase(tag_name, "uri") and ctx.inside_author) new_tag = .AuthorUri;

        // Check for xml:lang on root elements
        if (attrs != null and (eqlIgnoreCase(tag_name, "feed") or eqlIgnoreCase(tag_name, "rss") or eqlIgnoreCase(tag_name, "channel"))) {
            var i: usize = 0;
            while (attrs[i] != null and attrs[i + 1] != null) : (i += 2) {
                const attr_name = std.mem.span(attrs[i]);
                if (eqlIgnoreCase(attr_name, "xml:lang")) {
                    const attr_val = std.mem.span(attrs[i + 1]);
                    if (ctx.feed.language == null) {
                        ctx.feed.language = ctx.allocator.dupe(u8, attr_val) catch null;
                    }
                }
            }
        }

        // Atom Link handling (href attribute)
        if (new_tag == .Link and attrs != null) {
            var i: usize = 0;
            while (attrs[i] != null and attrs[i + 1] != null) : (i += 2) {
                const attr_name = std.mem.span(attrs[i]);
                if (eqlIgnoreCase(attr_name, "href")) {
                    const attr_val = std.mem.span(attrs[i + 1]);
                    // Logic to check if we should use this link
                    var use_link = false;
                    if (ctx.current_item) |item| {
                        if (item.link == null) use_link = true;
                    } else {
                        // Root link
                        if (ctx.feed.link == null) use_link = true;

                        // Check rel attribute to distinguish self vs alternate
                        // But finding any href is better than nothing if alternate is missing
                        // Ideally we prefer 'alternate' or no rel (which implies alternate)
                    }

                    if (use_link) {
                        const sanitized_link = sanitizeFeedData(attr_val, ctx.allocator) catch attr_val;
                        defer {
                            if (sanitized_link.ptr != attr_val.ptr) {
                                ctx.allocator.free(sanitized_link);
                            }
                        }

                        if (ctx.allocator.dupe(u8, sanitized_link) catch null) |duped| {
                            if (ctx.current_item) |*item| {
                                item.link = duped;
                            } else {
                                ctx.feed.link = duped;
                            }
                        }
                    }
                }
            }
        }

        // Enclosure handling for podcasts - extract url attribute as fallback link
        // Podcasts use <enclosure url="..." type="audio/mpeg" /> for episode media
        if (eqlIgnoreCase(tag_name, "enclosure") and ctx.current_item != null and attrs != null) {
            // Only use enclosure URL if we don't already have a link
            if (ctx.current_item.?.link == null) {
                var i: usize = 0;
                while (attrs[i] != null and attrs[i + 1] != null) : (i += 2) {
                    const attr_name = std.mem.span(attrs[i]);
                    if (eqlIgnoreCase(attr_name, "url")) {
                        const attr_val = std.mem.span(attrs[i + 1]);
                        const sanitized_url = sanitizeFeedData(attr_val, ctx.allocator) catch attr_val;
                        defer {
                            if (sanitized_url.ptr != attr_val.ptr) {
                                ctx.allocator.free(sanitized_url);
                            }
                        }

                        if (ctx.allocator.dupe(u8, sanitized_url)) |duped| {
                            ctx.current_item.?.link = duped;
                        } else |_| {
                            // Allocation failed, leave as null
                        }
                        break;
                    }
                }
            }
        }

        if (new_tag != .None and ctx.current_tag == .None) {
            ctx.current_tag = new_tag;
            ctx.target_depth = ctx.tag_depth;
            ctx.char_buffer.clearRetainingCapacity();
        }
    }

    fn endElementHandler(user_data: ?*anyopaque, name: [*c]const u8) callconv(.c) void {
        if (user_data == null) return;
        const ptr = user_data.?;
        std.debug.assert(std.mem.isAligned(@intFromPtr(ptr), @alignOf(ParserContext)));
        var ctx: *ParserContext = @ptrCast(@alignCast(ptr));
        const tag_name = std.mem.span(name);

        // Track author element closing
        if (eqlIgnoreCase(tag_name, "author") and ctx.inside_author and ctx.tag_depth == ctx.author_depth) {
            ctx.inside_author = false;
            ctx.author_depth = 0;
        }

        // End of Item/Entry
        if (eqlIgnoreCase(tag_name, "item") or eqlIgnoreCase(tag_name, "entry")) {
            if (ctx.current_item) |item| {
                var stop_now = false;

                // Check callback: returns true if item is seen
                if (ctx.on_item_callback) |cb| {
                    if (cb(&item, ctx.callback_context)) {
                        stop_now = true;
                    }
                }

                // Only append if we aren't stopping (discard the seen item)
                if (!stop_now) {
                    ctx.feed.items.append(item) catch |err| {
                        ctx.parse_error = err;
                        ctx.current_item = null;
                        ctx.tag_depth -= 1;
                        return;
                    };
                }

                ctx.current_item = null;

                if (stop_now) {
                    // Stop parsing immediately
                    _ = c.XML_StopParser(ctx.parser, c.XML_FALSE);
                }
            }
            ctx.tag_depth -= 1;
            return;
        }

        // If we are closing the tag we are currently capturing
        if (ctx.current_tag != .None and ctx.tag_depth == ctx.target_depth) {
            // Use allocating cleaner to preserve links as ANSI hyperlinks.
            const cleaned = cleanHtmlSimple(ctx.char_buffer.items, ctx.allocator) catch |err| {
                ctx.parse_error = err;
                ctx.current_tag = .None;
                ctx.tag_depth -= 1;
                return;
            };

            // Reuse the buffer capacity for the next tag
            ctx.char_buffer.clearRetainingCapacity();

            if (ctx.current_item) |*item| {
                switch (ctx.current_tag) {
                    .Title => item.title = cleaned,
                    .Link => if (item.link == null) {
                        item.link = cleaned;
                    },
                    .Description, .Content, .Summary => {
                        // Priority: Description > Summary > Content, or logic to combine
                        if (item.description == null) item.description = cleaned;
                    },
                    .PubDate, .Updated => {
                        if (item.pubDate == null) {
                            item.pubDate = cleaned;
                            item.timestamp = parseDateString(cleaned) catch 0;
                        }
                    },
                    .Guid, .Id => item.guid = cleaned,
                    else => {},
                }
            } else {
                // Feed metadata
                if (ctx.current_tag == .Title) ctx.feed.title = cleaned;
                if (ctx.current_tag == .Description) ctx.feed.description = cleaned;
                if (ctx.current_tag == .Link) {
                    if (ctx.feed.link == null) ctx.feed.link = cleaned;
                }
                if (ctx.current_tag == .Language) ctx.feed.language = cleaned;
                if (ctx.current_tag == .Generator) ctx.feed.generator = cleaned;
                if (ctx.current_tag == .PubDate or ctx.current_tag == .Updated) ctx.feed.lastBuildDate = cleaned;
                if (ctx.current_tag == .AuthorName) ctx.feed.author_name = cleaned;
                if (ctx.current_tag == .AuthorUri) ctx.feed.author_uri = cleaned;
            }

            ctx.current_tag = .None;
        }

        ctx.tag_depth -= 1;
    }

    fn charDataHandler(user_data: ?*anyopaque, s: [*c]const u8, len: c_int) callconv(.c) void {
        if (user_data == null) return;
        const ptr = user_data.?;
        std.debug.assert(std.mem.isAligned(@intFromPtr(ptr), @alignOf(ParserContext)));
        var ctx: *ParserContext = @ptrCast(@alignCast(ptr));

        if (ctx.current_tag != .None) {
            const data = s[0..@intCast(len)];
            ctx.char_buffer.appendSlice(data) catch |err| {
                ctx.parse_error = err;
                return;
            };
        }
    }

    // --- HTML Cleaning ---

    /// Helper to extract value from href="value" or href='value'
    fn extractHref(tag_content: []const u8) ?[]const u8 {
        // Find "href=" (case insensitive check would be better, but simple is fast)
        const href_idx = std.mem.indexOf(u8, tag_content, "href=") orelse return null;

        // Start looking after href=
        var start = href_idx + 5;
        if (start >= tag_content.len) return null;

        // Determine quote style
        const quote = tag_content[start];
        if (quote == '"' or quote == '\'') {
            start += 1; // Skip opening quote
            // Find closing quote
            const end = std.mem.indexOfScalarPos(u8, tag_content, start, quote) orelse return null;
            return tag_content[start..end];
        }

        // Handle unquoted attributes (rare in valid HTML but possible)
        // Read until space or end of tag
        var end = start;
        while (end < tag_content.len and tag_content[end] != ' ' and tag_content[end] != '>') : (end += 1) {}
        return tag_content[start..end];
    }

    fn isControlChar(ch: u8) bool {
        return (ch <= 31) or (ch == 127);
    }

    /// Clean HTML, potentially in-place if buffer is owned and contains no links.
    /// Returns a slice (possibly shorter) of the input buffer or a new allocation if needed.
    pub fn cleanHtmlSimple(html: []const u8, allocator: std.mem.Allocator) ![]u8 {
        return cleanHtmlSimpleWithUnderline(html, allocator, true);
    }

    /// In-place variant: assumes you own the buffer and converts it to mutable.
    /// Only use when the buffer is guaranteed to be writable and owned by you.
    /// Returns a slice of the cleaned content within the same buffer (still const safe).
    pub fn cleanHtmlSimpleOwned(html_owned: []const u8) []const u8 {
        // Cast away const since we own the buffer from toOwnedSlice()
        var mutable = @constCast(html_owned);
        const new_len = cleanHtmlInPlace(mutable);
        return mutable[0..new_len];
    }

    /// In-place HTML cleaning: Uses read/write cursors on the same buffer.
    /// Skips HTML tags, decodes entities, collapses whitespace.
    /// Safe for any buffer since cleaned text is always <= input size.
    /// Returns the new length of the cleaned content.
    fn cleanHtmlInPlace(html: []u8) usize {
        var write_pos: usize = 0;
        var read_pos: usize = 0;
        var prev_was_space = true;

        while (read_pos < html.len) {
            // 1. Skip HTML tags entirely
            if (html[read_pos] == '<') {
                while (read_pos < html.len and html[read_pos] != '>') : (read_pos += 1) {}
                if (read_pos < html.len) read_pos += 1; // Skip '>'
                continue;
            }

            // 2. Handle HTML entities - convert in place
            if (html[read_pos] == '&') {
                const entity_result = decodeHtmlEntity(html, read_pos);
                if (entity_result.len > 0) {
                    for (entity_result.utf8_seq[0..entity_result.len]) |byte| {
                        if (!isControlChar(byte) or byte == '\n' or byte == '\t') {
                            if (isWhitespace(byte)) {
                                if (!prev_was_space) {
                                    html[write_pos] = ' ';
                                    write_pos += 1;
                                    prev_was_space = true;
                                }
                            } else {
                                html[write_pos] = byte;
                                write_pos += 1;
                                prev_was_space = false;
                            }
                        }
                    }
                    read_pos += entity_result.consumed;
                    continue;
                }
            }

            // 3. Handle regular text
            const char = html[read_pos];
            if (!isControlChar(char) or char == '\n' or char == '\t') {
                if (isWhitespace(char)) {
                    if (!prev_was_space) {
                        html[write_pos] = ' ';
                        write_pos += 1;
                        prev_was_space = true;
                    }
                } else {
                    html[write_pos] = char;
                    write_pos += 1;
                    prev_was_space = false;
                }
            }
            read_pos += 1;
        }

        // Trim trailing spaces
        while (write_pos > 0 and html[write_pos - 1] == ' ') : (write_pos -= 1) {}

        return write_pos;
    }

    pub fn cleanHtmlSimpleWithUnderline(html: []const u8, allocator: std.mem.Allocator, enable_underline: bool) ![]u8 {
        var output = std.array_list.Managed(u8).init(allocator);
        const initial_capacity = @max(html.len * 2, 512); // 2x for ANSI codes + entities
        try output.ensureTotalCapacity(initial_capacity);
        defer output.deinit();

        var prev_was_space = true;
        var i: usize = 0;

        while (i < html.len) {
            // 1. Handle HTML Tags
            if (html[i] == '<') {
                const start_tag = i;
                // Find end of tag
                while (i < html.len and html[i] != '>') : (i += 1) {}

                // If we found a complete tag
                if (i < html.len and html[i] == '>') {
                    const tag_content = html[start_tag + 1 .. i]; // Inside <...>

                    // CHECK FOR OPENING LINK: <a href="...">
                    if (std.mem.startsWith(u8, tag_content, "a ") or std.mem.eql(u8, tag_content, "a")) {
                        if (extractHref(tag_content)) |url| {
                            // Emit ANSI Hyperlink Start: \x1b]8;;{url}\x1b\\
                            try output.appendSlice("\x1b]8;;");

                            // Sanitize URL: replace spaces with %20 to prevent tokenization splits
                            for (url) |ch| {
                                if (ch == ' ') {
                                    try output.appendSlice("%20");
                                } else if (ch == '\t' or ch == '\n' or ch == '\r') {
                                    // Skip other whitespace
                                } else {
                                    try output.append(ch);
                                }
                            }
                            try output.appendSlice("\x1b\\");

                            // Emit ANSI Underline Start: \x1b[4m (only if enabled)
                            if (enable_underline) {
                                try output.appendSlice("\x1b[4m");
                            }
                        }
                    }
                    // CHECK FOR CLOSING LINK: </a>
                    else if (std.mem.startsWith(u8, tag_content, "/a")) {
                        // Emit ANSI Underline End: \x1b[24m (only if enabled)
                        if (enable_underline) {
                            try output.appendSlice("\x1b[24m");
                        }

                        // Emit ANSI Hyperlink End: \x1b]8;;\x1b\\
                        try output.appendSlice("\x1b]8;;\x1b\\");
                    }

                    // Advance past the '>'
                    i += 1;

                    // Reset spacing logic so we don't accidentally merge words around tags
                    // unless the tag was block-level (simplified here)
                    continue;
                }

                // If tag wasn't closed properly, reset and treat as text
                i = start_tag;
            }

            // 2. Handle HTML Entities (Same as original)
            if (html[i] == '&') {
                const entity_result = decodeHtmlEntity(html, i);
                if (entity_result.len > 0) {
                    for (entity_result.utf8_seq[0..entity_result.len]) |byte| {
                        if (!isControlChar(byte) or byte == '\n' or byte == '\t') {
                            if (isWhitespace(byte)) {
                                if (!prev_was_space) {
                                    try output.append(' ');
                                    prev_was_space = true;
                                }
                            } else {
                                try output.append(byte);
                                prev_was_space = false;
                            }
                        }
                    }
                    i += entity_result.consumed;
                    continue;
                }
            }

            // 3. Handle Regular Text (Same as original)
            const char = html[i];
            if (!isControlChar(char) or char == '\n' or char == '\t') {
                if (isWhitespace(char)) {
                    if (!prev_was_space) {
                        try output.append(' ');
                        prev_was_space = true;
                    }
                } else {
                    try output.append(char);
                    prev_was_space = false;
                }
            }
            i += 1;
        }

        const result = try output.toOwnedSlice();
        const trimmed_slice = std.mem.trim(u8, result, " ");

        if (trimmed_slice.ptr == result.ptr and trimmed_slice.len == result.len) {
            return result;
        }

        const trimmed = try allocator.dupe(u8, trimmed_slice);
        allocator.free(result);
        return trimmed;
    }

    fn isWhitespace(byte: u8) bool {
        return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
    }

    /// Underline bare URLs (http:// or https://) in plain text
    /// Wraps URLs with \x1b[4m (underline) and \x1b[24m (no underline)
    /// Skips over ANSI escape sequences to avoid processing text that already has them
    pub fn underlineBareUrls(text: []const u8, allocator: std.mem.Allocator) ![]u8 {
        var output = std.array_list.Managed(u8).init(allocator);
        try output.ensureTotalCapacity(@max(text.len * 2, 256));
        defer output.deinit();

        var pos: usize = 0;
        while (pos < text.len) {
            // Find next escape sequence
            if (std.mem.indexOfScalar(u8, text[pos..], '\x1b')) |offset| {
                const esc_start = pos + offset;
                // Append text before the escape
                try output.appendSlice(text[pos..esc_start]);
                // Copy the escape sequence
                try output.append('\x1b');
                pos = esc_start + 1;
                // Find end of sequence
                while (pos < text.len) {
                    const ch = text[pos];
                    try output.append(ch);
                    pos += 1;
                    // Check for end of sequence
                    if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z')) break;
                    if (ch == '\\') break;
                    if (ch == 0x07) break;
                }
                continue;
            }

            // Find next https://
            if (std.mem.indexOf(u8, text[pos..], "https://")) |offset| {
                const url_start = pos + offset;
                // Append text before the URL
                try output.appendSlice(text[pos..url_start]);
                // Find end of URL
                var end = url_start + 8;
                while (end < text.len and !isWhitespace(text[end]) and text[end] != '\x1b') : (end += 1) {}
                // Emit underline codes and URL
                try output.appendSlice("\x1b[4m");
                try output.appendSlice(text[url_start..end]);
                try output.appendSlice("\x1b[24m");
                pos = end;
                continue;
            }

            // Find next http://
            if (std.mem.indexOf(u8, text[pos..], "http://")) |offset| {
                const url_start = pos + offset;
                // Append text before the URL
                try output.appendSlice(text[pos..url_start]);
                // Find end of URL
                var end = url_start + 7;
                while (end < text.len and !isWhitespace(text[end]) and text[end] != '\x1b') : (end += 1) {}
                // Emit underline codes and URL
                try output.appendSlice("\x1b[4m");
                try output.appendSlice(text[url_start..end]);
                try output.appendSlice("\x1b[24m");
                pos = end;
                continue;
            }

            // No more special sequences, append the rest
            try output.appendSlice(text[pos..]);
            break;
        }

        return output.toOwnedSlice();
    }

    pub fn sanitizeFeedData(input: []const u8, allocator: std.mem.Allocator) ![]u8 {
        var output = std.array_list.Managed(u8).init(allocator);
        defer output.deinit();

        for (input) |char| {
            // Only strip control characters (0-31) and ESC (0x1B) to prevent escape sequence injection
            if (char >= 32 and char != 0x1B) {
                try output.append(char);
            }
        }

        return output.toOwnedSlice();
    }

    const EntityDecodeResult = struct {
        utf8_seq: [4]u8,
        len: u8,
        consumed: usize,
    };

    fn decodeHtmlEntity(html: []const u8, pos: usize) EntityDecodeResult {
        if (pos >= html.len or html[pos] != '&') {
            return EntityDecodeResult{ .utf8_seq = undefined, .len = 0, .consumed = 1 };
        }

        if (pos + 3 < html.len and html[pos + 1] == '#') {
            var i = pos + 2;
            var code_point: u32 = 0;
            var is_hex = false;

            if (html[i] == 'x' or html[i] == 'X') {
                is_hex = true;
                i += 1;
            }

            var found_digit = false;
            while (i < html.len and html[i] != ';') {
                const char = html[i];
                if (is_hex) {
                    if (char >= '0' and char <= '9') {
                        code_point = code_point * 16 + (char - '0');
                        found_digit = true;
                    } else if (char >= 'a' and char <= 'f') {
                        code_point = code_point * 16 + (char - 'a' + 10);
                        found_digit = true;
                    } else if (char >= 'A' and char <= 'F') {
                        code_point = code_point * 16 + (char - 'A' + 10);
                        found_digit = true;
                    } else {
                        break;
                    }
                } else {
                    if (char >= '0' and char <= '9') {
                        code_point = code_point * 10 + (char - '0');
                        found_digit = true;
                    } else {
                        break;
                    }
                }
                i += 1;
            }

            if (found_digit and i < html.len and html[i] == ';') {
                if (code_point <= 0x10FFFF) {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(@as(u21, @intCast(code_point)), &buf) catch 0;
                    if (len > 0) {
                        return EntityDecodeResult{ .utf8_seq = buf, .len = @intCast(len), .consumed = i - pos + 1 };
                    }
                }
            }
        }

        var i = pos + 1;
        const max_len = @min(pos + 32, html.len);

        while (i < max_len) {
            const char = html[i];

            if (char == ';') {
                const entity_name = html[pos + 1 .. i];

                if (RssReader.html_entities.get(entity_name)) |val| {
                    var buf: [4]u8 = undefined;
                    if (val.len <= 4) {
                        @memcpy(buf[0..val.len], val);
                        return EntityDecodeResult{ .utf8_seq = buf, .len = @intCast(val.len), .consumed = i - pos + 1 };
                    }
                }
                break;
            }

            if (!((char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or (char >= '0' and char <= '9'))) {
                break;
            }

            i += 1;
        }

        return EntityDecodeResult{ .utf8_seq = undefined, .len = 0, .consumed = 1 };
    }

    // --- Helpers ---

    fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }

    // --- Date Parsing ---
    pub const DateParseError = error{
        /// Date string is empty or null
        EmptyDate,
        /// ISO8601 parsing failed
        InvalidIso8601,
        /// RFC822 parsing failed (invalid format)
        InvalidRfc822,
    };

    pub fn parseDateString(date_str: []const u8) DateParseError!i64 {
        if (date_str.len == 0) return error.EmptyDate;

        // Trim whitespace
        const trimmed = std.mem.trim(u8, date_str, " \t\n\r");

        // Step 1: Try RFC3339 (ISO 8601 with timezone) - Modern Atom feeds
        if (zdt.Datetime.fromISO8601(trimmed)) |dt| {
            return dt.unix_sec;
        } else |_| {}

        // Step 2: Try library RFC822/1123 parser - Strict RSS feeds

        // Step 3: Try manual "Dirty" RFC822 parser - Handles non-compliant feeds
        if (parseRfc822(trimmed)) |ts| {
            return ts;
        } else |_| {}

        // Step 4: Try loose ISO 8601 parse - Last resort fallback
        // Handles variations without T separator or other non-standard formats
        if (parseLooseIso8601(trimmed)) |ts| {
            return ts;
        } else |_| {}

        // All parsing attempts failed
        return error.InvalidRfc822;
    }

    fn parseRfc822(date_str: []const u8) DateParseError!i64 {
        // Try parsing with zdt
        var it = std.mem.tokenizeAny(u8, date_str, " ,\t");
        var part = it.next() orelse return error.InvalidRfc822;

        // Skip day name if present (e.g., "Wed")
        if (!std.ascii.isDigit(part[0])) {
            part = it.next() orelse return error.InvalidRfc822;
        }

        const day = std.fmt.parseInt(u8, part, 10) catch return error.InvalidRfc822;
        const month_str = it.next() orelse return error.InvalidRfc822;
        const month: u8 = monthStrToInt(month_str) catch return error.InvalidRfc822;
        const year_str = it.next() orelse return error.InvalidRfc822;
        const year = std.fmt.parseInt(i16, year_str, 10) catch return error.InvalidRfc822;
        const time_str = it.next() orelse return error.InvalidRfc822;

        var time_it = std.mem.splitSequence(u8, time_str, ":");
        const hour = std.fmt.parseInt(u8, time_it.next() orelse "0", 10) catch 0;
        const minute = std.fmt.parseInt(u8, time_it.next() orelse "0", 10) catch 0;
        const second = std.fmt.parseInt(u8, time_it.next() orelse "0", 10) catch 0;

        // Create zdt Datetime and get timestamp
        const dt = zdt.Datetime.fromFields(.{
            .year = year,
            .month = month,
            .day = day,
            .hour = hour,
            .minute = minute,
            .second = second,
        }) catch return error.InvalidRfc822;

        // Parse timezone offset
        var offset_seconds: i64 = 0;
        if (it.next()) |zone| {
            offset_seconds = parseTimezoneOffset(zone);
        }

        // Convert to UTC timestamp
        return dt.unix_sec - offset_seconds;
    }

    fn parseLooseIso8601(date_str: []const u8) DateParseError!i64 {
        // Try variations of ISO 8601 without requiring T separator
        // This is a fallback for feeds with non-standard formats
        _ = date_str;
        return error.InvalidIso8601;
    }

    fn monthStrToInt(month: []const u8) !u8 {
        const month_map = comptime std.StaticStringMap(u8).initComptime(.{
            .{ "Jan", 1 },  .{ "Feb", 2 },  .{ "Mar", 3 },
            .{ "Apr", 4 },  .{ "May", 5 },  .{ "Jun", 6 },
            .{ "Jul", 7 },  .{ "Aug", 8 },  .{ "Sep", 9 },
            .{ "Oct", 10 }, .{ "Nov", 11 }, .{ "Dec", 12 },
        });
        return month_map.get(month) orelse error.InvalidMonth;
    }

    fn parseTimezoneOffset(zone: []const u8) i64 {
        if (zone.len == 0) return 0;
        if (zone[0] == '+' or zone[0] == '-') {
            const sign: i64 = if (zone[0] == '+') 1 else -1;
            var rest = zone[1..];
            if (rest.len >= 5 and rest[2] == ':') {
                const hh = std.fmt.parseInt(i64, rest[0..2], 10) catch return 0;
                const mm = std.fmt.parseInt(i64, rest[3..5], 10) catch return 0;
                return sign * ((hh * 3600) + (mm * 60));
            }
            if (rest.len >= 4) {
                const hh = std.fmt.parseInt(i64, rest[0..2], 10) catch return 0;
                const mm = std.fmt.parseInt(i64, rest[2..4], 10) catch return 0;
                return sign * ((hh * 3600) + (mm * 60));
            }
            return 0;
        }
        const tz_offsets = comptime std.StaticStringMap(i64).initComptime(.{
            .{ "GMT", 0 },         .{ "UTC", 0 },
            .{ "EST", -5 * 3600 }, .{ "EDT", -4 * 3600 },
            .{ "CST", -6 * 3600 }, .{ "CDT", -5 * 3600 },
            .{ "MST", -7 * 3600 }, .{ "MDT", -6 * 3600 },
            .{ "PST", -8 * 3600 }, .{ "PDT", -7 * 3600 },
        });
        return tz_offsets.get(zone) orelse 0;
    }

    fn fetchFeed(self: *RssReader, url: []const u8) RssReaderError![]u8 {
        return self.fetchWithLibcurl(url);
    }

    const CurlWriteContext = struct {
        buffer: *std.array_list.Managed(u8),
        max_bytes: usize,
        exceeded_limit: bool,
        content_type: ?[]const u8 = null,
        content_type_buffer: *std.array_list.Managed(u8),
    };

    fn curlHeaderCallback(data: [*c]const u8, size: usize, nmemb: usize, user_data: ?*anyopaque) callconv(.c) usize {
        if (user_data == null) return size * nmemb;
        const ptr = user_data.?;
        std.debug.assert(std.mem.isAligned(@intFromPtr(ptr), @alignOf(CurlWriteContext)));
        const ctx: *CurlWriteContext = @ptrCast(@alignCast(ptr));
        const total_size: usize = size * nmemb;
        const line = data[0..total_size];
        
        // Look for Content-Type header
        if (std.ascii.startsWithIgnoreCase(line, "content-type:")) {
            const trimmed = std.mem.trim(u8, line, " \r\n\t");
            if (std.mem.indexOf(u8, trimmed, ":")) |colon_idx| {
                const ct_value = std.mem.trim(u8, trimmed[colon_idx + 1..], " ");
                ctx.content_type_buffer.clearRetainingCapacity();
                ctx.content_type_buffer.appendSlice(ct_value) catch {};
                ctx.content_type = ctx.content_type_buffer.items;
            }
        }
        
        return total_size;
    }

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

    fn fetchWithLibcurl(self: *RssReader, url: []const u8) RssReaderError![]u8 {
        const allocator = self.allocator;
        const max_bytes: usize = @intFromFloat(self.max_feed_size_mb * 1024 * 1024);

        const url_z = allocator.allocSentinel(u8, url.len, 0) catch return RssReaderError.OutOfMemory;
        defer allocator.free(url_z);
        @memcpy(url_z, url);

        const handle = curl.curl_easy_init() orelse return RssReaderError.CurlFailed;
        defer curl.curl_easy_cleanup(handle);

        var response_buffer = std.array_list.Managed(u8).init(allocator);
        defer response_buffer.deinit();
        
        var content_type_buffer = std.array_list.Managed(u8).init(allocator);
        defer content_type_buffer.deinit();

        var write_ctx = CurlWriteContext{
            .buffer = &response_buffer,
            .max_bytes = max_bytes,
            .exceeded_limit = false,
            .content_type_buffer = &content_type_buffer,
        };

        const setup_ok = blk: {
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_URL, url_z.ptr) != curl.CURLE_OK) break :blk false;
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEFUNCTION, @as(curl.curl_write_callback, @ptrCast(&curlWriteCallback))) != curl.CURLE_OK) break :blk false;
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&write_ctx))) != curl.CURLE_OK) break :blk false;
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_HEADERFUNCTION, @as(curl.curl_write_callback, @ptrCast(&curlHeaderCallback))) != curl.CURLE_OK) break :blk false;
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_HEADERDATA, @as(*anyopaque, @ptrCast(&write_ctx))) != curl.CURLE_OK) break :blk false;
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)) != curl.CURLE_OK) break :blk false;
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_MAXREDIRS, @as(c_long, 10)) != curl.CURLE_OK) break :blk false;
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_CONNECTTIMEOUT, @as(c_long, 5)) != curl.CURLE_OK) break :blk false;
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_TIMEOUT, @as(c_long, 30)) != curl.CURLE_OK) break :blk false;
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_ACCEPT_ENCODING, "") != curl.CURLE_OK) break :blk false;
            if (curl.curl_easy_setopt(handle, curl.CURLOPT_USERAGENT, "hys-rss/0.1.0") != curl.CURLE_OK) break :blk false;
            break :blk true;
        };

        if (!setup_ok) {
            return RssReaderError.CurlFailed;
        }

        const result = curl.curl_easy_perform(handle);

        if (result != curl.CURLE_OK) {
            if (result == curl.CURLE_WRITE_ERROR and write_ctx.exceeded_limit and response_buffer.items.len > 0) {
                // Expected abort
            } else {
                return RssReaderError.NetworkError;
            }
        }

        var http_code: c_long = 0;
        _ = curl.curl_easy_getinfo(handle, curl.CURLINFO_RESPONSE_CODE, &http_code);
        if (http_code >= 400) {
            return RssReaderError.HttpError;
        }

        if (response_buffer.items.len == 0) {
            return RssReaderError.NetworkError;
        }

        // Validate content-type if available
        if (write_ctx.content_type) |ct| {
            if (!isValidRssContentType(ct)) {
                return RssReaderError.HttpError;
            }
        }

        const content = response_buffer.toOwnedSlice() catch {
            return RssReaderError.OutOfMemory;
        };
        errdefer allocator.free(content);

        return self.truncateAtLastCompleteItem(content);
    }

    /// Check if content-type header indicates a feed format
    fn isValidRssContentType(content_type: []const u8) bool {
        // Convert to lowercase for comparison
        const lower = std.ascii.toLower;
        var ct_lower: [256]u8 = undefined;
        if (content_type.len > 255) return false;
        for (content_type, 0..) |byte, i| {
            ct_lower[i] = lower(byte);
        }
        const ct_check = ct_lower[0..content_type.len];
        
        // Valid content types for RSS/Atom feeds
        return std.mem.startsWith(u8, ct_check, "application/rss") or
               std.mem.startsWith(u8, ct_check, "application/atom") or
               std.mem.startsWith(u8, ct_check, "application/xml") or
               std.mem.startsWith(u8, ct_check, "application/json") or // JSON Feed
               std.mem.startsWith(u8, ct_check, "text/xml") or
               std.mem.startsWith(u8, ct_check, "text/rss") or
               std.mem.startsWith(u8, ct_check, "text/atom");
    }

    fn truncateAtLastCompleteItem(self: *RssReader, content: []u8) RssReaderError![]u8 {
        var final_size = content.len;
        const item_idx = std.mem.lastIndexOf(u8, content, "</item>");
        const entry_idx = std.mem.lastIndexOf(u8, content, "</entry>");

        if (item_idx) |idx| final_size = idx + 7;
        if (entry_idx) |idx| {
            const entry_end = idx + 8;
            if (final_size == content.len or entry_end > final_size) final_size = entry_end;
        }

        if (final_size < content.len) {
            if (self.allocator.resize(content, final_size)) {
                return content[0..final_size];
            }
            const trimmed = self.allocator.alloc(u8, final_size) catch {
                self.allocator.free(content);
                return RssReaderError.OutOfMemory;
            };
            @memcpy(trimmed, content[0..final_size]);
            self.allocator.free(content);
            return trimmed;
        }
        return content;
    }
};

// ============================================================================
// UNIT TESTS
// ============================================================================

test "parseDateString handles RFC 822 formats" {
    // Standard RFC 822 with GMT
    const gmt_ts = try RssReader.parseDateString("Wed, 02 Oct 2024 15:30:00 GMT");
    try std.testing.expect(gmt_ts > 0);

    // RFC 822 with timezone offset
    const utc_ts = try RssReader.parseDateString("Wed, 02 Oct 2024 15:30:00 UTC");
    try std.testing.expectEqual(gmt_ts, utc_ts);

    // RFC 822 with EST timezone
    const est_ts = try RssReader.parseDateString("Wed, 02 Oct 2024 10:30:00 EST");
    // EST is -5 hours from UTC, so 10:30 EST = 15:30 UTC
    try std.testing.expectEqual(gmt_ts, est_ts);

    // RFC 822 with numeric offset +0000
    const plus0_ts = try RssReader.parseDateString("Wed, 02 Oct 2024 15:30:00 +0000");
    try std.testing.expectEqual(gmt_ts, plus0_ts);
}

test "parseDateString handles ISO 8601 formats" {
    // ISO 8601 with Z suffix
    const iso_z = try RssReader.parseDateString("2024-10-02T15:30:00Z");
    try std.testing.expect(iso_z > 0);

    // ISO 8601 with positive offset
    const iso_plus = try RssReader.parseDateString("2024-10-02T17:30:00+02:00");
    try std.testing.expectEqual(iso_z, iso_plus);

    // ISO 8601 with negative offset
    const iso_minus = try RssReader.parseDateString("2024-10-02T10:30:00-05:00");
    try std.testing.expectEqual(iso_z, iso_minus);
}

test "parseDateString returns error for empty/malformed dates" {
    // Empty string
    try std.testing.expectError(error.EmptyDate, RssReader.parseDateString(""));

    // Completely invalid
    try std.testing.expectError(error.InvalidRfc822, RssReader.parseDateString("not a date"));
    try std.testing.expectError(error.InvalidRfc822, RssReader.parseDateString("abc"));
}

test "validateFeedUrl accepts valid URLs" {
    // HTTPS URLs
    try validateFeedUrl("https://example.com/feed.xml");
    try validateFeedUrl("https://subdomain.example.com/rss");

    // HTTP URLs
    try validateFeedUrl("http://example.com/feed.xml");

    // File URLs
    try validateFeedUrl("file:///Users/test/feed.xml");
}

test "validateFeedUrl rejects invalid URLs" {
    // Missing scheme
    try std.testing.expectError(error.InvalidUrl, validateFeedUrl("example.com/feed"));

    // Invalid scheme
    try std.testing.expectError(error.InvalidUrl, validateFeedUrl("ftp://example.com"));

    // URL with spaces
    try std.testing.expectError(error.InvalidUrl, validateFeedUrl("https://example.com/feed rss"));

    // Empty URL
    try std.testing.expectError(error.InvalidUrl, validateFeedUrl(""));

    // Too short URLs
    try std.testing.expectError(error.InvalidUrl, validateFeedUrl("http://"));
    try std.testing.expectError(error.InvalidUrl, validateFeedUrl("https://"));
}

test "cleanHtmlSimple removes HTML tags" {
    const allocator = std.testing.allocator;

    const result1 = try RssReader.cleanHtmlSimple("<p>Hello <b>World</b></p>", allocator);
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("Hello World", result1);

    const result2 = try RssReader.cleanHtmlSimple("<div><span>Nested</span> text</div>", allocator);
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("Nested text", result2);
}

test "cleanHtmlSimple collapses whitespace" {
    const allocator = std.testing.allocator;

    const result = try RssReader.cleanHtmlSimple("Multiple    spaces   here", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Multiple spaces here", result);

    const result2 = try RssReader.cleanHtmlSimple("\n\n  Newlines  \n  and spaces  \n", allocator);
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("Newlines and spaces", result2);
}

test "cleanHtmlSimple decodes HTML entities" {
    const allocator = std.testing.allocator;

    const result1 = try RssReader.cleanHtmlSimple("Test &amp; more", allocator);
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("Test & more", result1);

    const result2 = try RssReader.cleanHtmlSimple("&lt;tag&gt;", allocator);
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("<tag>", result2);

    const result3 = try RssReader.cleanHtmlSimple("&quot;quoted&quot;", allocator);
    defer allocator.free(result3);
    try std.testing.expectEqualStrings("\"quoted\"", result3);
}

test "cleanHtmlSimple decodes numeric entities" {
    const allocator = std.testing.allocator;

    // Decimal numeric entity (right single quote)
    const result1 = try RssReader.cleanHtmlSimple("It&#8217;s working", allocator);
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("It's working", result1);

    // Hex numeric entity
    const result2 = try RssReader.cleanHtmlSimple("Dash &#x2014; here", allocator);
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("Dash — here", result2);

    // En-dash
    const result3 = try RssReader.cleanHtmlSimple("Range: 1&#8211;10", allocator);
    defer allocator.free(result3);
    try std.testing.expectEqualStrings("Range: 1–10", result3);
}

test "decodeHtmlEntity handles named entities" {
    // Test amp
    const amp_result = RssReader.decodeHtmlEntity("&amp;", 0);
    try std.testing.expectEqual(@as(u8, 1), amp_result.len);
    try std.testing.expectEqual(@as(u8, '&'), amp_result.utf8_seq[0]);
    try std.testing.expectEqual(@as(usize, 5), amp_result.consumed);

    // Test lt
    const lt_result = RssReader.decodeHtmlEntity("&lt;", 0);
    try std.testing.expectEqual(@as(u8, 1), lt_result.len);
    try std.testing.expectEqual(@as(u8, '<'), lt_result.utf8_seq[0]);

    // Test gt
    const gt_result = RssReader.decodeHtmlEntity("&gt;", 0);
    try std.testing.expectEqual(@as(u8, 1), gt_result.len);
    try std.testing.expectEqual(@as(u8, '>'), gt_result.utf8_seq[0]);
}

test "decodeHtmlEntity handles decimal numeric entities" {
    // ASCII character (A = 65)
    const ascii_result = RssReader.decodeHtmlEntity("&#65;", 0);
    try std.testing.expectEqual(@as(u8, 1), ascii_result.len);
    try std.testing.expectEqual(@as(u8, 'A'), ascii_result.utf8_seq[0]);

    // Right single quote (8217 = U+2019)
    const quote_result = RssReader.decodeHtmlEntity("&#8217;", 0);
    try std.testing.expect(quote_result.len >= 1);
    try std.testing.expectEqual(@as(usize, 7), quote_result.consumed);
}

test "decodeHtmlEntity handles hex numeric entities" {
    // Hex entity (A = 0x41)
    const hex_result = RssReader.decodeHtmlEntity("&#x41;", 0);
    try std.testing.expectEqual(@as(u8, 1), hex_result.len);
    try std.testing.expectEqual(@as(u8, 'A'), hex_result.utf8_seq[0]);

    // M-dash (0x2014)
    const mdash_result = RssReader.decodeHtmlEntity("&#x2014;", 0);
    try std.testing.expect(mdash_result.len >= 1);
}

test "decodeHtmlEntity returns zero length for unknown entities" {
    const unknown = RssReader.decodeHtmlEntity("&unknown;", 0);
    try std.testing.expectEqual(@as(u8, 0), unknown.len);

    // Unclosed entity
    const unclosed = RssReader.decodeHtmlEntity("&amp text", 0);
    try std.testing.expectEqual(@as(u8, 0), unclosed.len);
}

test "sanitizeFeedData removes control characters" {
    const allocator = std.testing.allocator;

    // Escape sequence (0x1B)
    const input = "Normal\x1B[31mRed\x1B[0mText";
    const result = try RssReader.sanitizeFeedData(input, allocator);
    defer allocator.free(result);

    // Should not contain escape character
    for (result) |ch| {
        try std.testing.expect(ch != 0x1B);
    }
}

test "normalizeFeedUrl handles feed:// scheme" {
    const allocator = std.testing.allocator;

    const result = try RssReader.normalizeFeedUrl(allocator, "feed://example.com/rss");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("http://example.com/rss", result);
}

test "normalizeFeedUrl preserves http:// and https://" {
    const allocator = std.testing.allocator;

    const http_result = try RssReader.normalizeFeedUrl(allocator, "http://example.com/feed");
    defer allocator.free(http_result);
    try std.testing.expectEqualStrings("http://example.com/feed", http_result);

    const https_result = try RssReader.normalizeFeedUrl(allocator, "https://example.com/feed");
    defer allocator.free(https_result);
    try std.testing.expectEqualStrings("https://example.com/feed", https_result);
}

test "eqlIgnoreCase works correctly" {
    try std.testing.expect(RssReader.eqlIgnoreCase("title", "TITLE"));
    try std.testing.expect(RssReader.eqlIgnoreCase("PubDate", "pubdate"));
    try std.testing.expect(RssReader.eqlIgnoreCase("GUID", "guid"));
    try std.testing.expect(!RssReader.eqlIgnoreCase("title", "description"));
}

test "RssReader parseXml handles minimal RSS" {
    const allocator = std.testing.allocator;
    var reader = RssReader.init(allocator);
    defer reader.deinit();

    const xml =
        \\<?xml version="1.0"?>
        \\<rss version="2.0"><channel>
        \\<title>Test Feed</title>
        \\<item>
        \\<title>Test Item</title>
        \\<link>https://example.com/1</link>
        \\<guid>item-1</guid>
        \\</item>
        \\</channel></rss>
    ;

    var parsed = try reader.parseXml(xml, null, null);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Test Feed", parsed.title.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.items.len);
    try std.testing.expectEqualStrings("Test Item", parsed.items[0].title.?);
    try std.testing.expectEqualStrings("https://example.com/1", parsed.items[0].link.?);
    try std.testing.expectEqualStrings("item-1", parsed.items[0].guid.?);
}

test "RssReader parseXml handles Atom feed" {
    const allocator = std.testing.allocator;
    var reader = RssReader.init(allocator);
    defer reader.deinit();

    const xml =
        \\<?xml version="1.0"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\<title>Atom Feed</title>
        \\<entry>
        \\<title>Atom Entry</title>
        \\<link href="https://example.com/entry1"/>
        \\<id>tag:example.com,2024:entry1</id>
        \\<updated>2024-10-02T12:00:00Z</updated>
        \\<summary>Entry summary</summary>
        \\</entry>
        \\</feed>
    ;

    var parsed = try reader.parseXml(xml, null, null);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Atom Feed", parsed.title.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.items.len);
    try std.testing.expectEqualStrings("Atom Entry", parsed.items[0].title.?);
    try std.testing.expectEqualStrings("https://example.com/entry1", parsed.items[0].link.?);
}

test "RssReader parseXml handles large dynamically generated feed" {
    const allocator = std.testing.allocator;

    // Generate a large RSS feed at runtime (100 items)
    var feed_content = std.array_list.Managed(u8).init(allocator);
    defer feed_content.deinit();

    try feed_content.appendSlice(
        \\<?xml version="1.0"?>
        \\<rss version="2.0"><channel>
        \\<title>Large Dynamic Feed</title>
        \\
    );

    const item_count: usize = 100;
    var i: usize = 0;
    while (i < item_count) : (i += 1) {
        var buf: [256]u8 = undefined;
        const item = try std.fmt.bufPrint(&buf,
            \\<item>
            \\<title>Item {d}</title>
            \\<link>https://example.com/{d}</link>
            \\<guid>guid-{d}</guid>
            \\</item>
            \\
        , .{ i, i, i });
        try feed_content.appendSlice(item);
    }

    try feed_content.appendSlice(
        \\</channel></rss>
    );

    var reader = RssReader.init(allocator);
    defer reader.deinit();

    var parsed = try reader.parseXml(feed_content.items, null, null);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Large Dynamic Feed", parsed.title.?);
    try std.testing.expectEqual(item_count, parsed.items.len);

    // Verify first and last items
    try std.testing.expectEqualStrings("Item 0", parsed.items[0].title.?);
    try std.testing.expectEqualStrings("Item 99", parsed.items[99].title.?);
}

test "cleanHtmlSimple preserves links with OSC 8 hyperlinks" {
    const allocator = std.testing.allocator;

    // Test 1: Simple link
    const result1 = try RssReader.cleanHtmlSimple("<a href=\"https://example.com\">click here</a>", allocator);
    defer allocator.free(result1);

    // Should contain OSC 8 start, underline, text, underline end, OSC 8 end
    try std.testing.expect(std.mem.containsAtLeast(u8, result1, 1, "\x1b]8;;"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result1, 1, "https://example.com"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result1, 1, "\x1b[4m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result1, 1, "click here"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result1, 1, "\x1b[24m"));

    // Test 2: Link with single quotes
    const result2 = try RssReader.cleanHtmlSimple("<a href='https://test.com'>link</a>", allocator);
    defer allocator.free(result2);

    try std.testing.expect(std.mem.containsAtLeast(u8, result2, 1, "\x1b]8;;"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result2, 1, "https://test.com"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result2, 1, "link"));

    // Test 3: Text with link and other HTML
    const result3 = try RssReader.cleanHtmlSimple("Check <a href=\"https://example.com\">this</a> out", allocator);
    defer allocator.free(result3);

    try std.testing.expect(std.mem.containsAtLeast(u8, result3, 1, "Check"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result3, 1, "\x1b]8;;"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result3, 1, "this"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result3, 1, "out"));
}

test "underlineBareUrls underlines http and https URLs" {
    const allocator = std.testing.allocator;

    // Test 1: Single https URL
    const result1 = try RssReader.underlineBareUrls("Visit https://example.com today", allocator);
    defer allocator.free(result1);

    try std.testing.expect(std.mem.containsAtLeast(u8, result1, 1, "\x1b[4m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result1, 1, "https://example.com"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result1, 1, "\x1b[24m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result1, 1, "Visit"));

    // Test 2: Single http URL
    const result2 = try RssReader.underlineBareUrls("Go to http://test.org now", allocator);
    defer allocator.free(result2);

    try std.testing.expect(std.mem.containsAtLeast(u8, result2, 1, "\x1b[4m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result2, 1, "http://test.org"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result2, 1, "now"));

    // Test 3: Multiple URLs
    const result3 = try RssReader.underlineBareUrls("https://first.com and http://second.com", allocator);
    defer allocator.free(result3);

    try std.testing.expect(std.mem.containsAtLeast(u8, result3, 2, "\x1b[4m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result3, 1, "https://first.com"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result3, 1, "http://second.com"));

    // Test 4: Text without URLs
    const result4 = try RssReader.underlineBareUrls("Just plain text", allocator);
    defer allocator.free(result4);

    try std.testing.expectEqualStrings("Just plain text", result4);
}
