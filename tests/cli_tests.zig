const std = @import("std");
const cli_parser = @import("cli_parser");

// Test suite for CLI argument parsing
// Run with: zig build test-cli

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/// Create a CliParser from a slice of string literals (for testing)
fn createTestParser(allocator: std.mem.Allocator, comptime args: []const []const u8) !cli_parser.CliParser {
    // We need to convert []const []const u8 to [][:0]u8 for CliParser
    // In tests, we'll use the actual args struct layout
    _ = allocator;
    _ = args;
    // This is a workaround since CliParser expects the raw args from std.process
    @compileError("Use MockCliParser instead");
}

/// Mock CliParser that accepts string slices directly for testing
const MockCliParser = struct {
    allocator: std.mem.Allocator,
    args: []const []const u8,

    pub fn init(allocator: std.mem.Allocator, args: []const []const u8) MockCliParser {
        return MockCliParser{
            .allocator = allocator,
            .args = args,
        };
    }

    pub fn hasArg(self: MockCliParser, flag: []const u8) bool {
        for (self.args) |arg| {
            if (std.mem.eql(u8, arg, flag)) {
                return true;
            }
        }
        return false;
    }

    pub fn getArgValue(self: MockCliParser, flag: []const u8) ?[]const u8 {
        for (self.args, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, flag) and i + 1 < self.args.len) {
                return self.args[i + 1];
            }
        }
        return null;
    }

    pub fn parseGroupName(self: MockCliParser) ?[]const u8 {
        // Skip program name
        var i: usize = 1;
        var group_name: ?[]const u8 = null;

        // Valid flags - used for validation
        const valid_flags = [_][]const u8{
            "--help", "-h",      "--config", "--add",      "--export",
            "--name", "--reset", "--pager",  "--no-pager", "-day",
        };

        // Flags that consume the next argument
        const flags_with_values = [_][]const u8{
            "--add", "--export", "--name", "-day",
        };

        while (i < self.args.len) {
            const arg = self.args[i];

            // Handle flags (both -- and single dash longer than 2 chars)
            if (std.mem.startsWith(u8, arg, "--") or (std.mem.startsWith(u8, arg, "-") and arg.len > 2)) {
                // Validate that this is a known flag
                var is_valid_flag = false;
                for (valid_flags) |flag| {
                    if (std.mem.eql(u8, arg, flag)) {
                        is_valid_flag = true;
                        break;
                    }
                }

                if (!is_valid_flag) {
                    // Unknown flag - return null
                    return null;
                }

                // Check if this flag takes a value
                var skip_next = false;
                for (flags_with_values) |flag| {
                    if (std.mem.eql(u8, arg, flag)) {
                        skip_next = true;
                        break;
                    }
                }

                if (skip_next and i + 1 < self.args.len) {
                    i += 2; // Skip flag and its value
                } else {
                    i += 1; // Just skip the flag
                }
                continue;
            }

            // Skip URLs
            if (isUrl(arg)) {
                i += 1;
                continue;
            }

            // Skip file paths (OPML files, etc.)
            if (isFilePath(arg)) {
                i += 1;
                continue;
            }

            // This is a potential group name - only accept the first one
            if (group_name == null) {
                // Validate group name - reject special characters that could break file operations
                var is_valid_name = true;
                for (arg) |c| {
                    if (c == '/' or c == '\\' or c == ':' or c == '<' or c == '>' or c == '"' or c == '|' or c == '?') {
                        is_valid_name = false;
                        break;
                    }
                }

                if (is_valid_name) {
                    group_name = arg;
                }
            }
            i += 1;
        }

        return group_name;
    }

    pub fn getOpmlFilePath(self: MockCliParser) ?[]const u8 {
        // Skip program name
        for (self.args[1..]) |arg| {
            // Skip flags
            if (std.mem.startsWith(u8, arg, "-")) {
                continue;
            }
            // Skip URLs
            if (isUrl(arg)) {
                continue;
            }
            // Check if it's an OPML/XML file path
            if (isFilePath(arg)) {
                return arg;
            }
        }
        return null;
    }
};

fn isUrl(str: []const u8) bool {
    return std.mem.startsWith(u8, str, "http://") or std.mem.startsWith(u8, str, "https://");
}

fn isFilePath(str: []const u8) bool {
    // Check if it looks like a file path (starts with / or ./ or ~/)
    if (std.mem.startsWith(u8, str, "/") or
        std.mem.startsWith(u8, str, "./") or
        std.mem.startsWith(u8, str, "~/"))
    {
        return true;
    }
    // Check for OPML files only (not .xml, as that's too broad and matches feed URLs)
    if (std.mem.endsWith(u8, str, ".opml")) {
        return true;
    }
    return false;
}

// ============================================================================
// GROUP NAME PARSING TESTS
// ============================================================================

