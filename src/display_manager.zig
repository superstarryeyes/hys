const std = @import("std");
const builtin = @import("builtin");
const types = @import("types");
const Formatter = @import("formatter").Formatter;
const Config = @import("config");

pub const DisplayManager = struct {
    allocator: std.mem.Allocator,
    formatter: Formatter,
    output_buffer: ?*std.array_list.Managed(u8),
    pager_process: ?*std.process.Child = null,
    use_pager_streaming: bool = false,
    pager_mode: bool = false,
    stdout: *std.Io.Writer,

    pub fn init(allocator: std.mem.Allocator, config_display: types.DisplayConfig, stdout: *std.Io.Writer) !DisplayManager {
        const output_buffer = try allocator.create(std.array_list.Managed(u8));
        output_buffer.* = std.array_list.Managed(u8).init(allocator);

        var dm: DisplayManager = undefined;
        dm.allocator = allocator;
        dm.output_buffer = output_buffer;
        dm.pager_process = null;
        dm.use_pager_streaming = false;
        dm.pager_mode = config_display.pagerMode;
        dm.stdout = stdout;

        dm.formatter = Formatter.initWithBuffer(allocator, config_display, output_buffer);

        return dm;
    }

    pub fn deinit(self: *DisplayManager) void {
        if (self.pager_process) |process| {
            // Close stdin first to signal EOF to the pager
            if (process.stdin) |stdin| {
                var stdin_copy = stdin;
                stdin_copy.close();
                process.stdin = null;
            }

            // Wait for pager to finish
            _ = process.wait() catch |err| {
                std.debug.print("Warning: Failed to wait for pager process: {}\n", .{err});
            };

            // Clean up the allocated process
            self.allocator.destroy(process);
        }

        if (self.output_buffer) |buf| {
            buf.deinit();
            self.allocator.destroy(buf);
        }
    }

    pub fn printHeader(self: *DisplayManager, title: []const u8) void {
        self.formatter.printHeader(title);
    }

    pub fn printHysDigestHeader(self: *DisplayManager, group_name: []const u8, timestamp: i64, days_ago: ?i32) void {
        self.formatter.printHysDigestHeader(group_name, timestamp, days_ago);
    }

    pub fn printInfo(self: *DisplayManager, msg: []const u8) void {
        self.formatter.printInfo(msg);
    }

    pub fn printError(self: *DisplayManager, msg: []const u8) void {
        self.formatter.printError(msg);
    }

    pub fn printSuccess(self: *DisplayManager, msg: []const u8) void {
        self.formatter.printSuccess(msg);
    }

    pub fn printWarning(self: *DisplayManager, msg: []const u8) void {
        self.formatter.printWarning(msg);
    }

    pub fn printGroupHeader(self: *DisplayManager, name: []const u8) void {
        self.formatter.printGroupHeader(name);
    }

    pub fn printFeedHeader(self: *DisplayManager, name: []const u8) void {
        self.formatter.printFeedHeader(name, 0);
    }

    pub fn printFeedHeaderIndented(self: *DisplayManager, name: []const u8, indent: usize) void {
        self.formatter.printFeedHeader(name, indent);
    }

    pub fn printFeedItems(self: *DisplayManager, items: []types.RssItem) void {
        self.formatter.printFeedItems(items);
    }

    pub fn flush(self: *DisplayManager) !void {
        // If we have pager buffer, pipe it to less
        if (self.output_buffer) |buf| {
            if (buf.items.len > 0) {
                try self.pipeToLess();
            }
        }
        // Direct stdout write doesn't need flushing
    }

    pub fn renderFeedsToBuffer(self: *DisplayManager, items: []const types.RssItem) !void {
        // Determine if we need to show group headers (if items belong to different groups)
        const show_group_headers = blk: {
            if (items.len == 0) break :blk false;
            const first = items[0].groupName orelse "";
            const last = items[items.len - 1].groupName orelse "";
            break :blk !std.mem.eql(u8, first, last);
        };

        var current_group: ?[]const u8 = null;
        var current_feed: ?[]const u8 = null;

        var batch = std.array_list.Managed(types.RssItem).init(self.allocator);
        defer batch.deinit();

        for (items) |item| {
            const feed_name = item.feedName orelse "Unknown Feed";
            const group_name = item.groupName orelse "main";

            // Check for Group Change
            if (show_group_headers) {
                if (current_group == null or !std.mem.eql(u8, current_group.?, group_name)) {
                    // Flush previous feed batch if exists
                    if (current_feed != null) {
                        const indent: usize = if (show_group_headers) 1 else 0;
                        self.printFeedHeaderIndented(current_feed.?, indent);
                        self.printFeedItems(batch.items);
                        batch.clearRetainingCapacity();
                    }

                    const group_display_name = item.groupDisplayName orelse group_name;
                    self.printGroupHeader(group_display_name);
                    current_group = group_name;
                    current_feed = null; // Force feed header print for new group
                }
            }

            // Check for Feed Change
            if (current_feed == null or !std.mem.eql(u8, current_feed.?, feed_name)) {
                if (current_feed != null) {
                    const indent: usize = if (show_group_headers) 1 else 0;
                    self.printFeedHeaderIndented(current_feed.?, indent);
                    self.printFeedItems(batch.items);
                    batch.clearRetainingCapacity();
                }
                current_feed = feed_name;
            }

            try batch.append(item);
        }

        // Flush final batch
        if (current_feed) |name| {
            const indent: usize = if (show_group_headers) 1 else 0;
            self.printFeedHeaderIndented(name, indent);
            self.printFeedItems(batch.items);
        }
    }

    pub fn printCachedItems(self: *DisplayManager, items: []const types.RssItem) !void {
        // Determine if we need to show group headers (if items belong to different groups)
        const show_group_headers = blk: {
            if (items.len == 0) break :blk false;
            const first = items[0].groupName orelse "";
            const last = items[items.len - 1].groupName orelse "";
            break :blk !std.mem.eql(u8, first, last);
        };

        var current_group: ?[]const u8 = null;
        var current_feed: ?[]const u8 = null;

        var current_feed_items = std.array_list.Managed(types.RssItem).init(self.allocator);
        defer current_feed_items.deinit();

        for (items) |item| {
            const feed_name = item.feedName orelse "Unknown Feed";
            const group_name = item.groupName orelse "main";

            // Group Change Logic
            if (show_group_headers) {
                if (current_group == null or !std.mem.eql(u8, current_group.?, group_name)) {
                    // Flush previous feed
                    if (current_feed != null) {
                        const indent: usize = if (show_group_headers) 1 else 0;
                        self.printFeedHeaderIndented(current_feed.?, indent);
                        self.printFeedItems(current_feed_items.items);
                        current_feed_items.clearRetainingCapacity();
                    }

                    const group_display_name = item.groupDisplayName orelse group_name;
                    self.printGroupHeader(group_display_name);
                    current_group = group_name;
                    current_feed = null;
                }
            }

            // Feed Change Logic
            if (current_feed == null or !std.mem.eql(u8, current_feed.?, feed_name)) {
                if (current_feed != null) {
                    const indent: usize = if (show_group_headers) 1 else 0;
                    self.printFeedHeaderIndented(current_feed.?, indent);
                    self.printFeedItems(current_feed_items.items);
                    current_feed_items.clearRetainingCapacity();
                }
                current_feed = feed_name;
            }

            try current_feed_items.append(item);
        }

        // Flush last feed
        if (current_feed) |feed_name| {
            const indent: usize = if (show_group_headers) 1 else 0;
            self.printFeedHeaderIndented(feed_name, indent);
            self.printFeedItems(current_feed_items.items);
        }
    }

    pub fn pipeToLess(self: *DisplayManager) !void {
        // For buffered mode (fallback), pipe the buffer to less
        if (self.output_buffer) |buf| {
            // If pager mode is disabled, just print directly to stdout
            if (!self.pager_mode) {
                try self.stdout.writeAll(buf.items);
                buf.clearRetainingCapacity();
                return;
            }

            const pager_cmd: []const u8 = "less";
            var argv = [_][]const u8{ pager_cmd, "-R", "-Q" };

            if (builtin.os.tag == .windows) {
                // Check if 'less' exists, otherwise fall back to direct print (not 'more')
                // 'more' destroys ANSI codes on Windows
                const exit_code = std.process.Child.run(.{
                    .allocator = self.allocator,
                    .argv = &[_][]const u8{ "where", "less" },
                }) catch {
                    // 'where' command failed or less not found, fallback to stdout
                    try self.stdout.writeAll(buf.items);
                    buf.clearRetainingCapacity();
                    return;
                };
                defer self.allocator.free(exit_code.stdout);
                defer self.allocator.free(exit_code.stderr);

                if (exit_code.term != .Exited or exit_code.term.Exited != 0) {
                    // less not found, print directly
                    try self.stdout.writeAll(buf.items);
                    buf.clearRetainingCapacity();
                    return;
                }
                // If we are here, 'less' is in PATH on Windows (e.g., via Git Bash or Chocolatey)
            }

            var child = std.process.Child.init(&argv, self.allocator);
            child.stdin_behavior = .Pipe;
            // Set LESS_TERMCAP_vb to inhibit visual bell on both old and new versions of less
            var env_map = try std.process.getEnvMap(self.allocator);
            defer env_map.deinit();
            try env_map.put("LESS_TERMCAP_vb", "\x1B[s");
            child.env_map = &env_map;
            child.spawn() catch {
                // Fallback: just print if pager fails
                try self.stdout.writeAll(buf.items);
                buf.clearRetainingCapacity();
                return;
            };

            if (child.stdin) |*stdin| {
                defer {
                    stdin.close();
                    child.stdin = null;
                }
                stdin.writeAll(buf.items) catch |err| {
                    if (err != error.BrokenPipe) {
                        return err;
                    }
                };
            }
            _ = try child.wait();
            // Clear buffer after successful pipe to prevent duplicate calls from flush()
            buf.clearRetainingCapacity();
        }
        // For streaming mode, pager is already running and we've written to it
    }

    pub fn clearBuffer(self: *DisplayManager) void {
        if (self.output_buffer) |buf| {
            buf.clearRetainingCapacity();
        }
    }

    pub fn getBufferItems(self: *DisplayManager) ?[]const u8 {
        if (self.output_buffer) |buf| {
            return buf.items;
        }
        return null;
    }
};
