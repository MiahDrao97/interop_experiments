const std = @import("std");
const testing = std.testing;
const log = std.log;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const File = std.fs.File;
const AnyReader = std.io.AnyReader;
const FeedReader = @import("FeedReader.zig");
const ScanResult = FeedReader.ScanResult;
const ReadScanStatus = FeedReader.ReadScanStatus;

threadlocal var reader: ?FeedReader = null;
var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
var alloc = gpa.allocator();

/// Open a file from the USPS feeder, returning a status code for the operation
export fn open(fileName: [*:0]const u8) NewReaderResult {
    if (reader) |_| {
        // reader is already active on another file
        log.err("This thread already has an open reader. Close the current reader before opening a new one.", .{});
        return .conflict;
    }

    const file: File = std.fs.cwd().openFileZ(
        fileName,
        File.OpenFlags{ .mode = .read_only, .allow_ctty = true, .lock = .exclusive },
    ) catch |err| {
        log.err("Failed to open file '{s}': {s} -> {?}", .{ fileName, @errorName(err), @errorReturnTrace() });
        return .failedToOpen;
    };

    reader = FeedReader.new(alloc, file) catch |err| {
        switch (err) {
            Allocator.Error.OutOfMemory => {
                log.err("FATAL: Out of memory. Last attempted allocation: {?}", .{@errorReturnTrace()});
                return .outOfMemory;
            },
            else => unreachable,
        }
    };

    return .opened;
}

export fn nextScan() ScanResult {
    if (reader) |*current_reader| {
        return current_reader.nextScan();
    }
    return .err(.noActiveReader);
}

export fn close() void {
    if (reader) |current_reader| {
        current_reader.deinit();
        reader = null;
    }
}

pub const NewReaderResult = enum(i32) {
    opened = 0,
    failedToOpen = 1,
    conflict = 2,
    outOfMemory = 3,
};

test "success case" {
    // switch to testing allocator to detect memory leaks
    alloc = testing.allocator;

    const result: NewReaderResult = open("test_feed.json");
    try testing.expectEqual(.opened, result);
    defer close();

    try testing.expect(reader != null);

    var scanResult: ScanResult = nextScan();
    try testing.expectEqual(.success, scanResult.status);
    try testing.expect(scanResult.imb != null);
    try testing.expect(scanResult.mailPhase != null);
    try testing.expectEqualStrings("4537457458800947547708425641125", scanResult.imb.?[0..31]);
    try testing.expectEqualStrings("Phase 3c - Destination Sequenced Carrier Sortation", scanResult.mailPhase.?[0..50]);

    scanResult = nextScan();
    try testing.expectEqual(.success, scanResult.status);
    try testing.expect(scanResult.imb != null);
    try testing.expect(scanResult.mailPhase != null);
    try testing.expectEqualStrings("6899000795822123340248082958957", scanResult.imb.?[0..31]);
    try testing.expectEqualStrings("Phase 0 - Origin Processing Cancellation of Postage", scanResult.mailPhase.?[0..51]);

    scanResult = nextScan();
    try testing.expectEqual(.eof, scanResult.status);
    try testing.expectEqual(null, scanResult.imb);
    try testing.expectEqual(null, scanResult.mailPhase);
}
