const std = @import("std");
const testing = std.testing;
const log = std.log;
const mem = std.mem;
const Allocator = mem.Allocator;
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;
const File = std.fs.File;
const FeedReader = @import("FeedReader.zig");
const ScanResult = FeedReader.ScanResult;
const ReadScanStatus = FeedReader.ReadScanStatus;
const ResetMode = std.heap.ArenaAllocator.ResetMode;

/// Static reader that is unique to each thread
threadlocal var reader: ?FeedReader = null;

/// The global allocator we're using
var gpa: GeneralPurposeAllocator(.{}) = .init;

/// I exposed this global so that it can set in unit testing to detect memory leaks
var alloc: Allocator = gpa.allocator();

/// Expose those global so that test cases can fully deinit the arena so we pass tests without memory leaks
var reset_mode: ResetMode = .{ .retain_with_limit = 4_000_000 };

/// Open a file from the USPS feeder, returning a status code for the operation.
///     `file_path` is a null-terminated string.
export fn open(file_path: [*:0]const u8) NewReaderResult {
    if (reader) |_| {
        // reader is already active on another file
        log.err("This thread already has an open reader. Close the current reader before opening a new one.", .{});
        return .conflict;
    }

    const open_start: i64 = std.time.microTimestamp();
    var file: File = undefined;
    if (std.fs.path.isAbsoluteZ(file_path)) {
        file = std.fs.openFileAbsoluteZ(
            file_path,
            File.OpenFlags{ .mode = .read_only },
        ) catch |err| {
            log.err("Failed to open file '{s}': {s} -> {?}", .{ file_path, @errorName(err), @errorReturnTrace() });
            return .failedToOpen;
        };
    } else {
        file = std.fs.cwd().openFileZ(
            file_path,
            File.OpenFlags{ .mode = .read_only },
        ) catch |err| {
            log.err("Failed to open file '{s}': {s} -> {?}", .{ file_path, @errorName(err), @errorReturnTrace() });
            return .failedToOpen;
        };
    }
    const open_end: i64 = std.time.microTimestamp();
    std.debug.print("Opened file '{s}' in {d}us\n", .{ mem.sliceTo(file_path, 0), open_end - open_start });

    reader = .open(alloc, file, mem.sliceTo(file_path, 0), false);
    return .opened;
}

/// Get the next scan, EOF, or an error if we cannot read it.
export fn nextScan() ScanResult {
    if (reader) |*current_reader| {
        return current_reader.nextScan();
    }
    return .err(.noActiveReader);
}

/// Close the current reader, allocated memory, and underlying feed file
export fn close() void {
    if (reader) |*current_reader| {
        // intentionally hold on to our pre-allocated memory
        current_reader.deinit(reset_mode);
        reader = null;
    }
}

/// Reader result from opening a new reader
pub const NewReaderResult = enum(i32) {
    /// Successfully opened
    opened = 0,
    /// Failed to open, likely because the OS would not let us open this file
    failedToOpen = 1,
    /// There is already an open reader on this thread
    conflict = 2,
    /// Out of memory to allocate
    outOfMemory = 3,
};

test "success case" {
    // switch to testing allocator to detect memory leaks
    alloc = testing.allocator;
    // free all so that we don't retain memory at the end of this test
    reset_mode = .free_all;
    testing.log_level = .debug;

    const result: NewReaderResult = open("test_feed.json");
    defer close();

    try testing.expectEqual(.opened, result);
    try testing.expect(reader != null);

    var scanResult: ScanResult = nextScan();
    try testing.expectEqual(.success, scanResult.status);
    try testing.expect(scanResult.imb != null);
    try testing.expect(scanResult.mailPhase != null);
    try testing.expectEqualStrings("4537457458800947547708425641125", mem.sliceTo(scanResult.imb.?, 0));
    try testing.expectEqualStrings("Phase 3c - Destination Sequenced Carrier Sortation", mem.sliceTo(scanResult.mailPhase.?, 0));

    scanResult = nextScan();
    try testing.expectEqual(.success, scanResult.status);
    try testing.expect(scanResult.imb != null);
    try testing.expect(scanResult.mailPhase != null);
    try testing.expectEqualStrings("6899000795822123340248082958957", mem.sliceTo(scanResult.imb.?, 0));
    try testing.expectEqualStrings("Phase 0 - Origin Processing Cancellation of Postage", mem.sliceTo(scanResult.mailPhase.?, 0));

    scanResult = nextScan();
    try testing.expectEqual(.eof, scanResult.status);
    try testing.expectEqual(null, scanResult.imb);
    try testing.expectEqual(null, scanResult.mailPhase);
}
