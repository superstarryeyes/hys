const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Optional curl configuration for custom paths
    const curl_include_path = b.option([]const u8, "curl_include_path", "Custom path to curl headers");
    const curl_lib_path = b.option([]const u8, "curl_lib_path", "Custom path to curl library");

    // Get the Expat and Zdt dependencies
    const expat_dep = b.dependency("libexpat", .{});
    const zdt_dep = b.dependency("zdt", .{});
    const zdt_mod = zdt_dep.module("zdt");

    // Create shared modules (used by tests and benchmarks)
    const types_mod = b.createModule(.{
        .root_source_file = b.path("src/types.zig"),
    });

    const rss_reader_mod = b.createModule(.{
        .root_source_file = b.path("src/rss_reader.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "zdt", .module = zdt_mod },
        },
    });

    const feed_group_manager_mod = b.createModule(.{
        .root_source_file = b.path("src/feed_group_manager.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "rss_reader", .module = rss_reader_mod },
        },
    });

    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "rss_reader", .module = rss_reader_mod },
            .{ .name = "feed_group_manager", .module = feed_group_manager_mod },
        },
    });

    const formatter_mod = b.createModule(.{
        .root_source_file = b.path("src/formatter.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "rss_reader", .module = rss_reader_mod },
        },
    });

    const display_manager_mod = b.createModule(.{
        .root_source_file = b.path("src/display_manager.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "formatter", .module = formatter_mod },
            .{ .name = "config", .module = config_mod },
        },
    });

    const curl_multi_fetcher_mod = b.createModule(.{
        .root_source_file = b.path("src/curl_multi_fetcher.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });

    const feed_processor_mod = b.createModule(.{
        .root_source_file = b.path("src/feed_processor.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "rss_reader", .module = rss_reader_mod },
            .{ .name = "display_manager", .module = display_manager_mod },
            .{ .name = "curl_multi_fetcher", .module = curl_multi_fetcher_mod },
        },
    });

    const cli_parser_mod = b.createModule(.{
        .root_source_file = b.path("src/cli_parser.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });

    const daily_limiter_mod = b.createModule(.{
        .root_source_file = b.path("src/daily_limiter.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "zdt", .module = zdt_mod },
            .{ .name = "rss_reader", .module = rss_reader_mod },
        },
    });

    const opml_mod = b.createModule(.{
        .root_source_file = b.path("src/opml.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "rss_reader", .module = rss_reader_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "hys",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add module imports to executable
    exe.root_module.addImport("zdt", zdt_mod);
    exe.root_module.addImport("types", types_mod);
    exe.root_module.addImport("config", config_mod);
    exe.root_module.addImport("rss_reader", rss_reader_mod);
    exe.root_module.addImport("daily_limiter", daily_limiter_mod);
    exe.root_module.addImport("opml", opml_mod);
    exe.root_module.addImport("cli_parser", cli_parser_mod);
    exe.root_module.addImport("feed_processor", feed_processor_mod);
    exe.root_module.addImport("display_manager", display_manager_mod);
    exe.root_module.addImport("formatter", formatter_mod);

    // Link Expat to the executable
    exe.linkLibrary(expat_dep.artifact("expat"));
    exe.linkLibC();

    // Link libcurl for HTTP fetching (more robust than Zig's std.http.Client)
    // This requires libcurl dev headers to be installed on the system.
    // The build system looks for the library in standard system library paths.
    //
    // If you need to specify a custom search path for curl headers/libs, you can:
    // 1. Set system environment variables: LDFLAGS, CFLAGS, PKG_CONFIG_PATH
    // 2. Use build options: zig build -Dcurl_include_path=/path -Dcurl_lib_path=/path
    // 3. Install curl dev package via your system package manager
    //
    // See README.md prerequisites for installation instructions for your OS.
    linkCurl(exe, curl_include_path, curl_lib_path);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Unit tests from main.zig
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add zdt import to tests
    unit_tests.root_module.addImport("zdt", zdt_mod);

    // Link Expat to tests as well
    unit_tests.linkLibrary(expat_dep.artifact("expat"));
    unit_tests.linkLibC();

    // Link curl with the same pattern as main executable
    // Requires libcurl dev headers. See README.md prerequisites.
    linkCurl(unit_tests, curl_include_path, curl_lib_path);

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Comprehensive test suite
    const suite_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/suite.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add imports to test suite
    suite_tests.root_module.addImport("types", types_mod);
    suite_tests.root_module.addImport("formatter", formatter_mod);
    suite_tests.root_module.addImport("config", config_mod);
    suite_tests.root_module.addImport("zdt", zdt_mod);
    suite_tests.linkLibrary(expat_dep.artifact("expat"));
    suite_tests.linkLibC();
    linkCurl(suite_tests, curl_include_path, curl_lib_path);

    const run_suite_tests = b.addRunArtifact(suite_tests);

    // Normalization tests
    const norm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/normalization.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_norm_tests = b.addRunArtifact(norm_tests);

    // ==========================================================================
    // CLI TESTS
    // ==========================================================================
    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cli_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cli_tests.root_module.addImport("cli_parser", cli_parser_mod);
    cli_tests.root_module.addImport("types", types_mod);

    const run_cli_tests = b.addRunArtifact(cli_tests);

    // ==========================================================================
    // FILESYSTEM TESTS (DailyLimiter, history, seen hashes)
    // ==========================================================================
    const filesystem_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/filesystem_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    filesystem_tests.root_module.addImport("types", types_mod);
    filesystem_tests.root_module.addImport("zdt", zdt_mod);
    filesystem_tests.root_module.addImport("daily_limiter", daily_limiter_mod);
    filesystem_tests.root_module.addImport("feed_group_manager", feed_group_manager_mod);
    filesystem_tests.linkLibrary(expat_dep.artifact("expat"));
    filesystem_tests.linkLibC();
    linkCurl(filesystem_tests, curl_include_path, curl_lib_path);

    const run_filesystem_tests = b.addRunArtifact(filesystem_tests);

    // ==========================================================================
    // OPML TESTS
    // ==========================================================================
    const opml_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/opml_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    opml_tests.root_module.addImport("opml", opml_mod);
    opml_tests.root_module.addImport("types", types_mod);
    opml_tests.linkLibrary(expat_dep.artifact("expat"));
    opml_tests.linkLibC();
    linkCurl(opml_tests, curl_include_path, curl_lib_path);

    const run_opml_tests = b.addRunArtifact(opml_tests);

    // ==========================================================================
    // TEST STEPS
    // ==========================================================================
    const test_step = b.step("test", "Run all tests (unit + comprehensive suite + new tests)");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_suite_tests.step);
    test_step.dependOn(&run_norm_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_filesystem_tests.step);
    test_step.dependOn(&run_opml_tests.step);

    // Individual test steps
    const cli_test_step = b.step("test-cli", "Run CLI parser tests");
    cli_test_step.dependOn(&run_cli_tests.step);

    const filesystem_test_step = b.step("test-fs", "Run filesystem/DailyLimiter tests");
    filesystem_test_step.dependOn(&run_filesystem_tests.step);

    const opml_test_step = b.step("test-opml", "Run OPML tests");
    opml_test_step.dependOn(&run_opml_tests.step);

    const norm_test_step = b.step("test-norm", "Run normalization tests");
    norm_test_step.dependOn(&run_norm_tests.step);

    // ==========================================================================
    // BENCHMARK EXECUTABLE
    // ==========================================================================
    // Performance benchmark for offline testing (no network I/O)
    // Always built with ReleaseFast for accurate measurements
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bench/bench_main.zig"),
            .target = target,
            .optimize = .ReleaseFast, // Always optimize benchmarks
        }),
    });

    // Add module imports to benchmark (using shared modules defined above)
    bench_exe.root_module.addImport("types", types_mod);
    bench_exe.root_module.addImport("rss_reader", rss_reader_mod);
    bench_exe.root_module.addImport("zdt", zdt_mod);

    // Link libraries
    bench_exe.linkLibrary(expat_dep.artifact("expat"));
    bench_exe.linkLibC();
    linkCurl(bench_exe, curl_include_path, curl_lib_path);

    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(b.getInstallStep());

    // Pass any args to the benchmark
    if (b.args) |args| {
        run_bench.addArgs(args);
    }

    const bench_step = b.step("bench", "Run offline performance benchmark");
    bench_step.dependOn(&run_bench.step);
}

fn linkCurl(exe: *std.Build.Step.Compile, include_path: ?[]const u8, lib_path: ?[]const u8) void {
    exe.linkSystemLibrary("curl");

    if (include_path) |path| {
        // Paths should be absolute or relative to cwd where build is invoked
        // Use cwd_relative for both cases - it works correctly
        exe.addIncludePath(.{ .cwd_relative = path });
    }

    if (lib_path) |path| {
        // Paths should be absolute or relative to cwd where build is invoked
        // Use cwd_relative for both cases - it works correctly
        exe.addLibraryPath(.{ .cwd_relative = path });
    }
}
