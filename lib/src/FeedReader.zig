const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const MemoryPool = std.heap.MemoryPool;
const File = std.fs.File;
const AnyReader = std.io.AnyReader;
const Parsed = json.Parsed;
const ParseOptions = json.ParseOptions;
const json = std.json;
const log = std.log;

parent_allocator: Allocator,
arena: *ArenaAllocator,
file: File,
inner_reader: AnyReader,
open_square_bracket: bool = false,
telemetry: Telemetry = .{},
prev_scan: ?struct { ptr: *Scan, parsed: Parsed(Scan) } = null,

const FeedReader = @This();

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

pub fn nextScan(self: *FeedReader) error{ InvalidFileFormat, OutOfMemory }!ScanResult {
    // check for a previous scan and free that memory
    if (self.prev_scan) |prev| {
        self.arena.allocator().destroy(prev.ptr);
        prev.parsed.deinit();
    }

    // the file is supposed to be a massive JSON file: an array of objects
    if (self.open_square_bracket) {
        // parse JSON object: from '{' until '}'
        var buf: [4096]u8 = undefined;
        const slice: []const u8 = self.parseNextObject(&buf) catch {
            return error.InvalidFileFormat;
        } orelse return .eof;

        const parsed: Parsed(Scan) = json.parseFromSlice(
            Scan,
            self.arena.allocator(),
            slice,
            ParseOptions{ .ignore_unknown_fields = true },
        ) catch |err| {
            log.err("Failed to parse feeder object: {s} -> {?}\nObject:\n{s}\n", .{
                @errorName(err),
                @errorReturnTrace(),
                slice,
            });
            return error.InvalidFileFormat;
        };
        const scan: *Scan = try self.arena.allocator().create(Scan);
        scan.* = parsed.value;
        // assign to previous
        self.prev_scan = .{ .ptr = scan, .parsed = parsed };
        return .{ .scan = scan };
    } else {
        // read the square bracket first
        self.openArray() catch |err| {
            switch (err) {
                error.EndOfStream => {
                    log.info("Read until end of stream. Presumably an empty file", .{});
                    return .eof;
                },
                else => |e| return e,
            }
        };
        // great, we found the opening square bracket, so we'll denote that
        self.open_square_bracket = true;
        return try self.nextScan();
    }
}

fn openArray(self: *FeedReader) error{ EndOfStream, InvalidFileFormat }!void {
    while (self.inner_reader.readByte()) |byte| {
        var new_line: bool = false;
        defer {
            if (!new_line) {
                self.telemetry.pos += 1;
            } else {
                self.telemetry.pos = 0;
                self.telemetry.line += 1;
            }
        }

        if (byte == '\n') {
            new_line = true;
        }
        if (std.ascii.isWhitespace(byte)) continue;

        if (byte == '[') {
            return;
        }
        log.err("First non-whitespace character was not '['. Instead was: '{c}', line: {d}, pos: {d}", .{
            byte,
            self.telemetry.line,
            self.telemetry.pos,
        });
        return error.InvalidFileFormat;
    } else |err| {
        return @as(error{ EndOfStream, InvalidFileFormat }, @errorCast(err));
    }
}

fn parseNextObject(self: *FeedReader, buf: []u8) error{ InvalidFormat, ObjectNotTerminated }!?[]const u8 {
    var open_brace: bool = false;
    var close_brace: bool = false;
    var i: usize = 0;
    while (self.inner_reader.readByte()) |byte| {
        if (i >= buf.len) break;

        var new_line: bool = false;
        defer {
            if (!new_line) {
                self.telemetry.pos += 1;
            } else {
                self.telemetry.pos = 0;
                self.telemetry.line += 1;
            }
        }

        if (byte == '\n') {
            new_line = true;
        }

        if (byte == ',' and i == 0) continue;
        if (std.ascii.isWhitespace(byte)) continue;
        if (byte == ']' and i == 0) {
            // we're all done here
            return null;
        }

        defer i += 1;
        if (!open_brace and byte == '{') {
            buf[i] = byte;
            open_brace = true;
        } else if (open_brace) {
            buf[i] = byte;
            if (byte == '}') {
                close_brace = true;
                break;
            }
        } else {
            return error.InvalidFormat;
        }
    } else |err| {
        // probably just the end
        switch (err) {
            error.EndOfStream => return null,
            else => unreachable,
        }
    }

    if (!close_brace) {
        return error.ObjectNotTerminated;
    }
    return buf[0..i];
}

pub fn deinit(self: *FeedReader) void {
    const parent_allocator: Allocator = self.parent_allocator;
    const arena_ptr: *ArenaAllocator = self.arena;

    self.file.close();
    self.arena.deinit();
    parent_allocator.destroy(arena_ptr);
}

const Telemetry = struct {
    line: usize = 1,
    pos: usize = 0,
};

pub const ScanResult = union(enum) {
    eof,
    scan: *Scan,
};

pub const Scan = struct {
    imb: [31]u8,
    mailPhase: []const u8,
};
