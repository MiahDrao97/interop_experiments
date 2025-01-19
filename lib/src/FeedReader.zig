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
open_square_bracket: bool = false,
telemetry: Telemetry = .{},
prev_scan: ?struct { unmanaged: *ScanUnmanaged, parsed: Parsed(Scan) } = null,
// this belongs to the OS
file_handle_ptr: usize,

const FeedReader = @This();

pub fn new(allocator: Allocator, file: File) Allocator.Error!FeedReader {
    const arena_ptr: *ArenaAllocator = try allocator.create(ArenaAllocator);
    errdefer allocator.destroy(arena_ptr);
    arena_ptr.* = .init(allocator);

    return .{
        .parent_allocator = allocator,
        .arena = arena_ptr,
        .file_handle_ptr = @intFromPtr(file.handle),
    };
}

fn getFile(self: FeedReader) File {
    const handle: *anyopaque = @ptrFromInt(self.file_handle_ptr);
    return .{ .handle = handle };
}

pub fn nextScan(self: *FeedReader) error{ InvalidFileFormat, OutOfMemory }!ScanResult {
    // check for a previous scan and free that memory
    if (self.prev_scan) |prev| {
        prev.unmanaged.deinit(self.arena.allocator());
        prev.parsed.deinit();
    }

    // the file is supposed to be a massive JSON file: an array of objects
    if (self.open_square_bracket) {
        // parse JSON object: from '{' until '}'
        var buf: [4096]u8 = undefined;
        const slice: []const u8 = self.parseNextObject(&buf) catch |err| {
            log.err("Failed to parse next object: {s} -> {?}", .{ @errorName(err), @errorReturnTrace() });
            return error.InvalidFileFormat;
        } orelse return .eof;

        log.debug("\nParsed object: '{s}'", .{slice});

        const parsed: Parsed(Scan) = json.parseFromSlice(
            Scan,
            self.arena.allocator(),
            slice,
            ParseOptions{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed },
        ) catch |err| {
            switch (err) {
                error.Overflow => return error.OutOfMemory,
                else => {
                    log.err("Failed to parse feeder object: {s} -> {?}\nObject:\n{s}\n", .{
                        @errorName(err),
                        @errorReturnTrace(),
                        slice,
                    });
                    return error.InvalidFileFormat;
                },
            }
        };
        // assign to previous
        self.prev_scan = .{ .unmanaged = try .new(self.arena.allocator(), parsed.value), .parsed = parsed };
        return .{ .scan = self.prev_scan.?.unmanaged };
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
    var reader: AnyReader = self.getFile().reader().any();
    while (reader.readByte()) |byte| {
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
        log.err("Encountered error opening array (line: {d}, pos: {d}): {s} -> {?}", .{
            self.telemetry.line,
            self.telemetry.pos,
            @errorName(err),
            @errorReturnTrace(),
        });
        return error.InvalidFileFormat;
    }
}

fn parseNextObject(self: *FeedReader, buf: []u8) error{ InvalidFormat, ObjectNotTerminated }!?[]const u8 {
    var open_brace: bool = false;
    var close_brace: bool = false;
    var inside_quotes: bool = false;
    var i: usize = 0;
    var reader: AnyReader = self.getFile().reader().any();
    while (reader.readByte()) |byte| {
        // don't allow overflow
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

        if (byte == '"') {
            inside_quotes = !inside_quotes;
        }

        if (byte == ',' and i == 0) continue;
        if (!inside_quotes and std.ascii.isWhitespace(byte)) continue;

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
            log.err("Unexpected token '{c}': line {d}, pos {d}", .{ byte, self.telemetry.line, self.telemetry.pos });
            return error.InvalidFormat;
        }
    } else |err| {
        // probably just the end
        switch (err) {
            error.EndOfStream => return null,
            else => {
                log.err("Unepxected error: {s} -> {?}", .{ @errorName(err), @errorReturnTrace() });
                unreachable;
            },
        }
    }

    if (!close_brace) {
        return error.ObjectNotTerminated;
    }
    return buf[0..i];
}

pub fn deinit(self: FeedReader) void {
    const parent_allocator: Allocator = self.parent_allocator;
    const arena_ptr: *ArenaAllocator = self.arena;

    self.getFile().close();
    self.arena.deinit();
    parent_allocator.destroy(arena_ptr);
}

const Telemetry = struct {
    line: usize = 1,
    pos: usize = 0,
};

pub const ScanResult = union(enum) {
    eof,
    scan: *ScanUnmanaged,
};

const Scan = struct {
    imb: []const u8,
    mailPhase: []const u8,
};

pub const ScanUnmanaged = extern struct {
    imb: [*:0]u8,
    imb_len: usize,
    mailPhase: [*:0]u8,
    mailPhase_len: usize,

    pub fn new(allocator: Allocator, scan: Scan) Allocator.Error!*ScanUnmanaged {
        const imb: [:0]u8 = try allocator.allocSentinel(u8, scan.imb.len, 0);
        errdefer allocator.free(imb);

        const mailPhase: [:0]u8 = try allocator.allocSentinel(u8, scan.mailPhase.len, 0);
        errdefer allocator.free(mailPhase);

        const ptr: *ScanUnmanaged = try allocator.create(ScanUnmanaged);

        @memcpy(imb, scan.imb);
        @memcpy(mailPhase, scan.mailPhase);

        ptr.* = .{
            .imb = imb.ptr,
            .imb_len = scan.imb.len,
            .mailPhase = mailPhase.ptr,
            .mailPhase_len = scan.mailPhase.len,
        };
        return ptr;
    }

    pub fn deinit(self: *ScanUnmanaged, allocator: Allocator) void {
        allocator.free(self.imb[0..self.imb_len]);
        allocator.free(self.mailPhase[0..self.mailPhase_len]);
        allocator.destroy(self);
    }
};
