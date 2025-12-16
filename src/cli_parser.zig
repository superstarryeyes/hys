const std = @import("std");
const types = @import("types");

// Define compile-time maps for valid flags (Value is void as we just check existence)
const valid_flags_map = std.StaticStringMap(void).initComptime(.{
    .{ "--help", {} },    .{ "-h", {} },
    .{ "--version", {} }, .{ "-v", {} },
    .{ "--groups", {} },  .{ "-g", {} },
    .{ "--sub", {} },     .{ "-s", {} },
    .{ "--import", {} },  .{ "-i", {} },
    .{ "--export", {} },  .{ "-e", {} },
    .{ "--name", {} },    .{ "-n", {} },
    .{ "--reset", {} },   .{ "-r", {} },
    .{ "--pager", {} },   .{ "--no-pager", {} },
    .{ "--all", {} },     .{ "-a", {} },
    .{ "--day", {} },     .{ "-d", {} },
});

const flags_with_values_map = std.StaticStringMap(void).initComptime(.{
    .{ "--sub", {} },    .{ "-s", {} },
    .{ "--import", {} }, .{ "-i", {} },
    .{ "--export", {} }, .{ "-e", {} },
    .{ "--name", {} },   .{ "-n", {} },
    .{ "--day", {} },    .{ "-d", {} },
});

pub const ParseError = error{
    UnknownFlag,
    OutOfMemory,
};

pub const CliParser = struct {
    allocator: std.mem.Allocator,
    // Explicitly mark as sentinel-terminated strings as per std.process.argsAlloc
    args: [][:0]u8,

    pub fn init(allocator: std.mem.Allocator, args: [][:0]u8) CliParser {
        return CliParser{
            .allocator = allocator,
            .args = args,
        };
    }

    pub fn hasArg(self: CliParser, flag: []const u8) bool {
        for (self.args) |arg| {
            if (std.mem.eql(u8, arg, flag)) {
                return true;
            }
        }
        return false;
    }

    pub fn getArgValue(self: CliParser, flag: []const u8) ?[]const u8 {
        for (self.args, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, flag) and i + 1 < self.args.len) {
                return std.mem.sliceTo(self.args[i + 1], 0);
            }
        }
        return null;
    }

    pub fn getNextArg(self: CliParser, flag: []const u8) ?[]const u8 {
        for (self.args, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, flag) and i + 1 < self.args.len) {
                return std.mem.sliceTo(self.args[i + 1], 0);
            }
        }
        return null;
    }

    pub fn getCmdLineFeeds(self: CliParser) ![]types.FeedConfig {
        var feeds = std.array_list.Managed(types.FeedConfig).init(self.allocator);
        defer feeds.deinit();

        // Skip program name and look for URLs
        var i: usize = 1;
        while (i < self.args.len) {
            const arg = self.args[i];

            // Skip flags and their values - only accept valid flags
            if (std.mem.startsWith(u8, arg, "-")) {
                if (!valid_flags_map.has(arg)) {
                    // Unknown flag - this is an error
                    std.debug.print("Error: Unknown flag '{s}'\n", .{arg});
                    std.debug.print("Run 'hys --help' for usage information.\n", .{});
                    return error.UnknownFlag;
                }

                // Check if this flag takes a value
                const skip_next = flags_with_values_map.has(arg);

                if (skip_next and i + 1 < self.args.len) {
                    i += 2; // Skip flag and its value
                } else {
                    i += 1; // Just skip the flag
                }
                continue;
            }

            // Add URLs
            if (isUrl(arg)) {
                const url = try self.allocator.dupe(u8, arg);
                try feeds.append(types.FeedConfig{
                    .xmlUrl = url,
                    .text = null,
                    .enabled = true,
                });
            }

            i += 1;
        }

        return feeds.toOwnedSlice();
    }

    pub fn parseGroupNames(self: CliParser) ParseError![]const []const u8 {
        // Skip program name
        var i: usize = 1;
        var group_names = std.array_list.Managed([]const u8).init(self.allocator);
        errdefer group_names.deinit();

        while (i < self.args.len) {
            const arg = self.args[i];

            // Handle flags - be strict: only accept exact matches from valid_flags
            if (std.mem.startsWith(u8, arg, "-")) {
                if (!valid_flags_map.has(arg)) {
                    // Unknown flag - this is an error
                    std.debug.print("Error: Unknown flag '{s}'\n", .{arg});
                    std.debug.print("Run 'hys --help' for usage information.\n", .{});
                    return ParseError.UnknownFlag;
                }

                // Check if this flag takes a value
                const skip_next = flags_with_values_map.has(arg);

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

            // This is a potential group name (or comma-separated list of names)
            // Only accept the first positional argument as the group specifier
            if (group_names.items.len == 0) {
                // Split by comma
                var it = std.mem.splitScalar(u8, arg, ',');
                while (it.next()) |part| {
                    if (part.len > 0) {
                        // Validate group name part
                        var is_valid_name = true;
                        for (part) |c| {
                            if (c == '/' or c == '\\' or c == ':' or c == '<' or c == '>' or c == '"' or c == '|' or c == '?') {
                                is_valid_name = false;
                                break;
                            }
                        }

                        if (is_valid_name) {
                            try group_names.append(part);
                        }
                    }
                }
            }
            i += 1;
        }

        return group_names.toOwnedSlice();
    }

    /// Get OPML file path if one was passed directly as an argument
    pub fn getOpmlFilePath(self: CliParser) ?[]const u8 {
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
                return std.mem.sliceTo(arg, 0);
            }
        }
        return null;
    }

    pub fn printHelp() void {
        std.debug.print(
            \\Hys - RSS Reader for Digital Minimalists
            \\
            \\USAGE:
            \\    hys [GROUP] [OPTIONS] [URL]
            \\
            \\OPTIONS:
            \\    -h, --help                    Show this help message
            \\    -v, --version                 Show version information
            \\    -g, --groups                  List all available feed groups
            \\    -c, --config                  Show config file location
            \\    -a, --all                     Fetch and display feeds from all groups
            \\    -d, --day <NUM>               Fetch history for current group (1 for previous)
            \\
            \\    -s, --sub "<URL>" [NAME]      Subscribe to feed URL with optional display name
            \\    -i, --import <FILE>           Import OPML file to current group
            \\    -e, --export <FILE>           Export current group's feeds to OPML
            \\    -n, --name <NAME>             Set display name for current group
            \\    -r, --reset                   Reset daily limit
            \\    --pager / --no-pager          Force enable/disable pager
            \\
            \\EXAMPLES:
            \\    hys                           Check feeds from main group
            \\    hys news                      Check feeds from news group
            \\    hys tech,news                 Check both groups
            \\    hys --all                     Check feeds from all groups
            \\    hys news --sub "<URL>"        Add feed to 'news' group
            \\    hys tech --import feeds.opml  Import OPML feeds to 'tech' group
            \\    hys art --name "Art"          Set display name for group
            \\
        , .{});
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
