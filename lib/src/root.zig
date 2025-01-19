const std = @import("std");
const testing = std.testing;
const log = std.log;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;
const File = std.fs.File;
const AnyReader = std.io.AnyReader;
const FeedReader = @import("FeedReader.zig");
const Scan = FeedReader.Scan;
const ReadResult = FeedReader.ScanResult;

threadlocal var reader: ?*FeedReader = null;
var gpa: GeneralPurposeAllocator(.{}) = .init;

/// Open a file from the USPS feeder, returning a status code for the operation
export fn open(fileName: [*:0]const u8) NewReaderResult {
    if (reader) |_| {
        // reader is already active on another file
        log.err("This thread already has an open reader. Close the current reader before opening a new one.", .{});
        return .conflict;
    }

    const file: File = std.fs.cwd().openFileZ(fileName, .{ .mode = .read_only }) catch |err| {
        log.err("Failed to open file '{s}': {s} -> {?}", .{ fileName, @errorName(err), @errorReturnTrace() });
        return .failedToOpen;
    };

    reader = FeedReader.new(gpa.allocator(), file) catch |err| {
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

export fn nextScan() ReadScanResult {
    if (reader) |current_reader| {
        const read_result: ReadResult = current_reader.nextScan() catch |err| {
            switch (err) {
                error.OutOfMemory => return .{ .status = .outOfMemory },
                error.InvalidFileFormat => return .{ .status = .failedToRead },
            }
        };
        switch (read_result) {
            .scan => |s| return .{ .scan = s },
            .eof => return .{ .status = .eof },
        }
    }
    return .{ .status = .noActiveReader };
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

pub const ReadScanStatus = enum(i32) {
    success = 0,
    noActiveReader = 1,
    failedToRead = 2,
    outOfMemory = 3,
    eof = -1,
};

pub const ReadScanResult = extern struct {
    status: ReadScanStatus = .success,
    scan: ?*Scan = null,
};
