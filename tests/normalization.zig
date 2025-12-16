const std = @import("std");

/// Normalize identifier (GUID or URL) before hashing
/// Handles: http/https, trailing slashes, tracking params, HTML entities, case differences
fn normalizeIdentifier(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var normalized = try allocator.dupe(u8, id);
    defer allocator.free(normalized);

    // Convert to lowercase for case-insensitive matching
    for (normalized, 0..) |*c, i| {
        normalized[i] = std.ascii.toLower(c.*);
    }

    // Normalize http/https to https
    var working = if (std.mem.startsWith(u8, normalized, "http://"))
        normalized[7..]
    else
        normalized;

    // Find where to truncate (tracking params or trailing slash)
    var end_idx = working.len;

    // Remove trailing slash for URLs
    if ((std.mem.startsWith(u8, normalized, "https://") or std.mem.startsWith(u8, normalized, "http://")) and
        end_idx > 0 and working[end_idx - 1] == '/') {
        end_idx -= 1;
    }

    // Remove common tracking parameters
    if (std.mem.indexOf(u8, working[0..end_idx], "?utm_")) |idx| {
        end_idx = idx;
    } else if (std.mem.indexOf(u8, working[0..end_idx], "?fbclid=")) |idx| {
        end_idx = idx;
    } else if (std.mem.indexOf(u8, working[0..end_idx], "?ref=")) |idx| {
        end_idx = idx;
    }

    // If http:// was present, add https://
    if (std.mem.startsWith(u8, normalized, "http://")) {
        try result.appendSlice("https://");
    }

    // Add normalized content (with HTML entity decoding)
    var i: usize = 0;
    while (i < end_idx) {
        if (working[i] == '&') {
            if (std.mem.startsWith(u8, working[i..end_idx], "&amp;")) {
                try result.append('&');
                i += 5;
            } else if (std.mem.startsWith(u8, working[i..end_idx], "&lt;")) {
                try result.append('<');
                i += 4;
            } else if (std.mem.startsWith(u8, working[i..end_idx], "&gt;")) {
                try result.append('>');
                i += 4;
            } else if (std.mem.startsWith(u8, working[i..end_idx], "&quot;")) {
                try result.append('"');
                i += 6;
            } else if (std.mem.startsWith(u8, working[i..end_idx], "&apos;")) {
                try result.append('\'');
                i += 6;
            } else {
                try result.append(working[i]);
                i += 1;
            }
        } else {
            try result.append(working[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_cases = [_]struct { input: []const u8, expected: []const u8 }{
        // HTTP to HTTPS normalization
        .{ .input = "http://example.com", .expected = "https://example.com" },
        
        // Trailing slash removal
        .{ .input = "https://example.com/", .expected = "https://example.com" },
        .{ .input = "http://example.com/article/", .expected = "https://example.com/article" },
        
        // Case normalization
        .{ .input = "HTTPS://EXAMPLE.COM", .expected = "https://example.com" },
        .{ .input = "HTTPs://Example.Com/Article", .expected = "https://example.com/article" },
        
        // Tracking parameters removal
        .{ .input = "https://example.com/article?utm_source=twitter", .expected = "https://example.com/article" },
        .{ .input = "https://example.com/page?fbclid=123456", .expected = "https://example.com/page" },
        .{ .input = "https://example.com?ref=reddit", .expected = "https://example.com" },
        
        // HTML entity decoding
        .{ .input = "https://example.com/article&amp;section=1", .expected = "https://example.com/article&section=1" },
        .{ .input = "Title with &lt;tag&gt;", .expected = "title with <tag>" },
        .{ .input = "Quote &quot;test&quot;", .expected = "quote \"test\"" },
        
        // Combined normalization
        .{ .input = "HTTP://EXAMPLE.COM/article/?utm_source=test&amp;id=1", .expected = "https://example.com/article" },
        .{ .input = "https://Example.Com/Page/?fbclid=xyz", .expected = "https://example.com/page" },
        
        // GUIDs (should pass through with case normalization)
        .{ .input = "UUID:12345-ABC-DEF", .expected = "uuid:12345-abc-def" },
    };

    var passed: usize = 0;
    var failed: usize = 0;

    for (test_cases) |tc| {
        const result = try normalizeIdentifier(allocator, tc.input);
        defer allocator.free(result);

        if (std.mem.eql(u8, result, tc.expected)) {
            passed += 1;
            std.debug.print("✓ PASS: {s}\n", .{tc.input});
        } else {
            failed += 1;
            std.debug.print("✗ FAIL: {s}\n", .{tc.input});
            std.debug.print("  Expected: {s}\n", .{tc.expected});
            std.debug.print("  Got:      {s}\n", .{result});
        }
    }

    std.debug.print("\n{d} passed, {d} failed\n", .{ passed, failed });

    if (failed > 0) {
        std.process.exit(1);
    }
}
