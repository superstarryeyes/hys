const std = @import("std");
const types = @import("types");
const rss_reader = @import("rss_reader");
const FeedGroupManager = @import("feed_group_manager").FeedGroupManager;

/// ConfigManager error set - domain-specific errors for configuration operations
pub const ConfigError = error{
    /// Configuration directory cannot be created
    DirectoryCreationFailed,
    /// Configuration file cannot be read or opened
    ConfigReadFailed,
    /// Configuration file contains invalid JSON
    ParseFailed,
    /// Feed already exists in configuration
    FeedAlreadyExists,
    /// Configuration file cannot be written
    ConfigWriteFailed,
    /// Memory allocation failed
    OutOfMemory,
};

// ANSI Colors
pub const COLORS = struct {
    pub const RESET = "\x1b[0m";
    pub const BOLD = "\x1b[1m";
    pub const RED = "\x1b[31m";
    pub const GREEN = "\x1b[32m";
    pub const YELLOW = "\x1b[33m";
    pub const BLUE = "\x1b[34m";
    pub const CYAN = "\x1b[36m";
    pub const GRAY = "\x1b[90m";
    pub const ORANGE = "\x1b[38;5;208m";
    pub const UNDERLINE = "\x1b[4m";
    pub const NO_UNDERLINE = "\x1b[24m";
};

// Braille animation frames
pub const BRAILLE_ANIMATION = [_][]const u8{
    "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
};

/// ConfigManager handles loading, saving, and managing the global application config.
/// OWNERSHIP REQUIREMENT: config_dir and config_file must be owned by the allocator.
/// Both are allocated with std.fs.path.join() which uses the provided allocator.
pub const ConfigManager = struct {
    allocator: std.mem.Allocator,
    config_dir: []u8,
    config_file: []u8,
    feed_group_manager: FeedGroupManager,

    pub fn init(allocator: std.mem.Allocator) !ConfigManager {
        const home_dir = std.posix.getenv("HOME") orelse std.posix.getenv("USERPROFILE") orelse ".";
        const config_dir = try std.fs.path.join(allocator, &.{ home_dir, ".hys" });
        const config_file = try std.fs.path.join(allocator, &.{ config_dir, "config.json" });

        var manager = ConfigManager{
            .allocator = allocator,
            .config_dir = config_dir,
            .config_file = config_file,
            .feed_group_manager = try FeedGroupManager.init(allocator, config_dir),
        };

        try manager.ensureConfigDir();
        return manager;
    }

    pub fn deinit(self: ConfigManager) void {
        self.feed_group_manager.deinit();
        self.allocator.free(self.config_dir);
        self.allocator.free(self.config_file);
    }

    fn ensureConfigDir(self: ConfigManager) ConfigError!void {
        std.fs.cwd().makePath(self.config_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return ConfigError.DirectoryCreationFailed,
        };
    }

    /// Load global configuration (display and history settings only)
    pub fn loadGlobalConfig(self: ConfigManager) ConfigError!types.GlobalConfig {
        const file = std.fs.cwd().openFile(self.config_file, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                const default_config = ConfigManager.defaultGlobalConfig();
                try self.saveGlobalConfig(default_config);
                return default_config;
            },
            else => return ConfigError.ConfigReadFailed,
        };
        defer file.close();

        const file_size = file.getEndPos() catch return ConfigError.ConfigReadFailed;
        const contents = self.allocator.alloc(u8, file_size) catch return ConfigError.ConfigReadFailed;
        defer self.allocator.free(contents);
        _ = file.readAll(contents) catch return ConfigError.ConfigReadFailed;

        return self.parseGlobalConfig(contents);
    }

    fn defaultGlobalConfig() types.GlobalConfig {
        return .{
            .display = .{},
            .history = .{},
            .network = .{},
        };
    }

    fn parseGlobalConfig(self: ConfigManager, contents: []const u8) ConfigError!types.GlobalConfig {
        const RawConfig = struct {
            display: ?types.DisplayConfig = null,
            history: ?types.HistoryConfig = null,
            network: ?types.NetworkConfig = null,
        };

        // Use arena for JSON parsing to simplify cleanup
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(RawConfig, arena.allocator(), contents, .{
            .ignore_unknown_fields = true,
        }) catch return ConfigError.ParseFailed;
        defer parsed.deinit();

        return types.GlobalConfig{
            .display = parsed.value.display orelse types.DisplayConfig{},
            .history = parsed.value.history orelse types.HistoryConfig{},
            .network = parsed.value.network orelse types.NetworkConfig{},
        };
    }

    pub fn saveGlobalConfig(self: ConfigManager, config: types.GlobalConfig) ConfigError!void {
        const json_string = std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(config, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        })}) catch return ConfigError.ConfigWriteFailed;
        defer self.allocator.free(json_string);

        const file = std.fs.cwd().createFile(self.config_file, .{}) catch return ConfigError.ConfigWriteFailed;
        defer file.close();
        file.writeAll(json_string) catch return ConfigError.ConfigWriteFailed;
    }

    pub fn getConfigPath(self: ConfigManager) []const u8 {
        return self.config_file;
    }

    /// Add feed to a specific group (defaults to "main")
    pub fn addFeed(self: ConfigManager, url: []const u8, name: ?[]const u8) !void {
        return self.addFeedToGroup("main", url, name);
    }

    /// Add feed to a specific group
    pub fn addFeedToGroup(self: ConfigManager, group_name: []const u8, url: []const u8, name: ?[]const u8) !void {
        return self.feed_group_manager.addFeedToGroup(group_name, url, name);
    }

    /// Add a feed config (with all metadata) to a specific group
    pub fn addFeedConfigToGroup(self: ConfigManager, group_name: []const u8, feed_config: types.FeedConfig) !void {
        return self.feed_group_manager.addFeedConfigToGroup(group_name, feed_config);
    }

    /// Get enabled feeds from a specific group (defaults to "main")
    pub fn getEnabledFeeds(self: ConfigManager) !types.FeedList {
        return self.getEnabledFeedsFromGroup("main");
    }

    /// Get enabled feeds from a specific group
    pub fn getEnabledFeedsFromGroup(self: ConfigManager, group_name: []const u8) !types.FeedList {
        return self.feed_group_manager.getEnabledFeeds(group_name);
    }

    /// Check if a feed group exists
    pub fn groupExists(self: ConfigManager, group_name: []const u8) bool {
        return self.feed_group_manager.groupExists(group_name);
    }

    /// Get the display name of a group
    pub fn getGroupDisplayName(self: ConfigManager, group_name: []const u8) !?[]const u8 {
        return self.feed_group_manager.getGroupDisplayName(group_name);
    }

    /// Set the display name of a group
    pub fn setGroupDisplayName(self: ConfigManager, group_name: []const u8, display_name: ?[]const u8) !void {
        return self.feed_group_manager.setGroupDisplayName(group_name, display_name);
    }

    /// Load a complete feed group with metadata
    pub fn loadGroupWithMetadata(self: ConfigManager, group_name: []const u8) !types.FeedGroup {
        return self.feed_group_manager.loadGroupWithMetadata(group_name);
    }

    /// Get all available feed group names
    pub fn getAllGroupNames(self: ConfigManager) ![]const []const u8 {
        return self.feed_group_manager.getAllGroupNames();
    }
};