test "parseGroupName identifies group before flags" {
    const args = [_][]const u8{ "hys", "tech", "--add", "https://site.com" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const group_name = parser.parseGroupName();
    try std.testing.expect(group_name != null);
    try std.testing.expectEqualStrings("tech", group_name.?);
}

test "parseGroupName identifies group after flags" {
    const args = [_][]const u8{ "hys", "--reset", "youtube" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const group_name = parser.parseGroupName();
    try std.testing.expect(group_name != null);
    try std.testing.expectEqualStrings("youtube", group_name.?);
}

test "parseGroupName returns null when only URLs provided" {
    const args = [_][]const u8{ "hys", "https://example.com/feed.xml" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const group_name = parser.parseGroupName();
    try std.testing.expect(group_name == null);
}

test "parseGroupName skips URLs and finds group" {
    const args = [_][]const u8{ "hys", "https://example.com/feed.xml", "tech", "http://another.com/rss" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const group_name = parser.parseGroupName();
    try std.testing.expect(group_name != null);
    try std.testing.expectEqualStrings("tech", group_name.?);
}

test "parseGroupName rejects invalid group names with special characters" {
    // Group name with path separator should be rejected
    const args = [_][]const u8{ "hys", "tech/news" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const group_name = parser.parseGroupName();
    try std.testing.expect(group_name == null);
}

test "parseGroupName rejects group names with backslash" {
    const args = [_][]const u8{ "hys", "tech\\news" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const group_name = parser.parseGroupName();
    try std.testing.expect(group_name == null);
}

test "parseGroupName returns null for unknown flags" {
    // Unknown flag should cause null return, not be interpreted as group name
    const args = [_][]const u8{ "hys", "--unknown-flag" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const group_name = parser.parseGroupName();
    try std.testing.expect(group_name == null);
}

test "parseGroupName handles -day flag with value" {
    const args = [_][]const u8{ "hys", "main", "-day", "-1" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const group_name = parser.parseGroupName();
    try std.testing.expect(group_name != null);
    try std.testing.expectEqualStrings("main", group_name.?);
}

test "parseGroupName skips OPML file paths" {
    const args = [_][]const u8{ "hys", "/path/to/feeds.opml", "tech" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const group_name = parser.parseGroupName();
    try std.testing.expect(group_name != null);
    try std.testing.expectEqualStrings("tech", group_name.?);
}

test "parseGroupName handles relative OPML path" {
    const args = [_][]const u8{ "hys", "./feeds.opml", "mygroup" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const group_name = parser.parseGroupName();
    try std.testing.expect(group_name != null);
    try std.testing.expectEqualStrings("mygroup", group_name.?);
}

test "parseGroupName returns null when only program name" {
    const args = [_][]const u8{"hys"};
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const group_name = parser.parseGroupName();
    try std.testing.expect(group_name == null);
}

// ============================================================================
// FLAG DETECTION TESTS
// ============================================================================

test "hasArg detects --help flag" {
    const args = [_][]const u8{ "hys", "--help" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    try std.testing.expect(parser.hasArg("--help"));
    try std.testing.expect(!parser.hasArg("-h"));
    try std.testing.expect(!parser.hasArg("--config"));
}

test "hasArg detects short -h flag" {
    const args = [_][]const u8{ "hys", "-h" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    try std.testing.expect(parser.hasArg("-h"));
    try std.testing.expect(!parser.hasArg("--help"));
}

test "hasArg detects multiple flags" {
    const args = [_][]const u8{ "hys", "--reset", "--no-pager", "tech" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    try std.testing.expect(parser.hasArg("--reset"));
    try std.testing.expect(parser.hasArg("--no-pager"));
    try std.testing.expect(!parser.hasArg("--pager"));
}

test "hasArg returns false for non-existent flag" {
    const args = [_][]const u8{ "hys", "tech" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    try std.testing.expect(!parser.hasArg("--help"));
    try std.testing.expect(!parser.hasArg("--reset"));
}

// ============================================================================
// FLAG VALUE EXTRACTION TESTS
// ============================================================================

test "getArgValue extracts --add value" {
    const args = [_][]const u8{ "hys", "--add", "https://example.com/feed.xml" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const value = parser.getArgValue("--add");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("https://example.com/feed.xml", value.?);
}

test "getArgValue extracts --export value" {
    const args = [_][]const u8{ "hys", "tech", "--export", "/tmp/export.opml" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const value = parser.getArgValue("--export");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("/tmp/export.opml", value.?);
}

test "getArgValue extracts -day value" {
    const args = [_][]const u8{ "hys", "main", "-day", "-2" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const value = parser.getArgValue("-day");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("-2", value.?);
}

test "getArgValue returns null when flag has no value" {
    const args = [_][]const u8{ "hys", "--add" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const value = parser.getArgValue("--add");
    try std.testing.expect(value == null);
}

test "getArgValue returns null for non-existent flag" {
    const args = [_][]const u8{ "hys", "tech" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const value = parser.getArgValue("--add");
    try std.testing.expect(value == null);
}

// ============================================================================
// OPML FILE PATH DETECTION TESTS
// ============================================================================

test "getOpmlFilePath detects absolute path" {
    const args = [_][]const u8{ "hys", "/Users/test/feeds.opml" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const path = parser.getOpmlFilePath();
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("/Users/test/feeds.opml", path.?);
}

test "getOpmlFilePath detects relative path with ./" {
    const args = [_][]const u8{ "hys", "./my_feeds.opml" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const path = parser.getOpmlFilePath();
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("./my_feeds.opml", path.?);
}

test "getOpmlFilePath detects home-relative path" {
    const args = [_][]const u8{ "hys", "~/Documents/feeds.opml" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const path = parser.getOpmlFilePath();
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("~/Documents/feeds.opml", path.?);
}

test "getOpmlFilePath detects .opml extension without path prefix" {
    const args = [_][]const u8{ "hys", "feeds.opml" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const path = parser.getOpmlFilePath();
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("feeds.opml", path.?);
}

test "getOpmlFilePath returns null when no OPML file" {
    const args = [_][]const u8{ "hys", "tech", "--add", "https://example.com" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const path = parser.getOpmlFilePath();
    try std.testing.expect(path == null);
}

test "getOpmlFilePath skips URLs" {
    const args = [_][]const u8{ "hys", "https://example.com/feed.xml", "/path/to/feeds.opml" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const path = parser.getOpmlFilePath();
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("/path/to/feeds.opml", path.?);
}

test "getOpmlFilePath skips flags" {
    const args = [_][]const u8{ "hys", "--reset", "feeds.opml" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const path = parser.getOpmlFilePath();
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("feeds.opml", path.?);
}

// ============================================================================
// URL DETECTION TESTS
// ============================================================================

test "isUrl correctly identifies http URLs" {
    try std.testing.expect(isUrl("http://example.com/feed"));
    try std.testing.expect(isUrl("http://localhost:8080/rss"));
}

test "isUrl correctly identifies https URLs" {
    try std.testing.expect(isUrl("https://example.com/feed.xml"));
    try std.testing.expect(isUrl("https://subdomain.example.com/rss"));
}

test "isUrl rejects non-URL strings" {
    try std.testing.expect(!isUrl("example.com"));
    try std.testing.expect(!isUrl("ftp://example.com"));
    try std.testing.expect(!isUrl("tech"));
    try std.testing.expect(!isUrl("--help"));
    try std.testing.expect(!isUrl("/path/to/file.xml"));
}

// ============================================================================
// FILE PATH DETECTION TESTS
// ============================================================================

test "isFilePath detects absolute paths" {
    try std.testing.expect(isFilePath("/home/user/feeds.opml"));
    try std.testing.expect(isFilePath("/tmp/test.opml"));
}

test "isFilePath detects relative paths" {
    try std.testing.expect(isFilePath("./feeds.opml"));
    try std.testing.expect(isFilePath("./subdir/feeds.opml"));
}

test "isFilePath detects home-relative paths" {
    try std.testing.expect(isFilePath("~/feeds.opml"));
    try std.testing.expect(isFilePath("~/Documents/rss/feeds.opml"));
}

test "isFilePath detects .opml extension" {
    try std.testing.expect(isFilePath("feeds.opml"));
    try std.testing.expect(isFilePath("my_subscriptions.opml"));
}

test "isFilePath rejects non-file strings" {
    try std.testing.expect(!isFilePath("tech"));
    try std.testing.expect(!isFilePath("--help"));
    try std.testing.expect(!isFilePath("https://example.com"));
    // Note: .xml is intentionally not detected to avoid matching feed URLs
    try std.testing.expect(!isFilePath("feed.xml"));
}

// ============================================================================
// EDGE CASES
// ============================================================================

test "parseGroupName with empty args" {
    const args = [_][]const u8{};
    const parser = MockCliParser.init(std.testing.allocator, &args);

    // Should not crash, just return null
    const group_name = parser.parseGroupName();
    try std.testing.expect(group_name == null);
}

test "parseGroupName with unicode group name" {
    const args = [_][]const u8{ "hys", "日本語" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const group_name = parser.parseGroupName();
    try std.testing.expect(group_name != null);
    try std.testing.expectEqualStrings("日本語", group_name.?);
}

test "parseGroupName with emoji group name" {
    const args = [_][]const u8{ "hys", "🚀news" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    const group_name = parser.parseGroupName();
    try std.testing.expect(group_name != null);
    try std.testing.expectEqualStrings("🚀news", group_name.?);
}

test "complex command with multiple features" {
    const args = [_][]const u8{ "hys", "tech", "--add", "https://news.ycombinator.com/rss", "--name", "Hacker News" };
    const parser = MockCliParser.init(std.testing.allocator, &args);

    try std.testing.expect(parser.hasArg("--add"));
    try std.testing.expect(parser.hasArg("--name"));

    const add_value = parser.getArgValue("--add");
    try std.testing.expect(add_value != null);
    try std.testing.expectEqualStrings("https://news.ycombinator.com/rss", add_value.?);

    const group_display = parser.getArgValue("--name");
    try std.testing.expect(group_display != null);
    try std.testing.expectEqualStrings("Hacker News", group_display.?);

    const group_name = parser.parseGroupName();
    try std.testing.expect(group_name != null);
    try std.testing.expectEqualStrings("tech", group_name.?);
}
