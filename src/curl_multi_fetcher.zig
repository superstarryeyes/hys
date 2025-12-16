/// High-performance batch feed fetcher using libcurl's multi interface.
/// This enables connection pooling, HTTP/2 multiplexing, and efficient parallel downloads.
const std = @import("std");
const types = @import("types");

const curl = @cImport({
    @cInclude("curl/curl.h");
});

pub const FetchStatus = enum {
    Success, // 200 OK with content
    NotModified, // 304 Not Modified
    Failed, // Any error condition
};

pub const FetchResult = struct {
    url: []const u8,
    data: ?[]u8,
    err: ?FetchError,
    status: FetchStatus = .Failed,
    // New headers from response to save for next request
    new_etag: ?[]u8 = null,
    new_last_modified: ?[]u8 = null,
};

pub const FetchError = error{
    NetworkError,
    HttpError,
    OutOfMemory,
    CurlFailed,
    Timeout,
    InvalidUtf8,
};

/// Context for each individual transfer
const TransferContext = struct {
    allocator: std.mem.Allocator,
    buffer: std.array_list.Managed(u8),
    url: []const u8,
    max_bytes: usize,
    exceeded_limit: bool,
    curl_error: bool,
    oom_detected: bool,
    utf8_error: bool = false, // UTF-8 validation error
    http_code: c_long = 0, // HTTP status code from response
    // Header parsing buffers
    etag_buffer: ?[]u8 = null,
    last_modified_buffer: ?[]u8 = null,
    header_list: ?*curl.curl_slist = null, // For freeing custom headers
    // UTF-8 validation state for streaming validation
    partial_sequence: [4]u8 = undefined, // Buffer for incomplete UTF-8 sequences
    partial_len: u8 = 0, // Number of bytes in partial_sequence

    fn init(allocator: std.mem.Allocator, url: []const u8, max_bytes: usize) TransferContext {
        return .{
            .allocator = allocator,
            .buffer = std.array_list.Managed(u8).init(allocator),
            .url = url,
            .max_bytes = max_bytes,
            .exceeded_limit = false,
            .curl_error = false,
            .oom_detected = false,
            .utf8_error = false,
            .http_code = 0,
            .etag_buffer = null,
            .last_modified_buffer = null,
            .header_list = null,
            .partial_sequence = undefined,
            .partial_len = 0,
        };
    }

    fn deinit(self: *TransferContext) void {
        self.buffer.deinit();
        if (self.header_list) |list| {
            curl.curl_slist_free_all(list);
        }
        if (self.etag_buffer) |buf| self.allocator.free(buf);
        if (self.last_modified_buffer) |buf| self.allocator.free(buf);
    }
};

/// Callback-based fetch for streaming pipeline integration
pub const FetchCallback = *const fn (
    result: *FetchResult,
    index: usize,
    user_data: *anyopaque,
) void;

/// Helper function to build a FetchResult from a TransferContext with HTTP status
fn buildTransferResultWithStatus(
    allocator: std.mem.Allocator,
    url: []const u8,
    ctx: *TransferContext,
    out_result: *FetchResult,
) void {
    _ = allocator; // Not used in this version

    // Handle HTTP 304 Not Modified
    if (ctx.http_code == 304) {
        out_result.* = .{
            .url = url,
            .data = null,
            .err = null,
            .status = .NotModified,
            .new_etag = ctx.etag_buffer,
            .new_last_modified = ctx.last_modified_buffer,
        };
        ctx.etag_buffer = null;
        ctx.last_modified_buffer = null;
        ctx.deinit();
        return;
    }

    // Handle errors
    if (ctx.utf8_error or ctx.curl_error or (ctx.http_code >= 400 and !(ctx.exceeded_limit and ctx.buffer.items.len > 0))) {
        out_result.* = .{
            .url = url,
            .data = null,
            .err = if (ctx.utf8_error) FetchError.InvalidUtf8 else if (ctx.http_code >= 400) FetchError.HttpError else if (ctx.oom_detected) FetchError.OutOfMemory else FetchError.NetworkError,
            .status = .Failed,
        };
        ctx.deinit();
        return;
    }

    // Handle empty response
    if (ctx.buffer.items.len == 0) {
        out_result.* = .{
            .url = url,
            .data = null,
            .err = FetchError.NetworkError,
            .status = .Failed,
        };
        ctx.deinit();
        return;
    }

    // Handle success with data
    const data = ctx.buffer.toOwnedSlice() catch {
        out_result.* = .{
            .url = url,
            .data = null,
            .err = FetchError.OutOfMemory,
            .status = .Failed,
        };
        ctx.deinit();
        return;
    };

    out_result.* = .{
        .url = url,
        .data = data,
        .err = null,
        .status = .Success,
        .new_etag = ctx.etag_buffer,
        .new_last_modified = ctx.last_modified_buffer,
    };
    ctx.etag_buffer = null;
    ctx.last_modified_buffer = null;
    ctx.deinit();
}

