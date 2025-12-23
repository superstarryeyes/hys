const std = @import("std");
const zdt = @import("zdt");
const types = @import("types");
const RssReader = @import("rss_reader").RssReader;

pub const DailyLimiter = struct {
    allocator: std.mem.Allocator,
    /// Directory path where daily state files are stored (e.g., ~/.hys/history)
    state_dir: []u8,
    /// Path to the persistent hash storage file (e.g., ~/.hys/seen_ids.bin)
    seen_ids_file: []u8,
    /// Current group name for history file generation
    group_name: []const u8,
    /// Hour of the day when the next day starts (0-23)
    day_start_hour: u8,
    /// Fetch interval in days (limit fetching to once every N days)
    fetch_interval_days: u32,

    pub fn init(allocator: std.mem.Allocator, group_name: []const u8, day_start_hour: u8, fetch_interval_days: u32) !DailyLimiter {
        const home_dir = std.posix.getenv("HOME") orelse std.posix.getenv("USERPROFILE") orelse ".";
        const base_dir = try std.fs.path.join(allocator, &.{ home_dir, ".hys" });
        defer allocator.free(base_dir);

        const state_dir = try std.fs.path.join(allocator, &.{ base_dir, "history" });
        const seen_ids_file = try std.fs.path.join(allocator, &.{ base_dir, "seen_ids.bin" });

        // Ensure directories exist
        std.fs.cwd().makePath(state_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        return DailyLimiter{
            .allocator = allocator,
            .state_dir = state_dir,
            .seen_ids_file = seen_ids_file,
            .group_name = group_name,
            .day_start_hour = day_start_hour,
            .fetch_interval_days = fetch_interval_days,
        };
    }

    pub fn deinit(self: DailyLimiter) void {
        self.allocator.free(self.state_dir);
        self.allocator.free(self.seen_ids_file);
    }

    /// Load history based on chronological fetch order (0 = latest, -1 = previous run, etc.)
    pub fn loadRunByOffset(self: DailyLimiter, offset: i32) !types.LastRunState {
        // 1. Collect all history files for this group
        var history_dir = std.fs.cwd().openDir(self.state_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return types.LastRunState{}, // No history exists
            else => return err,
        };
        defer history_dir.close();

        var file_list = std.array_list.Managed([]u8).init(self.allocator);
        defer {
            for (file_list.items) |name| self.allocator.free(name);
            file_list.deinit();
        }

        const group_prefix = try std.fmt.allocPrint(self.allocator, "{s}_", .{self.group_name});
        defer self.allocator.free(group_prefix);

        var iterator = history_dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                if (std.mem.startsWith(u8, entry.name, group_prefix)) {
                    // Ensure valid format {group}_{YYYY-MM-DD}.json
                    if (entry.name.len > group_prefix.len and std.ascii.isDigit(entry.name[group_prefix.len])) {
                        try file_list.append(try self.allocator.dupe(u8, entry.name));
                    }
                }
            }
        }

        // 2. Sort files descending (Newest first: 2025-12-08, 2025-12-07...)
        std.mem.sort([]u8, file_list.items, {}, struct {
            fn greaterThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .gt;
            }
        }.greaterThan);

        // 3. Calculate target index
        // offset is usually negative (e.g., -1). We want index 1.
        // If offset is positive (e.g., 0), we want index 0.
        const target_index: usize = @abs(offset);

        if (target_index >= file_list.items.len) {
            // Offset goes further back than we have history
            return types.LastRunState{};
        }

        const target_file = file_list.items[target_index];

        // Extract date from filename: {group}_{YYYY-MM-DD}.json
        const date_start = group_prefix.len;
        const date_end = target_file.len - 5; // Remove ".json"
        const file_date = if (date_end > date_start)
            try self.allocator.dupe(u8, target_file[date_start..date_end])
        else
            null;
        errdefer if (file_date) |fd| self.allocator.free(fd);

        var state = try self.loadStateFromDir(history_dir, target_file);
        state.file_date = file_date;
        return state;
    }

    fn loadState(self: DailyLimiter) !types.LastRunState {
        const filename = try self.getStateFilePath();
        defer self.allocator.free(filename);
        return try self.loadStateFromFile(filename);
    }

    fn parseStateFile(self: DailyLimiter, file: std.fs.File) !types.LastRunState {
        const file_size = try file.getEndPos();
        // Handle empty files robustly
        if (file_size == 0) return types.LastRunState{};

        const contents = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(contents);
        _ = try file.readAll(contents);

        const RawRssItem = struct {
            title: ?[]const u8 = null,
            description: ?[]const u8 = null,
            link: ?[]const u8 = null,
            pubDate: ?[]const u8 = null,
            guid: ?[]const u8 = null,
            feedName: ?[]const u8 = null,
        };

        const RawLastRunState = struct {
            timestamp: ?i64 = null,
            items: ?[]RawRssItem = null,
        };

        const parsed = std.json.parseFromSlice(RawLastRunState, self.allocator, contents, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            std.debug.print("Error parsing history file: {}\n", .{err});
            return types.LastRunState{};
        };
        defer parsed.deinit();

        // Convert raw items to typed RssItems, duplicating strings so they survive deinit
        var items_list = std.array_list.Managed(types.RssItem).init(self.allocator);
        defer items_list.deinit();
        errdefer {
            for (items_list.items) |item| item.deinit(self.allocator);
        }

        if (parsed.value.items) |raw_items| {
            for (raw_items) |raw_item| {
                const title = if (raw_item.title) |t| try self.allocator.dupe(u8, t) else null;
                errdefer if (title) |t| self.allocator.free(t);

                const description = if (raw_item.description) |d| try self.allocator.dupe(u8, d) else null;
                errdefer if (description) |d| self.allocator.free(d);

                const link = if (raw_item.link) |l| try self.allocator.dupe(u8, l) else null;
                errdefer if (link) |l| self.allocator.free(l);

                const pubDate = if (raw_item.pubDate) |p| try self.allocator.dupe(u8, p) else null;
                errdefer if (pubDate) |p| self.allocator.free(p);

                const guid = if (raw_item.guid) |g| try self.allocator.dupe(u8, g) else null;
                errdefer if (guid) |g| self.allocator.free(g);

                const feedName = if (raw_item.feedName) |f| try self.allocator.dupe(u8, f) else null;
                errdefer if (feedName) |f| self.allocator.free(f);

                // Use robust timestamp parsing that handles null pubDate
                const timestamp = if (pubDate) |pd| RssReader.parseDateString(pd) catch blk: {
                    // Use current time for malformed dates when loading from history
                    break :blk @as(i64, @intCast(std.time.timestamp()));
                } else 0;

                try items_list.append(types.RssItem{
                    .title = title,
                    .description = description,
                    .link = link,
                    .pubDate = pubDate,
                    .timestamp = timestamp,
                    .guid = guid,
                    .feedName = feedName,
                });
            }
        }

        const owned_items = try items_list.toOwnedSlice();
        return types.LastRunState{
            .timestamp = parsed.value.timestamp,
            .items = owned_items,
        };
    }

    fn loadStateFromFile(self: DailyLimiter, filename: []const u8) !types.LastRunState {
        const file = std.fs.cwd().openFile(filename, .{}) catch |err| switch (err) {
            error.FileNotFound => return types.LastRunState{},
            else => return err,
        };
        defer file.close();

        return try self.parseStateFile(file);
    }

    fn loadStateFromDir(self: DailyLimiter, dir: std.fs.Dir, filename: []const u8) !types.LastRunState {
        const file = dir.openFile(filename, .{}) catch |err| switch (err) {
            error.FileNotFound => return types.LastRunState{},
            else => return err,
        };
        defer file.close();

        return try self.parseStateFile(file);
    }

    pub fn saveDay(self: DailyLimiter, items: []const types.RssItem) !void {
        const timestamp = std.time.timestamp();
        const filename = try self.getStateFilePath();
        defer self.allocator.free(filename);

        const json_string = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(types.LastRunState{
            .timestamp = timestamp,
            .items = items,
        }, .{ .whitespace = .indent_2 })});
        defer self.allocator.free(json_string);

        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();
        try file.writeAll(json_string);
    }

    /// Format current local date as YYYY-MM-DD into a provided buffer
    /// Returns the slice of the buffer that was written to
    fn formatCurrentLocalDate(self: DailyLimiter, buf: *[32]u8) ![]u8 {
        // Get current datetime in local timezone
        var local_tz = try zdt.Timezone.tzLocal(self.allocator);
        defer local_tz.deinit();
        var now = try zdt.Datetime.now(.{ .tz = &local_tz });

        // Effect of day start hour: if it's 4 AM, and now is 3 AM, we are in previous day.
        // So we subtract the start hour offset to shift the "logical" time back.
        if (self.day_start_hour > 0) {
            const hour_offset: i64 = -@as(i64, @intCast(self.day_start_hour));
            const duration = zdt.Duration.fromTimespanMultiple(hour_offset, .hour);
            now = try now.add(duration);
        }

        // Format in YYYY-MM-DD exactly (10 bytes), using larger buffer for safety
        // Use @abs to avoid + sign from zdt positive number formatting
        const result = try std.fmt.bufPrint(
            buf,
            "{d:0>4}-{d:0>2}-{d:0>2}",
            .{ @abs(now.year), @as(u5, @intCast(now.month)), @as(u5, @intCast(now.day)) },
        );
        return result;
    }

    fn getStateFilePath(self: DailyLimiter) ![]u8 {
        var date_buf: [32]u8 = undefined;
        const date_str = try self.formatCurrentLocalDate(&date_buf);

        // Build filename into a larger buffer: group_name + "_" + date + ".json"
        var filename_buf: [256]u8 = undefined;
        const filename_only = try std.fmt.bufPrint(&filename_buf, "{s}_{s}.json", .{ self.group_name, date_str });

        return try std.fs.path.join(self.allocator, &.{ self.state_dir, filename_only });
    }

    pub fn reset(self: DailyLimiter) !void {
        const filename = try self.getStateFilePath();
        defer self.allocator.free(filename);

        std.fs.cwd().deleteFile(filename) catch |err| switch (err) {
            error.FileNotFound => {}, // Already doesn't exist
            else => return err,
        };
    }

    pub fn isWithinFetchInterval(self: DailyLimiter) !bool {
        // If interval is 0, we always fetch
        if (self.fetch_interval_days == 0) return false;

        const latest_file = (try self.getLatestHistoryFileName()) orelse return false; // No history, must fetch
        defer self.allocator.free(latest_file);

        // Parse date from filename: {group}_YYYY-MM-DD.json
        const group_prefix_len = self.group_name.len + 1; // name + "_"
        if (latest_file.len < group_prefix_len + 10) return false;

        const date_str = latest_file[group_prefix_len .. group_prefix_len + 10];

        // Parse latest date
        const ly = try std.fmt.parseInt(i32, date_str[0..4], 10);
        const lm = try std.fmt.parseInt(i32, date_str[5..7], 10);
        const ld = try std.fmt.parseInt(i32, date_str[8..10], 10);
        const latest_rd = dateToRataDie(ly, lm, ld);

        // Get current logical date
        var current_buf: [32]u8 = undefined;
        const current_date_str = try self.formatCurrentLocalDate(&current_buf);
        const cy = try std.fmt.parseInt(i32, current_date_str[0..4], 10);
        const cm = try std.fmt.parseInt(i32, current_date_str[5..7], 10);
        const cd = try std.fmt.parseInt(i32, current_date_str[8..10], 10);
        const current_rd = dateToRataDie(cy, cm, cd);

        const diff = current_rd - latest_rd;
        return diff < self.fetch_interval_days;
    }

    pub fn loadLatestRun(self: DailyLimiter) !types.LastRunState {
        const latest_file = (try self.getLatestHistoryFileName()) orelse return error.FileNotFound;
        defer self.allocator.free(latest_file);

        // We need full path
        const full_path = try std.fs.path.join(self.allocator, &.{ self.state_dir, latest_file });
        defer self.allocator.free(full_path);

        return try self.loadStateFromFile(full_path);
    }

    fn getLatestHistoryFileName(self: DailyLimiter) !?[]u8 {
        var history_dir = std.fs.cwd().openDir(self.state_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer history_dir.close();

        const group_prefix = try std.fmt.allocPrint(self.allocator, "{s}_", .{self.group_name});
        defer self.allocator.free(group_prefix);

        var latest_filename: ?[]u8 = null;

        var iterator = history_dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                if (std.mem.startsWith(u8, entry.name, group_prefix)) {
                    // Check strict prefix + digit to avoid prefix conflicts
                    if (entry.name.len > group_prefix.len and std.ascii.isDigit(entry.name[group_prefix.len])) {
                        if (latest_filename) |existing| {
                            if (std.mem.order(u8, entry.name, existing) == .gt) {
                                // Found a newer file
                                self.allocator.free(existing);
                                latest_filename = try self.allocator.dupe(u8, entry.name);
                            }
                        } else {
                            latest_filename = try self.allocator.dupe(u8, entry.name);
                        }
                    }
                }
            }
        }
        return latest_filename;
    }

    fn dateToRataDie(year: i32, month: i32, day: i32) i32 {
        var y = year;
        var m = month;
        if (m < 3) {
            y -= 1;
            m += 12;
        }
        return 365 * y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400) + @divFloor(153 * m - 457, 5) + day - 306;
    }

    /// Calculate how many days ago a date string (YYYY-MM-DD) is from today
    /// Returns the number of days difference (0 = today, 1 = yesterday, etc.)
    pub fn daysAgoFromDateString(self: DailyLimiter, date_str: []const u8) !i32 {
        if (date_str.len < 10) return error.InvalidDateFormat;

        // Parse date from string: YYYY-MM-DD
        const file_year = try std.fmt.parseInt(i32, date_str[0..4], 10);
        const file_month = try std.fmt.parseInt(i32, date_str[5..7], 10);
        const file_day = try std.fmt.parseInt(i32, date_str[8..10], 10);
        const file_rd = dateToRataDie(file_year, file_month, file_day);

        // Get current logical date (accounting for day start hour)
        var current_buf: [32]u8 = undefined;
        const current_date_str = try self.formatCurrentLocalDate(&current_buf);
        const cy = try std.fmt.parseInt(i32, current_date_str[0..4], 10);
        const cm = try std.fmt.parseInt(i32, current_date_str[5..7], 10);
        const cd = try std.fmt.parseInt(i32, current_date_str[8..10], 10);
        const current_rd = dateToRataDie(cy, cm, cd);

        return current_rd - file_rd;
    }

    /// Load seen article hashes from persistent binary storage
    /// File format: entries of (u32 timestamp | u64 hash) = 12 bytes each
    /// Returns a HashMap of hashes (timestamps are filtered during load, see pruneSeen)
    pub fn loadSeenHashes(self: DailyLimiter) !std.AutoHashMap(u64, void) {
        var seen_hashes = std.AutoHashMap(u64, void).init(self.allocator);

        const file = std.fs.cwd().openFile(self.seen_ids_file, .{}) catch |err| switch (err) {
            error.FileNotFound => return seen_hashes, // Return empty map if file doesn't exist
            else => return err,
        };
        defer file.close();

        const file_size = try file.getEndPos();
        if (file_size == 0) return seen_hashes;

        // File should contain (timestamp + hash) pairs: 4 + 8 = 12 bytes each
        const entry_size = 4 + 8; // u32 + u64
        const entry_count = file_size / entry_size;
        if (file_size % entry_size != 0) {
            // Reset the file if corrupted, otherwise it stays corrupted forever
            std.debug.print("Warning: Deduplication file corrupted. Resetting.\n", .{});
            file.close();
            try std.fs.cwd().deleteFile(self.seen_ids_file);
            return seen_hashes;
        }

        try seen_hashes.ensureTotalCapacity(@intCast(entry_count));

        var i: usize = 0;
        while (i < entry_count) : (i += 1) {
            var entry_bytes: [12]u8 = undefined;
            const bytes_read = try file.readAll(&entry_bytes);
            if (bytes_read < 12) break; // EOF or incomplete read

            // Skip timestamp (first 4 bytes), extract hash (next 8 bytes)
            const hash = std.mem.readInt(u64, entry_bytes[4..12], .little);
            seen_hashes.putAssumeCapacity(hash, {});
        }

        return seen_hashes;
    }

    /// Save new article hashes to persistent binary storage with timestamps
    /// Format: each entry is (u32 timestamp | u64 hash) = 12 bytes
    pub fn saveNewHashes(self: DailyLimiter, new_hashes: []const u64) !void {
        if (new_hashes.len == 0) return;

        const file = std.fs.cwd().openFile(self.seen_ids_file, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.fs.cwd().createFile(self.seen_ids_file, .{}),
            else => return err,
        };
        defer file.close();

        // Seek to end of file to append
        try file.seekFromEnd(0);

        // Get current timestamp (limited to u32 for 136-year range, sufficient until year 2106)
        // Handle negative timestamps gracefully (system clock skew before 1970)
        // Also cap at u32 max to prevent silent overflow beyond year 2106
        const ts_i64 = std.time.timestamp();
        const ts_u64: u64 = if (ts_i64 < 0) 0 else @intCast(ts_i64);
        const now_timestamp = @as(u32, @min(ts_u64, std.math.maxInt(u32)));

        // Write each hash with its timestamp
        for (new_hashes) |hash| {
            var entry_bytes: [12]u8 = undefined;
            std.mem.writeInt(u32, entry_bytes[0..4], now_timestamp, .little);
            std.mem.writeInt(u64, entry_bytes[4..12], hash, .little);
            try file.writeAll(&entry_bytes);
        }
    }

    /// Remove old history files based on retention policy (group-specific)
    /// Deletes files with dates older than (now - retention_days)
    pub fn pruneHistory(self: DailyLimiter, retention_days: u32) !void {
        var history_dir = std.fs.cwd().openDir(self.state_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return, // Directory doesn't exist, nothing to prune
            else => return err,
        };
        defer history_dir.close();

        var file_list = std.array_list.Managed([]u8).init(self.allocator);
        defer {
            for (file_list.items) |filename| {
                self.allocator.free(filename);
            }
            file_list.deinit();
        }

        // Collect JSON files for this specific group
        const group_prefix = try std.fmt.allocPrint(self.allocator, "{s}_", .{self.group_name});
        defer self.allocator.free(group_prefix);

        var iterator = history_dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                if (std.mem.startsWith(u8, entry.name, group_prefix)) {
                    // Ensure the character immediately after the prefix is a digit (start of YYYY)
                    // to avoid matching group names that are substrings of others (e.g., "tech" vs "tech_news")
                    if (entry.name.len > group_prefix.len and std.ascii.isDigit(entry.name[group_prefix.len])) {
                        const filename = try self.allocator.dupe(u8, entry.name);
                        try file_list.append(filename);
                    }
                }
            }
        }

        // Calculate cutoff date: now - retention_days
        var local_tz = try zdt.Timezone.tzLocal(self.allocator);
        defer local_tz.deinit();
        var now = try zdt.Datetime.now(.{ .tz = &local_tz });

        if (self.day_start_hour > 0) {
            const hour_offset: i64 = -@as(i64, @intCast(self.day_start_hour));
            const duration = zdt.Duration.fromTimespanMultiple(hour_offset, .hour);
            now = try now.add(duration);
        }

        const day_duration = zdt.Duration.fromTimespanMultiple(-@as(i64, @intCast(retention_days)), .day);
        const cutoff = try now.add(day_duration);
        // Use @abs to avoid + sign from zdt positive number formatting
        var cutoff_date_buf: [32]u8 = undefined;
        const cutoff_date_str = try std.fmt.bufPrint(
            &cutoff_date_buf,
            "{d:0>4}-{d:0>2}-{d:0>2}",
            .{ @abs(cutoff.year), @as(u5, @intCast(cutoff.month)), @as(u5, @intCast(cutoff.day)) },
        );

        // Delete files with dates older than cutoff
        for (file_list.items) |filename| {
            // Extract date from filename: {group}_YYYY-MM-DD.json
            // Date starts after group_prefix and is 10 characters long (YYYY-MM-DD)
            if (filename.len > group_prefix.len + 10) {
                const date_start = group_prefix.len;
                const date_end = date_start + 10;
                const file_date = filename[date_start..date_end];

                // Compare dates lexicographically (YYYY-MM-DD format sorts correctly)
                if (std.mem.order(u8, file_date, cutoff_date_str) == .lt) {
                    _ = history_dir.deleteFile(filename) catch {};
                    // Non-critical error, silently continue
                }
            }
        }
    }

    /// Prune old hashes from seen_ids.bin based on retention policy
    /// File format: entries of (u32 timestamp | u64 hash) = 12 bytes each
    /// Only keeps entries newer than (now - retention_days)
    pub fn pruneSeen(self: DailyLimiter, retention_days: u32) !void {
        const file = std.fs.cwd().openFile(self.seen_ids_file, .{}) catch |err| switch (err) {
            error.FileNotFound => return, // File doesn't exist, nothing to prune
            else => return err,
        };
        defer file.close();

        const file_size = try file.getEndPos();
        if (file_size == 0) return; // Empty file, nothing to prune

        // File should contain (timestamp + hash) pairs: 4 + 8 = 12 bytes each
        const entry_size = 4 + 8; // u32 + u64
        const entry_count = file_size / entry_size;
        if (file_size % entry_size != 0) {
            // File is corrupted, delete it to reset
            try std.fs.cwd().deleteFile(self.seen_ids_file);
            return;
        }

        // Calculate cutoff timestamp (current time - retention_days)
        const now_timestamp = @as(u64, @intCast(std.time.timestamp()));
        const retention_seconds = @as(u64, retention_days) * 24 * 60 * 60;
        const cutoff_timestamp = if (now_timestamp > retention_seconds)
            @as(u32, @truncate(now_timestamp - retention_seconds))
        else
            0; // If retention_seconds is larger than now_timestamp, keep everything

        // Read all entries and filter
        var valid_entries = std.array_list.Managed([12]u8).init(self.allocator);
        defer valid_entries.deinit();

        try file.seekTo(0);
        var i: usize = 0;
        while (i < entry_count) : (i += 1) {
            var entry_bytes: [12]u8 = undefined;
            const bytes_read = try file.readAll(&entry_bytes);
            if (bytes_read < 12) break; // EOF or incomplete read

            const timestamp = std.mem.readInt(u32, entry_bytes[0..4], .little);

            // Keep entries that are newer than cutoff or if they're at the boundary
            if (timestamp >= cutoff_timestamp) {
                try valid_entries.append(entry_bytes);
            }
        }

        // If nothing was pruned, no need to rewrite
        if (valid_entries.items.len == entry_count) {
            return;
        }

        // Rewrite file with only valid entries
        file.close();
        var write_file = try std.fs.cwd().createFile(self.seen_ids_file, .{});
        defer write_file.close();

        for (valid_entries.items) |entry| {
            try write_file.writeAll(&entry);
        }
    }
};
