# Test Suite

Run all tests:
```bash
zig build test
```

Run individual test suites:
```bash
zig build test-cli          # CLI argument parsing
zig build test-fs           # Filesystem, history, hashes
zig build test-norm         # URL/GUID normalization
zig build test-opml         # OPML feed configuration
```

## Test Files

- **suite.zig** - Types, formatter, config, integration tests (~31 tests)
- **cli_tests.zig** - CLI parsing, group names, flags (~27 tests)
- **filesystem_tests.zig** - History files, hash storage (~8 tests)
- **normalization.zig** - URL normalization, entity decoding (~11 tests)
- **opml_tests.zig** - FeedConfig fields, cloning, Unicode (~13 tests)

Total: ~93 tests. All tests pass and use `std.testing.allocator` for memory validation.