/// Batch fetch multiple feeds using curl_multi for connection pooling
/// If callback is provided, invokes it as each transfer completes (enables pipelining)
pub fn fetchMultiple(
    allocator: std.mem.Allocator,
    feeds: []const types.FeedConfig,
    max_feed_size_mb: f64,
) ![]FetchResult {
    return fetchMultipleWithCallback(allocator, feeds, max_feed_size_mb, null, null);
}

/// Fetch with callback for each completed transfer (for pipelining)
pub fn fetchMultipleWithCallback(
    allocator: std.mem.Allocator,
    feeds: []const types.FeedConfig,
    max_feed_size_mb: f64,
    callback: ?FetchCallback,
    callback_user_data: ?*anyopaque,
) ![]FetchResult {
    const max_bytes: usize = @intFromFloat(max_feed_size_mb * 1024 * 1024);

    // Initialize multi handle
    const multi_handle = curl.curl_multi_init() orelse return error.OutOfMemory;
    defer _ = curl.curl_multi_cleanup(multi_handle);

    // Configure multi handle for maximum parallelism
    _ = curl.curl_multi_setopt(multi_handle, curl.CURLMOPT_MAX_TOTAL_CONNECTIONS, @as(c_long, 50));
    _ = curl.curl_multi_setopt(multi_handle, curl.CURLMOPT_MAX_HOST_CONNECTIONS, @as(c_long, 6));
    _ = curl.curl_multi_setopt(multi_handle, curl.CURLMOPT_PIPELINING, @as(c_long, curl.CURLPIPE_MULTIPLEX));

    // Allocate contexts and results
    var contexts = try allocator.alloc(TransferContext, feeds.len);
    errdefer allocator.free(contexts);

    // Initialize all contexts with empty/valid state upfront
    // This prevents deinit() from being called on uninitialized memory in the errdefer block
    for (contexts) |*ctx| {
        ctx.* = .{
            .allocator = allocator,
            .buffer = std.array_list.Managed(u8).init(allocator),
            .url = "",
            .max_bytes = max_bytes,
            .exceeded_limit = false,
            .curl_error = false,
            .oom_detected = false,
            .utf8_error = false,
            .http_code = 0,
            .etag_buffer = null,
            .last_modified_buffer = null,
            .header_list = null,
            .partial_sequence = undefined,
            .partial_len = 0,
        };
    }

    var easy_handles = try allocator.alloc(?*curl.CURL, feeds.len);
    errdefer allocator.free(easy_handles);

    var url_zs = try allocator.alloc(?[:0]u8, feeds.len);
    errdefer allocator.free(url_zs);

    // Error cleanup block
    errdefer {
        for (easy_handles) |maybe_easy| {
            if (maybe_easy) |easy| {
                _ = curl.curl_multi_remove_handle(multi_handle, easy);
                curl.curl_easy_cleanup(easy);
            }
        }
        for (url_zs) |maybe_z| {
            if (maybe_z) |z| allocator.free(z);
        }
        for (contexts) |*ctx| {
            ctx.deinit();
        }
    }

    // Initialize all transfers
    for (feeds, 0..) |feed, i| {
        const url = feed.xmlUrl;
        contexts[i].url = url;
        easy_handles[i] = null;
        url_zs[i] = null;

        // Create null-terminated URL
        const url_z = allocator.allocSentinel(u8, url.len, 0) catch {
            contexts[i].curl_error = true;
            continue;
        };
        @memcpy(url_z[0..url.len], url);
        url_z[url.len] = 0; // Explicitly set sentinel
        url_zs[i] = url_z;

        // Create easy handle
        const easy = curl.curl_easy_init() orelse {
            contexts[i].curl_error = true;
            continue;
        };
        easy_handles[i] = easy;

        // Configure the easy handle
        _ = curl.curl_easy_setopt(easy, curl.CURLOPT_URL, url_z.ptr);
        _ = curl.curl_easy_setopt(easy, curl.CURLOPT_WRITEFUNCTION, @as(curl.curl_write_callback, @ptrCast(&writeCallback)));
        _ = curl.curl_easy_setopt(easy, curl.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&contexts[i])));
        _ = curl.curl_easy_setopt(easy, curl.CURLOPT_PRIVATE, @as(*anyopaque, @ptrCast(&contexts[i])));

        // Set header callback for parsing ETag and Last-Modified
        _ = curl.curl_easy_setopt(easy, curl.CURLOPT_HEADERFUNCTION, @as(curl.curl_write_callback, @ptrCast(&headerCallback)));
        _ = curl.curl_easy_setopt(easy, curl.CURLOPT_HEADERDATA, @as(*anyopaque, @ptrCast(&contexts[i])));

        // Add Conditional GET headers if available
        var headers: ?*curl.curl_slist = null;

        if (feed.etag) |etag| {
            const header_str = std.fmt.allocPrint(allocator, "If-None-Match: {s}", .{etag}) catch {
                contexts[i].curl_error = true;
                continue;
            };
            defer allocator.free(header_str);
            const header_z = allocator.dupeZ(u8, header_str) catch {
                contexts[i].curl_error = true;
                continue;
            };
            defer allocator.free(header_z);
            headers = curl.curl_slist_append(headers, header_z.ptr);
        }

        if (feed.lastModified) |lastMod| {
            const header_str = std.fmt.allocPrint(allocator, "If-Modified-Since: {s}", .{lastMod}) catch {
                contexts[i].curl_error = true;
                continue;
            };
            defer allocator.free(header_str);
            const header_z = allocator.dupeZ(u8, header_str) catch {
                contexts[i].curl_error = true;
                continue;
            };
            defer allocator.free(header_z);
            headers = curl.curl_slist_append(headers, header_z.ptr);
        }

        if (headers != null) {
            _ = curl.curl_easy_setopt(easy, curl.CURLOPT_HTTPHEADER, headers);
            contexts[i].header_list = headers; // Store to free later
        }

        // Follow redirects
        _ = curl.curl_easy_setopt(easy, curl.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
        _ = curl.curl_easy_setopt(easy, curl.CURLOPT_MAXREDIRS, @as(c_long, 10));

        // Timeouts
        _ = curl.curl_easy_setopt(easy, curl.CURLOPT_CONNECTTIMEOUT, @as(c_long, 10));
        _ = curl.curl_easy_setopt(easy, curl.CURLOPT_TIMEOUT, @as(c_long, 30));

        // Accept compressed responses
        _ = curl.curl_easy_setopt(easy, curl.CURLOPT_ACCEPT_ENCODING, "");

        // User agent
        _ = curl.curl_easy_setopt(easy, curl.CURLOPT_USERAGENT, "hys-rss/0.1.0");

        // Enable connection pooling and HTTP/2
        _ = curl.curl_easy_setopt(easy, curl.CURLOPT_FRESH_CONNECT, @as(c_long, 0));
        _ = curl.curl_easy_setopt(easy, curl.CURLOPT_HTTP_VERSION, @as(c_long, curl.CURL_HTTP_VERSION_2TLS));
        _ = curl.curl_easy_setopt(easy, curl.CURLOPT_PIPEWAIT, @as(c_long, 1));

        // Use progress callback to abort transfer after we have enough data
        _ = curl.curl_easy_setopt(easy, curl.CURLOPT_NOPROGRESS, @as(c_long, 0));
        _ = curl.curl_easy_setopt(easy, curl.CURLOPT_XFERINFOFUNCTION, @as(?*const fn (ctx: ?*anyopaque, dltotal: c_longlong, dlnow: c_longlong, ultotal: c_longlong, ulnow: c_longlong) callconv(.c) c_int, @ptrCast(&progressCallback)));
        _ = curl.curl_easy_setopt(easy, curl.CURLOPT_XFERINFODATA, @as(*anyopaque, @ptrCast(&contexts[i])));

        // Add to multi handle
        _ = curl.curl_multi_add_handle(multi_handle, easy);
    }

    // Perform all transfers in parallel
    var still_running: c_int = 1;
    var prev_running: c_int = 0;

    // Initial kick to start all transfers
    _ = curl.curl_multi_perform(multi_handle, &still_running);
    prev_running = still_running;

    while (still_running > 0) {
        // Wait for activity on any socket (max 100ms timeout for responsiveness)
        var numfds: c_int = 0;
        const wait_result = curl.curl_multi_poll(multi_handle, null, 0, 100, &numfds);
        if (wait_result != curl.CURLM_OK) break;

        // Drive the transfers forward
        const mc = curl.curl_multi_perform(multi_handle, &still_running);
        if (mc != curl.CURLM_OK) break;

        prev_running = still_running;
    }

    // Allocate results upfront (needed for both callback and non-callback paths)
    var results = try allocator.alloc(FetchResult, feeds.len);

    // Initialize all results to Failed state
    for (feeds, 0..) |feed, i| {
        results[i] = .{
            .url = feed.xmlUrl,
            .data = null,
            .err = FetchError.NetworkError,
            .status = .Failed,
        };
    }

    // Track which transfers have been completed
    var completed_mask = try allocator.alloc(bool, feeds.len);
    defer allocator.free(completed_mask);
    @memset(completed_mask, false);

    // Process completed transfers and check for errors
    var msgs_left: c_int = 0;
    while (true) {
        const msg = curl.curl_multi_info_read(multi_handle, &msgs_left);
        if (msg == null) break;

        if (msg.*.msg == curl.CURLMSG_DONE) {
            const easy = msg.*.easy_handle;
            var p: ?*anyopaque = null;
            _ = curl.curl_easy_getinfo(easy, curl.CURLINFO_PRIVATE, &p);

            if (p) |pval| {
                const ctx: *TransferContext = @ptrCast(@alignCast(pval));

                // Find the index of this context
                var ctx_index: usize = 0;
                for (contexts, 0..) |*c, i| {
                    if (c == ctx) {
                        ctx_index = i;
                        break;
                    }
                }

                // Get HTTP status code
                _ = curl.curl_easy_getinfo(easy, curl.CURLINFO_RESPONSE_CODE, &ctx.http_code);

                // CURLE_ABORTED_BY_CALLBACK is expected when we abort due to size limit
                const curl_result = msg.*.data.result;
                if (curl_result != curl.CURLE_OK and curl_result != curl.CURLE_ABORTED_BY_CALLBACK) {
                    ctx.curl_error = true;
                }
                // If we aborted but have data and exceeded limit, that's success
                if (curl_result == curl.CURLE_ABORTED_BY_CALLBACK and ctx.exceeded_limit and ctx.buffer.items.len > 0) {
                    // This is fine - we intentionally aborted, reset error flag
                    ctx.curl_error = false;
                }

                completed_mask[ctx_index] = true;

                // Build result for this transfer
                var transfer_result: FetchResult = undefined;
                buildTransferResultWithStatus(allocator, feeds[ctx_index].xmlUrl, ctx, &transfer_result);
                results[ctx_index] = transfer_result;

                // If callback provided, invoke it immediately (streaming/pipelining)
                if (callback != null and callback_user_data != null) {
                    callback.?(&results[ctx_index], ctx_index, callback_user_data.?);
                }
            }
        }
    }

    // Cleanup easy handles
    for (easy_handles, 0..) |maybe_easy, i| {
        if (maybe_easy) |easy| {
            _ = curl.curl_multi_remove_handle(multi_handle, easy);
            curl.curl_easy_cleanup(easy);
        }
        if (url_zs[i]) |z| allocator.free(z);
    }

    // We've handled individual deinit/ownership transfer above, just free container arrays
    allocator.free(contexts);
    allocator.free(easy_handles);
    allocator.free(url_zs);

    return results;
}

