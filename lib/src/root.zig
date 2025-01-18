const std = @import("std");
const testing = std.testing;
const log = std.log;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;
const File = std.fs.File;
const AnyReader = std.io.AnyReader;

threadlocal var reader: ?*FeedReader = null;
var gpa: GeneralPurposeAllocator(.{}) = .init;

export fn open(fileName: [*:0]const u8) i32 {
    if (reader) |_| {
        // reader is already active on another file
        log.err("This thread already has an open reader. Close the current reader before opening a new one.", .{});
        return @intFromEnum(NewReaderResult.conflict);
    }

    const file: File = std.fs.cwd().openFileZ(fileName, .{}) catch |err| {
        log.err("Failed to open file: {s} -> {?}", .{ @errorName(err), @errorReturnTrace() });
        return @intFromEnum(NewReaderResult.failedToOpen);
    };

    reader = FeedReader.new(gpa.allocator(), file) catch |err| {
        switch (err) {
            Allocator.Error.OutOfMemory => {
                log.err("FATAL: Out of memory. Last attempted allocation: {?}", .{@errorReturnTrace()});
                return @intFromEnum(NewReaderResult.outOfMemory);
            },
            else => unreachable,
        }
    };

    return @intFromEnum(NewReaderResult.opened);
}

export fn close() void {
    if (reader) |current_reader| {
        current_reader.deinit();
        reader = null;
    }
}

const FeedReader = struct {
    parent_allocator: Allocator,
    arena: *ArenaAllocator,
    file: File,
    inner_reader: AnyReader,

    pub fn new(allocator: Allocator, file: File) Allocator.Error!*FeedReader {
        const arena_ptr: *ArenaAllocator = try allocator.create(ArenaAllocator);
        errdefer allocator.destroy(arena_ptr);
        arena_ptr.* = .init(allocator);

        const reader_ptr: *FeedReader = try arena_ptr.allocator().create(FeedReader);
        reader_ptr.* = .{
            .parent_allocator = allocator,
            .arena = arena_ptr,
            .file = file,
            .inner_reader = file.reader().any(),
        };

        return reader_ptr;
    }

    pub fn deinit(self: FeedReader) void {
        self.file.close();
        self.arena.deinit();
    }
};

const NewReaderResult = enum(i32) {
    opened = 0,
    failedToOpen = 1,
    conflict = 2,
    outOfMemory = 3,
};
