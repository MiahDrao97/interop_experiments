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

threadlocal var reader: ?FeedReader = null;
var gpa: GeneralPurposeAllocator(.{}) = .init;
var alloc: Allocator = gpa.allocator();

/// Open a file from the USPS feeder, returning a status code for the operation
export fn open(file_path: [*:0]const u8) NewReaderResult {
    if (reader) |_| {
        // reader is already active on another file
        log.err("This thread already has an open reader. Close the current reader before opening a new one.", .{});
        return .conflict;
    }

    const file: File = std.fs.cwd().openFileZ(
        file_path,
        File.OpenFlags{ .mode = .read_only },
    ) catch |err| {
        log.err("Failed to open file '{s}': {s} -> {?}", .{ file_path, @errorName(err), @errorReturnTrace() });
        return .failedToOpen;
    };

    reader = FeedReader.new(alloc, file, mem.sliceTo(file_path, 0), false) catch |err| {
        @branchHint(.cold);
        switch (err) {
            Allocator.Error.OutOfMemory => {
                log.err("FATAL: Out of memory. Last attempted allocation: {?}", .{@errorReturnTrace()});
                return .outOfMemory;
            },
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
    testing.log_level = .debug;

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