/// Validate UTF-8 sequence incrementally during streaming.
/// Handles incomplete sequences at chunk boundaries.
/// Returns true if valid, false if invalid UTF-8 detected.
fn validateUtf8Chunk(ctx: *TransferContext, chunk: []const u8) bool {
    var i: usize = 0;

    // First, validate any partial sequence from previous chunk
    if (ctx.partial_len > 0) {
        // Check how many continuation bytes we need
        const first_byte = ctx.partial_sequence[0];
        var expected_len: u8 = 1;
        if ((first_byte & 0xE0) == 0xC0) {
            expected_len = 2;
        } else if ((first_byte & 0xF0) == 0xE0) {
            expected_len = 3;
        } else if ((first_byte & 0xF8) == 0xF0) {
            expected_len = 4;
        } else {
            return false; // Invalid start byte
        }

        // Fill in remaining bytes from current chunk
        while (ctx.partial_len < expected_len and i < chunk.len) {
            const byte = chunk[i];
            if ((byte & 0xC0) != 0x80) return false; // Invalid continuation
            ctx.partial_sequence[ctx.partial_len] = byte;
            ctx.partial_len += 1;
            i += 1;
        }

        // If we still don't have the complete sequence, we're done with this chunk
        if (ctx.partial_len < expected_len) return true;
        ctx.partial_len = 0;
    }

    // Validate rest of chunk
    while (i < chunk.len) {
        const byte = chunk[i];

        if ((byte & 0x80) == 0) {
            // ASCII (0xxxxxxx)
            i += 1;
        } else if ((byte & 0xE0) == 0xC0) {
            // Start of 2-byte sequence (110xxxxx)
            if (i + 1 >= chunk.len) {
                // Incomplete at chunk boundary, save for next chunk
                ctx.partial_sequence[0] = byte;
                ctx.partial_len = 1;
                return true;
            }
            if ((chunk[i + 1] & 0xC0) != 0x80) return false;
            i += 2;
        } else if ((byte & 0xF0) == 0xE0) {
            // Start of 3-byte sequence (1110xxxx)
            if (i + 2 >= chunk.len) {
                // Incomplete at chunk boundary, save for next chunk
                @memcpy(ctx.partial_sequence[0..@min(2, chunk.len - i)], chunk[i..@min(i + 2, chunk.len)]);
                ctx.partial_len = @intCast(@min(2, chunk.len - i));
                return true;
            }
            if ((chunk[i + 1] & 0xC0) != 0x80) return false;
            if ((chunk[i + 2] & 0xC0) != 0x80) return false;
            i += 3;
        } else if ((byte & 0xF8) == 0xF0) {
            // Start of 4-byte sequence (11110xxx)
            if (i + 3 >= chunk.len) {
                // Incomplete at chunk boundary, save for next chunk
                @memcpy(ctx.partial_sequence[0..@min(3, chunk.len - i)], chunk[i..@min(i + 3, chunk.len)]);
                ctx.partial_len = @intCast(@min(3, chunk.len - i));
                return true;
            }
            if ((chunk[i + 1] & 0xC0) != 0x80) return false;
            if ((chunk[i + 2] & 0xC0) != 0x80) return false;
            if ((chunk[i + 3] & 0xC0) != 0x80) return false;
            i += 4;
        } else {
            // Invalid UTF-8
            return false;
        }
    }
    return true;
}

