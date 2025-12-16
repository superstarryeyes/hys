const std = @import("std");
const builtin = @import("builtin");
const types = @import("types");
const config = @import("config");
const rss_reader = @import("rss_reader");

/// Get the display width (in terminal columns) of a Unicode code point
/// Handles CJK characters (width 2), combining marks (width 0), and most others (width 1)
pub fn getCodepointDisplayWidth(cp: u21) usize {
    if (cp == 0) return 0;

    // Fast path for ASCII
    if (cp < 0x7F) return 1;

    // Combining marks (simplified check) - these take 0 width
    if (cp >= 0x300 and cp <= 0x36F) return 0;

    // CJK (Chinese/Japanese/Korean) ranges - these take 2 width
    if ((cp >= 0x1100 and cp <= 0x115F) or // Hangul Jamo
        (cp >= 0x2E80 and cp <= 0xA4CF) or // CJK Radicals through Yi Radicals
        (cp >= 0xAC00 and cp <= 0xD7A3) or // Hangul Syllables
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK Compatibility Ideographs
        (cp >= 0xFE10 and cp <= 0xFE19) or // Vertical forms
        (cp >= 0xFE30 and cp <= 0xFE6F) or // CJK Compatibility Forms
        (cp >= 0xFF00 and cp <= 0xFF60) or // Fullwidth Forms
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x20000 and cp <= 0x2FFFD) or
        (cp >= 0x30000 and cp <= 0x3FFFD))
    {
        return 2;
    }

    // Emojis (Simple heuristic: most high plane chars are wide)
    if (cp >= 0x1F300 and cp <= 0x1F64F) return 2; // Miscellaneous Symbols and Pictographs
    if (cp >= 0x1F900 and cp <= 0x1F9FF) return 2; // Supplemental Symbols and Pictographs

    // Default for Latin-1, Cyrillic, Greek, Hebrew, Arabic, etc.
    return 1;
}