/// Header callback - parses ETag and Last-Modified headers
fn headerCallback(data: [*c]const u8, size: usize, nmemb: usize, user_data: ?*anyopaque) callconv(.c) usize {
    if (user_data == null) return 0;
    const ctx: *TransferContext = @ptrCast(@alignCast(user_data.?));
    const total_size = size * nmemb;
    const line = data[0..total_size];

    // Helper to clean CRLF
    const trimmed = std.mem.trimRight(u8, line, "\r\n ");

    if (std.ascii.startsWithIgnoreCase(trimmed, "ETag:")) {
        if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
            const val = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " ");
            if (ctx.etag_buffer) |old| ctx.allocator.free(old);
            ctx.etag_buffer = ctx.allocator.dupe(u8, val) catch null;
        }
    } else if (std.ascii.startsWithIgnoreCase(trimmed, "Last-Modified:")) {
        if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
            const val = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " ");
            if (ctx.last_modified_buffer) |old| ctx.allocator.free(old);
            ctx.last_modified_buffer = ctx.allocator.dupe(u8, val) catch null;
        }
    }

    return total_size;
}

/// Progress callback - returns non-zero to abort transfer
fn progressCallback(user_data: ?*anyopaque, _: c_longlong, _: c_longlong, _: c_longlong, _: c_longlong) callconv(.c) c_int {
    if (user_data == null) return 0;
    const ctx: *TransferContext = @ptrCast(@alignCast(user_data.?));
    // Abort if we've collected enough data
    if (ctx.exceeded_limit) return 1; // Non-zero aborts the transfer
    return 0;
}

fn writeCallback(data: [*c]const u8, size: usize, nmemb: usize, user_data: ?*anyopaque) callconv(.c) usize {
    if (user_data == null) return 0;
    const ctx: *TransferContext = @ptrCast(@alignCast(user_data.?));
    const total_size: usize = size * nmemb;

    // If UTF-8 validation failed, abort transfer
    if (ctx.utf8_error) return 0;

    // Validate UTF-8 incrementally before storing
    const slice = data[0..total_size];
    if (!validateUtf8Chunk(ctx, slice)) {
        ctx.utf8_error = true;
        return 0; // Abort transfer
    }

    // If we've hit our soft limit, just accept but don't store
    if (ctx.exceeded_limit) return total_size;

    if (ctx.buffer.items.len + total_size > ctx.max_bytes) {
        const remaining = ctx.max_bytes - ctx.buffer.items.len;
        if (remaining > 0) {
            ctx.buffer.appendSlice(slice[0..remaining]) catch {
                ctx.oom_detected = true;
                return 0;
            };
        }
        ctx.exceeded_limit = true;
        return total_size; // Accept but we've stored what we need
    }

    ctx.buffer.appendSlice(slice) catch {
        ctx.oom_detected = true;
        return 0;
    };
    return total_size;
}