pub const Formatter = struct {
    allocator: std.mem.Allocator,
    display_config: types.DisplayConfig,
    buffer: ?*std.array_list.Managed(u8) = null,
    terminal_width: usize = 80,
    pager_stdin: ?std.fs.File = null,
    writer: ?std.Io.Writer = null,

    pub fn init(allocator: std.mem.Allocator, display_config: types.DisplayConfig) Formatter {
        return Formatter{
            .allocator = allocator,
            .display_config = display_config,
            .terminal_width = getTerminalWidthUncached(),
        };
    }

    pub fn initDirect(allocator: std.mem.Allocator, display_config: types.DisplayConfig, writer: std.Io.Writer) Formatter {
        return Formatter{
            .allocator = allocator,
            .display_config = display_config,
            .terminal_width = getTerminalWidthUncached(),
            .writer = writer,
        };
    }

    pub fn initWithBuffer(allocator: std.mem.Allocator, display_config: types.DisplayConfig, buffer: *std.array_list.Managed(u8)) Formatter {
        return Formatter{
            .allocator = allocator,
            .display_config = display_config,
            .buffer = buffer,
            .terminal_width = getTerminalWidthUncached(),
        };
    }

    pub fn initWithPagerStdin(allocator: std.mem.Allocator, display_config: types.DisplayConfig, pager_stdin: ?std.fs.File) Formatter {
        return Formatter{
            .allocator = allocator,
            .display_config = display_config,
            .pager_stdin = pager_stdin,
            .terminal_width = getTerminalWidthUncached(),
        };
    }

    fn getTermWidth(self: *Formatter) usize {
        return self.terminal_width;
    }

    pub fn flush(self: *Formatter) !void {
        _ = self;
    }

    fn writeOutput(self: *Formatter, text: []const u8) void {
        if (self.pager_stdin) |stdin| {
            // Streaming mode: write directly to pager
            stdin.writeAll(text) catch |err| {
                if (err != error.BrokenPipe) {
                    if (self.writer) |w| {
                        @constCast(&w).writeAll(text) catch return;
                    } else {
                        std.fs.File.stdout().writeAll(text) catch return;
                    }
                }
                // If BrokenPipe (user quit less), just silently discard
            };
        } else if (self.buffer) |buf| {
            buf.appendSlice(text) catch {
                if (self.writer) |w| {
                    @constCast(&w).writeAll(text) catch return;
                } else {
                    std.fs.File.stdout().writeAll(text) catch return;
                }
            };
        } else if (self.writer) |w| {
            // Use the stored writer interface
            @constCast(&w).writeAll(text) catch return;
        } else {
            // Fallback only if no writer provided (shouldn't happen with correct init)
            std.fs.File.stdout().writeAll(text) catch return;
        }
    }

    fn writef(self: *Formatter, comptime fmt: []const u8, args: anytype) void {
        if (self.pager_stdin) |stdin| {
            // Streaming mode: format and write directly to pager
            const formatted = std.fmt.allocPrint(self.allocator, fmt, args) catch {
                std.debug.print(fmt, args);
                return;
            };
            defer self.allocator.free(formatted);

            stdin.writeAll(formatted) catch |err| {
                if (err != error.BrokenPipe) {
                    if (self.writer) |w| {
                        {
                            const formatted_writer = std.fmt.allocPrint(self.allocator, fmt, args) catch {
                                std.debug.print(fmt, args);
                                return;
                            };
                            defer self.allocator.free(formatted_writer);
                            @constCast(&w).writeAll(formatted_writer) catch {
                                std.debug.print(fmt, args);
                            };
                        }
                    } else {
                        std.debug.print(fmt, args);
                    }
                }
                // If BrokenPipe (user quit less), just silently discard
            };
        } else if (self.buffer) |buf| {
            std.fmt.format(buf.writer(), fmt, args) catch {
                // Fallback to debug print if buffer write fails
                if (self.writer) |w| {
                    {
                        const formatted_writer = std.fmt.allocPrint(self.allocator, fmt, args) catch {
                            std.debug.print(fmt, args);
                            return;
                        };
                        defer self.allocator.free(formatted_writer);
                        @constCast(&w).writeAll(formatted_writer) catch {
                            std.debug.print(fmt, args);
                        };
                    }
                } else {
                    std.debug.print(fmt, args);
                }
            };
        } else if (self.writer) |w| {
            // Use the stored writer interface
            {
                const formatted_writer = std.fmt.allocPrint(self.allocator, fmt, args) catch {
                    std.debug.print(fmt, args);
                    return;
                };
                defer self.allocator.free(formatted_writer);
                @constCast(&w).writeAll(formatted_writer) catch {
                    std.debug.print(fmt, args);
                };
            }
        } else {
            std.debug.print(fmt, args);
        }
    }

    /// Get the current terminal width without caching, with fallback to 80 if detection fails
    fn getTerminalWidthUncached() usize {
        // 1) Environment variable first (works across OSes)
        if (std.posix.getenv("COLUMNS")) |cols_str| {
            if (std.fmt.parseInt(usize, cols_str, 10) catch null) |cols| {
                if (cols > 10 and cols < 1000) return cols;
            }
        }

        // 2) Windows implementation using GetConsoleScreenBufferInfo
        if (builtin.os.tag == .windows) {
            const w = std.os.windows;
            const handle = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE) orelse return 80;
            var info: w.CONSOLE_SCREEN_BUFFER_INFO = undefined;
            if (w.kernel32.GetConsoleScreenBufferInfo(handle, &info) != 0) {
                const width: i16 = info.srWindow.Right - info.srWindow.Left + 1;
                if (width > 0) return @intCast(width);
            }
            return 80;
        }

        // 3) POSIX implementation using ioctl on stdout, then stderr as fallback
        const stdout = std.fs.File.stdout();
        if (std.posix.isatty(stdout.handle)) {
            var winsize: std.posix.winsize = undefined;
            const result = std.posix.system.ioctl(stdout.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
            if (result == 0 and winsize.col > 0) {
                return @intCast(winsize.col);
            }
        } else {
            const stderr = std.fs.File.stderr();
            if (std.posix.isatty(stderr.handle)) {
                var winsize: std.posix.winsize = undefined;
                const result = std.posix.system.ioctl(stderr.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
                if (result == 0 and winsize.col > 0) {
                    return @intCast(winsize.col);
                }
            }
        }

        // 4) Default fallback: use 0 for piped output to indicate no wrapping
        return 0;
    }

    pub fn printHeader(self: *Formatter, title: []const u8) void {
        self.writeOutput("\n");
        self.writeOutput(config.COLORS.BOLD ++ config.COLORS.CYAN);
        const term_width = self.getTermWidth();
        for (0..term_width) |_| {
            self.writeOutput("═");
        }
        self.writeOutput(config.COLORS.RESET ++ "\n");
        self.writef("{s}  {s}{s}\n", .{ config.COLORS.BOLD ++ config.COLORS.CYAN, title, config.COLORS.RESET });
        self.writeOutput(config.COLORS.BOLD ++ config.COLORS.CYAN);
        for (0..term_width) |_| {
            self.writeOutput("═");
        }
        self.writeOutput(config.COLORS.RESET ++ "\n");
        self.writeOutput("\n");
    }

    pub fn printHysDigestHeader(self: *Formatter, group_name: []const u8, timestamp: i64) void {
        // Get relative or formatted date string
        const date_str = getRelativeOrFormattedDateWithAlloc(self.allocator, timestamp, self.display_config.dateFormat) catch "Unknown Date";
        defer if (date_str.ptr != "Unknown Date".ptr) self.allocator.free(date_str);

        self.writeOutput(config.COLORS.BOLD ++ config.COLORS.CYAN);
        const term_width = self.getTermWidth();
        for (0..term_width) |_| {
            self.writeOutput("═");
        }
        self.writeOutput(config.COLORS.RESET ++ "\n");

        // "  Hys Digest ({date_string}) – {group_name}"
        self.writef("{s}  Hys Digest ({s}) – {s}{s}\n", .{ config.COLORS.BOLD ++ config.COLORS.CYAN, date_str, group_name, config.COLORS.RESET });

        self.writeOutput(config.COLORS.BOLD ++ config.COLORS.CYAN);
        for (0..term_width) |_| {
            self.writeOutput("═");
        }
        self.writeOutput(config.COLORS.RESET ++ "\n");
        self.writeOutput("\n");
    }

    pub fn printGroupHeader(self: *Formatter, group_name: []const u8) void {
        // Use orange color for group headers
        const color = config.COLORS.ORANGE;
        const reset = config.COLORS.RESET;
        const bold = config.COLORS.BOLD;

        self.writeOutput("\n");
        self.writef("{s}{s}┌─ {s} ", .{ bold, color, group_name });

        const term_width = self.getTermWidth();
        const prefix_len = 3 + group_name.len + 1; // "┌─ " + name + " "
        const padding_len = if (prefix_len < term_width) term_width - prefix_len else 1;

        for (0..padding_len) |_| {
            self.writeOutput("─");
        }
        self.writeOutput(reset ++ "\n");
    }

    pub fn printFeedHeader(self: *Formatter, feed_name: []const u8, indent: usize) void {
        self.writeOutput("\n");

        const indent_spaces = indent * 2;
        for (0..indent_spaces) |_| {
            self.writeOutput(" ");
        }

        self.writef("{s}{s}┌─ {s} ", .{ config.COLORS.BOLD, config.COLORS.YELLOW, feed_name });

        // Calculate padding to fill the terminal width
        const term_width = self.getTermWidth();
        const prefix_len = indent_spaces + 3 + feed_name.len + 1;
        const padding_len = if (prefix_len < term_width) term_width - prefix_len else 1;

        for (0..padding_len) |_| {
            self.writeOutput("─");
        }
        self.writeOutput(config.COLORS.RESET ++ "\n");
        self.writeOutput("\n");
    }

    pub fn printFeedItems(self: *Formatter, items: []types.RssItem) void {
        if (items.len == 0) {
            self.writef("{s}  No items found in this feed{s}\n\n", .{ config.COLORS.YELLOW, config.COLORS.RESET });
            return;
        }

        // Create a single arena allocator for all items in this feed
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const items_to_show = if (self.display_config.maxItemsPerFeed > 0)
            @min(items.len, self.display_config.maxItemsPerFeed)
        else
            items.len;

        for (items[0..items_to_show], 0..) |item, i| {
            self.printFeedItemWithArena(item, i + 1, &arena);
            // Reset arena state after each item to reclaim memory while keeping allocator alive
            _ = arena.reset(std.heap.ArenaAllocator.ResetMode.retain_capacity);
        }
    }

    fn printFeedItemWithArena(self: *Formatter, item: types.RssItem, index: usize, arena: *std.heap.ArenaAllocator) void {
        // Use the provided arena allocator (created and managed by printFeedItems)
        const temp_alloc = arena.allocator();

        // 1. Title with index (Word Wrapped)
        const title_str = item.title orelse "No Title";
        const truncated_title = if (self.display_config.maxTitleLength > 0)
            truncateTextWithAlloc(temp_alloc, title_str, self.display_config.maxTitleLength) catch return
        else
            temp_alloc.dupe(u8, title_str) catch return;

        // Calculate proper indentation for wrapped title lines
        const index_str = std.fmt.allocPrint(temp_alloc, "{d}", .{index}) catch return;

        // Single digit (1-9): use 2 spaces, double digit (10+): use 1 space
        const leading_spaces: usize = if (index < 10) 2 else 1;
        const title_indent_len = leading_spaces + index_str.len + 2; // spaces + index + ". "
        const title_indent = temp_alloc.alloc(u8, title_indent_len) catch return;
        @memset(title_indent, ' '); // Fill with spaces

        // Format the index prefix (with color codes)
        const index_prefix = if (index < 10)
            std.fmt.allocPrint(temp_alloc, "  {s}{d}. ", .{ config.COLORS.BOLD, index }) catch return
        else
            std.fmt.allocPrint(temp_alloc, " {s}{d}. ", .{ config.COLORS.BOLD, index }) catch return;

        const term_width = self.getTermWidth();
        self.writeOutput(config.COLORS.BOLD);
        self.printWordWrappedWithColor(truncated_title, index_prefix, title_indent, term_width, config.COLORS.BOLD);

        // 2. Publication date
        if (self.display_config.showPublishDate) {
            var date_display: []u8 = undefined;

            // Try relative time first
            if (item.timestamp > 0) {
                if (getRelativeTimeWithAlloc(temp_alloc, item.timestamp)) |rel| {
                    date_display = rel;
                } else |_| {
                    // Fallback to raw string if allocation fails
                    date_display = @constCast(item.pubDate orelse "Unknown date");
                }
            } else if (item.pubDate) |pdate| {
                if (pdate.len > 0) {
                    date_display = @constCast(pdate);
                } else {
                    date_display = @constCast("Unknown date");
                }
            } else {
                date_display = @constCast("Unknown date");
            }

            if (date_display.len > 0) {
                self.writef("     {s}Published: {s}{s}\n", .{ config.COLORS.CYAN, date_display, config.COLORS.RESET });
            }
        }

        // 3. Description (Word Wrapped)
        if (self.display_config.showDescription) {
            if (item.description) |desc| {
                if (desc.len > 0) {
                    // Strip underline codes from description if underlineUrls is disabled
                    const desc_processed = if (self.display_config.underlineUrls)
                        temp_alloc.dupe(u8, desc) catch return
                    else
                        rss_reader.RssReader.stripUnderlineCodes(desc, temp_alloc) catch temp_alloc.dupe(u8, desc) catch return;

                    const desc_to_show = if (self.display_config.maxDescriptionLength > 0)
                        truncateTextWithAlloc(temp_alloc, desc_processed, self.display_config.maxDescriptionLength) catch return
                    else
                        desc_processed;

                    const term_width2 = self.getTermWidth();
                    self.writeOutput(config.COLORS.GRAY);
                    self.printWordWrapped(desc_to_show, "     ", "     ", term_width2);
                }
            }
        }

        // 4. Link (Configurable truncation)
        if (self.display_config.showLink) {
            if (item.link) |link| {
                if (link.len > 0) {
                    const link_prefix = "     Link: ";
                    const term_width3 = self.getTermWidth();
                    const available_width = if (term_width3 > link_prefix.len) term_width3 - link_prefix.len else link.len;

                    // Check if we should truncate based on config and available space
                    const should_truncate = self.display_config.truncateUrls and link.len > available_width;

                    // Apply underline to the link URL itself (if underlineUrls config is enabled)
                    const link_display = if (self.display_config.underlineUrls)
                        rss_reader.RssReader.underlineBareUrls(link, temp_alloc) catch link
                    else
                        link;

                    if (!should_truncate) {
                        // Link fits or truncation disabled, display normally with optional underline
                        self.writef("     {s}Link: {s}{s}\n", .{ config.COLORS.BLUE, link_display, config.COLORS.RESET });
                    } else {
                        // Link too long and truncation enabled, use hyperlink escape sequence
                        const truncated_link = truncateTextWithAlloc(temp_alloc, link, available_width) catch link;
                        const truncated_display = if (self.display_config.underlineUrls)
                            rss_reader.RssReader.underlineBareUrls(truncated_link, temp_alloc) catch truncated_link
                        else
                            truncated_link;

                        // Terminal hyperlink format: \e]8;;URL\e\DISPLAY_TEXT\e]8;;\e\
                        self.writef("     {s}Link: \x1b]8;;{s}\x1b\\{s}{s}\x1b]8;;\x1b\\{s}\n", .{
                            config.COLORS.BLUE,
                            link, // Full URL for the hyperlink
                            config.COLORS.BLUE, // Color for display text
                            truncated_display, // Truncated text to display (with optional underline)
                            config.COLORS.RESET,
                        });
                    }
                }
            }
        }

        // Ensure formatting is reset before the next item
        self.writeOutput(config.COLORS.RESET ++ "\n");
    }

    /// Count the number of digits in a number
    fn countDigits(self: *Formatter, num: usize) usize {
        _ = self;
        if (num == 0) return 1;
        var count: usize = 0;
        var n = num;
        while (n > 0) {
            count += 1;
            n /= 10;
        }
        return count;
    }

    /// Calculate visual width of a string, excluding ANSI color codes and handling UTF-8
    fn calculateVisualWidth(self: *Formatter, text: []const u8) usize {
        _ = self;
        var width: usize = 0;
        var i: usize = 0;

        while (i < text.len) {
            // 1. Handle ANSI Escape Codes (same as before)
            if (text[i] == '\x1b') {
                i += 1;
                if (i < text.len and text[i] == '[') {
                    i += 1;
                    while (i < text.len and text[i] != 'm') i += 1;
                    if (i < text.len) i += 1;
                } else if (i < text.len and text[i] == ']') {
                    i += 1;
                    while (i < text.len) {
                        if (text[i] == '\x1b' and i + 1 < text.len and text[i + 1] == '\\') {
                            i += 2;
                            break;
                        }
                        if (text[i] == 0x07) { // Bell terminator for OSC
                            i += 1;
                            break;
                        }
                        i += 1;
                    }
                }
                continue;
            }

            // 2. Handle UTF-8 Decoding
            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
                // Invalid UTF-8 start byte, treat as width 1 (replacement char)
                width += 1;
                i += 1;
                continue;
            };

            if (i + len > text.len) {
                // Incomplete sequence at end of string
                width += 1;
                i += 1;
                continue;
            }

            // Decode the code point
            const cp = std.unicode.utf8Decode(text[i .. i + len]) catch {
                width += 1;
                i += 1;
                continue;
            };

            // Add the correct display width
            width += getCodepointDisplayWidth(cp);
            i += len;
        }
        return width;
    }

    fn printWordWrappedWithColor(self: *Formatter, text: []const u8, prefix: []const u8, indent: []const u8, max_width: usize, color: []const u8) void {
        var text_to_process = text;
        var arena: ?std.heap.ArenaAllocator = null;
        defer if (arena) |*a| a.deinit();

        if (std.mem.indexOf(u8, text, "\u{3000}") != null) {
            var temp_arena = std.heap.ArenaAllocator.init(self.allocator);
            if (temp_arena.allocator().dupe(u8, text)) |buf| {
                arena = temp_arena;
                text_to_process = buf;
                var i: usize = 0;
                while (i + 2 < buf.len) {
                    if (buf[i] == 0xE3 and buf[i + 1] == 0x80 and buf[i + 2] == 0x80) {
                        buf[i] = ' ';
                        buf[i + 1] = ' ';
                        buf[i + 2] = ' ';
                        i += 3;
                    } else {
                        i += 1;
                    }
                }
            } else |_| {
                temp_arena.deinit();
            }
        }

        // Print the start of the first line
        self.writeOutput(prefix);
        // Calculate visual width of prefix (excluding ANSI color codes)
        var current_pos = self.calculateVisualWidth(prefix);
        const indent_width = self.calculateVisualWidth(indent);

        // Tokenize by whitespace to get words
        var it = std.mem.tokenizeAny(u8, text_to_process, " \t\n\r");
        var first_word = true;

        while (it.next()) |word| {
            // Check if this word is a URL
            const is_url = std.mem.startsWith(u8, word, "http://") or std.mem.startsWith(u8, word, "https://");

            // For URLs, potentially truncate them based on available space
            var display_word: []const u8 = word;
            var truncated_word: ?[]u8 = null;

            // Calculate width of the word
            const word_width = self.calculateVisualWidth(word);

            // Calculate available space for this word
            const remaining_space = if (max_width > current_pos) max_width - current_pos else 0;

            // URL Truncation Logic
            if (is_url and self.display_config.truncateUrls and word.len > remaining_space) {
                if (self.truncateText(word, remaining_space)) |truncated| {
                    truncated_word = truncated;
                    display_word = truncated_word.?;
                } else |_| {
                    display_word = word;
                }
            }
            defer if (truncated_word) |tw| self.allocator.free(tw);

            const space_len: usize = if (first_word) 0 else 1;
            const display_len = if (truncated_word != null) display_word.len else word_width;

            // CASE 1: Word fits on current line
            if (current_pos + space_len + display_len <= max_width) {
                if (!first_word) {
                    self.writeOutput(" ");
                    current_pos += 1;
                }

                if (is_url and truncated_word != null) {
                    self.writef("\x1b]8;;{s}\x1b\\{s}{s}\x1b]8;;\x1b\\", .{ word, color, display_word });
                } else {
                    self.writeOutput(display_word);
                }
                current_pos += display_len;
            }
            // CASE 2: Word is normal size (Western) but doesn't fit on this line -> Wrap to next line
            else if (display_len <= (max_width - indent_width)) {
                self.writeOutput("\n");
                self.writeOutput(indent);
                self.writeOutput(color); // Re-apply color
                current_pos = indent_width;

                if (is_url and truncated_word != null) {
                    self.writef("\x1b]8;;{s}\x1b\\{s}{s}\x1b]8;;\x1b\\", .{ word, color, display_word });
                } else {
                    self.writeOutput(display_word);
                }
                current_pos += display_len;
            }
            // CASE 3: Word is HUGE (longer than a full line).
            // This happens for CJK sentences (no spaces) or very long URLs (if truncation off).
            // We must perform a character-by-character split, but be ANSI-aware to avoid breaking escape sequences.
            else {
                // If we aren't at the start of a line (after indent), wrap first to get a fresh start
                if (current_pos > indent_width) {
                    self.writeOutput("\n");
                    self.writeOutput(indent);
                    self.writeOutput(color);
                    current_pos = indent_width;
                } else if (!first_word) {
                    // If we are at start but not first word, add a space
                    self.writeOutput(" ");
                    current_pos += 1;
                }

                var i: usize = 0;
                while (i < word.len) {
                    // Handle ANSI Escape Codes (Don't wrap inside them, don't count width)
                    if (word[i] == '\x1b') {
                        const start = i;
                        i += 1;
                        if (i < word.len and word[i] == '[') {
                            i += 1;
                            while (i < word.len and word[i] != 'm') i += 1;
                            if (i < word.len) i += 1;
                        } else if (i < word.len and word[i] == ']') {
                            i += 1;
                            while (i < word.len) {
                                if (word[i] == '\x1b' and i + 1 < word.len and word[i + 1] == '\\') {
                                    i += 2;
                                    break;
                                }
                                if (word[i] == 0x07) { // Bell terminator for OSC
                                    i += 1;
                                    break;
                                }
                                i += 1;
                            }
                        }
                        self.writeOutput(word[start..i]);
                        continue;
                    }

                    // Handle regular characters
                    const len = std.unicode.utf8ByteSequenceLength(word[i]) catch 1;
                    const slice = if (i + len <= word.len) word[i .. i + len] else word[i..];

                    var cw: usize = 0;
                    if (std.unicode.utf8Decode(slice)) |cp| {
                        cw = getCodepointDisplayWidth(cp);
                    } else |_| {
                        cw = 1;
                    }

                    // If adding this char exceeds line width, wrap
                    if (current_pos + cw > max_width) {
                        self.writeOutput("\n");
                        self.writeOutput(indent);
                        self.writeOutput(color);
                        current_pos = indent_width;
                    }

                    self.writeOutput(slice);
                    current_pos += cw;
                    i += len;
                }
            }
            first_word = false;
        }
        self.writeOutput(config.COLORS.RESET);
        self.writeOutput("\n");
    }

    fn printWordWrapped(self: *Formatter, text: []const u8, prefix: []const u8, indent: []const u8, max_width: usize) void {
        self.printWordWrappedWithColor(text, prefix, indent, max_width, config.COLORS.GRAY);
    }

    fn truncateText(self: *Formatter, text: []const u8, max_length: usize) ![]u8 {
        return truncateTextWithAlloc(self.allocator, text, max_length);
    }

    fn truncateTextWithAlloc(alloc: std.mem.Allocator, text: []const u8, max_length: usize) ![]u8 {
        // Simple case: text fits
        if (text.len <= max_length) {
            return alloc.dupe(u8, text);
        }

        // If really short
        if (max_length < 3) {
            return alloc.dupe(u8, ".");
        }

        // We want to truncate to `max_length - 3` (for "..."),
        // but we must ensure we don't split a multibyte sequence.
        const target_len = max_length - 3;
        var safe_len = target_len;

        // Ensure safe_len lands on a UTF-8 character start
        while (safe_len > 0 and safe_len < text.len) {
            // If current byte is a continuation byte (starts with 10...), go back
            if ((text[safe_len] & 0xC0) == 0x80) {
                safe_len -= 1;
            } else {
                break;
            }
        }

        const truncated = try alloc.alloc(u8, safe_len + 3);
        @memcpy(truncated[0..safe_len], text[0..safe_len]);
        @memcpy(truncated[safe_len .. safe_len + 3], "...");
        return truncated;
    }

    fn getRelativeTime(self: *Formatter, timestamp: i64) ![]u8 {
        return getRelativeTimeWithAlloc(self.allocator, timestamp);
    }

    fn getRelativeTimeWithAlloc(alloc: std.mem.Allocator, timestamp: i64) ![]u8 {
        if (timestamp == 0) return alloc.dupe(u8, "");

        const now = std.time.timestamp();
        // Handle future dates or clock skew
        if (timestamp > now) return alloc.dupe(u8, "just now");

        const diff = now - timestamp;

        if (diff < 60) {
            return alloc.dupe(u8, "just now");
        } else if (diff < 3600) {
            const mins = @divFloor(diff, 60);
            return std.fmt.allocPrint(alloc, "{d}m ago", .{mins});
        } else if (diff < 86400) {
            const hours = @divFloor(diff, 3600);
            return std.fmt.allocPrint(alloc, "{d}h ago", .{hours});
        } else if (diff < 604800) { // 7 days
            const days = @divFloor(diff, 86400);
            return std.fmt.allocPrint(alloc, "{d}d ago", .{days});
        } else {
            // Older than a week, return formatted date (YYYY-MM-DD)
            const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(timestamp)) };
            const year_day = epoch_seconds.getEpochDay().calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1 });
        }
    }

    /// Get relative time for recent dates (today, 1 day ago, etc), or formatted date for older ones
    fn getRelativeOrFormattedDateWithAlloc(alloc: std.mem.Allocator, timestamp: i64, date_format: []const u8) ![]u8 {
        if (timestamp == 0) return alloc.dupe(u8, "Unknown Date");

        const now = std.time.timestamp();
        // Handle future dates or clock skew
        if (timestamp > now) return alloc.dupe(u8, "today");

        const diff = now - timestamp;

        if (diff < 86400) {
            // Today
            return alloc.dupe(u8, "today");
        } else if (diff < 172800) { // 2 days
            // 1 day ago
            return alloc.dupe(u8, "1 day ago");
        } else if (diff < 604800) { // 7 days
            const days = @divFloor(diff, 86400);
            return std.fmt.allocPrint(alloc, "{d} days ago", .{days});
        } else {
            // Older than a week, return formatted date using date_format
            const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(timestamp)) };
            const year_day = epoch_seconds.getEpochDay().calculateYearDay();
            const month_day = year_day.calculateMonthDay();

            // Parse format string and apply substitutions
            var result = std.array_list.Managed(u8).init(alloc);
            errdefer result.deinit();

            var i: usize = 0;
            while (i < date_format.len) {
                if (date_format[i] == '%' and i + 1 < date_format.len) {
                    switch (date_format[i + 1]) {
                        'm' => {
                            // Month (01-12)
                            try result.writer().print("{d:0>2}", .{month_day.month.numeric()});
                            i += 2;
                        },
                        'd' => {
                            // Day (01-31)
                            try result.writer().print("{d:0>2}", .{month_day.day_index + 1});
                            i += 2;
                        },
                        'Y' => {
                            // Year (4 digits)
                            try result.writer().print("{d:0>4}", .{year_day.year});
                            i += 2;
                        },
                        'y' => {
                            // Year (2 digits)
                            const year_2digit = @as(u16, @truncate(@as(u32, @intCast(year_day.year)) % 100));
                            try result.writer().print("{d:0>2}", .{year_2digit});
                            i += 2;
                        },
                        '%' => {
                            try result.append('%');
                            i += 2;
                        },
                        else => {
                            // Unknown format code, just append it
                            try result.append('%');
                            try result.append(date_format[i + 1]);
                            i += 2;
                        },
                    }
                } else {
                    try result.append(date_format[i]);
                    i += 1;
                }
            }

            return try result.toOwnedSlice();
        }
    }

    fn formatDate(self: *Formatter, date_string: []const u8) ![]u8 {
        return try self.allocator.dupe(u8, date_string);
    }

    pub fn printSuccess(self: *Formatter, message: []const u8) void {
        self.writef("{s}{s}{s}\n", .{ config.COLORS.GREEN, message, config.COLORS.RESET });
        self.writeOutput("\n");
    }

    pub fn printError(self: *Formatter, message: []const u8) void {
        self.writef("{s}Error: {s}{s}\n", .{ config.COLORS.RED, message, config.COLORS.RESET });
        self.writeOutput("\n");
    }

    pub fn printWarning(self: *Formatter, message: []const u8) void {
        self.writef("{s}Warning: {s}{s}\n", .{ config.COLORS.YELLOW, message, config.COLORS.RESET });
        self.writeOutput("\n");
    }

    pub fn printInfo(self: *Formatter, message: []const u8) void {
        self.writef("{s}Info: {s}{s}\n", .{ config.COLORS.BLUE, message, config.COLORS.RESET });
        self.writeOutput("\n");
    }
};
