const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const File = std.fs.File;
const AnyReader = std.io.AnyReader;
const Parsed = json.Parsed;
const ParseOptions = json.ParseOptions;
const json = std.json;
const log = std.log;
const ascii = std.ascii;
const windows = std.os.windows;
const posix = std.posix;
const fd_t = posix.fd_t;

parent_allocator: Allocator,
arena: *ArenaAllocator,
open_square_bracket: bool = false,
telemetry: Telemetry,
// this belongs to the OS
file_handle: fd_t,

const FeedReader = @This();
const is_windows: bool = @import("builtin").os.tag == .windows;

pub fn new(allocator: Allocator, file: File, file_path: [:0]const u8) Allocator.Error!FeedReader {
    const arena_ptr: *ArenaAllocator = try allocator.create(ArenaAllocator);
    arena_ptr.* = .init(allocator);

    return .{
        .parent_allocator = allocator,
        .arena = arena_ptr,
        .file_handle = file.handle,
        .telemetry = .init(file_path),
    };
}

pub fn nextScan(self: *FeedReader) ScanResult {
    // the file is supposed to be a massive JSON file: an array of objects
    if (self.open_square_bracket) {
        // parse JSON object: from '{' until '}'
        var buf: [4096]u8 = undefined;
        const slice: []const u8 = self.parseNextObject(&buf) catch |err| {
            log.err("Failed to parse next object: {s} -> {?}", .{ @errorName(err), @errorReturnTrace() });
            return .err(.failedToRead);
        } orelse return .eof;

        log.debug("\nParsed object: '{s}'", .{slice});

        const parsed: Scan = json.parseFromSliceLeaky(
            Scan,
            self.arena.allocator(),
            slice,
            ParseOptions{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed },
        ) catch |err| {
            switch (err) {
                error.Overflow => return .err(.outOfMemory),
                else => {
                    log.err("Failed to parse feeder object: {s} -> {?}\nObject:\n{s}\n", .{
                        @errorName(err),
                        @errorReturnTrace(),
                        slice,
                    });
                    return .err(.failedToRead);
                },
            }
        };
        return .ok(parsed);
    } else {
        // read the square bracket first
        self.openArray() catch |err| {
            switch (err) {
                error.EndOfStream => {
                    log.warn("Read until end of stream. Presumably an empty file", .{});
                    return .eof;
                },
                else => {
                    @branchHint(.cold);
                    log.err("Unexpected error while opening array: {s} -> {?}", .{ @errorName(err), @errorReturnTrace() });
                    return .err(.failedToRead);
                },
            }
        };
        // great, we found the opening square bracket, so we'll denote that
        self.open_square_bracket = true;
        return self.nextScan();
    }
}

fn getFile(self: FeedReader) File {
    return .{ .handle = self.file_handle };
}

fn readByte(self: FeedReader) anyerror!u8 {
    // extracted from std lib
    var buffer: [1]u8 = undefined;
    var bytes_read: usize = undefined;
    if (is_windows) {
        bytes_read = try windows.ReadFile(self.file_handle, &buffer, null);
    } else {
        bytes_read = try posix.read(self.file_handle, &buffer);
    }
    return if (bytes_read == 1) buffer[0] else error.EndOfStream;
}

fn openArray(self: *FeedReader) error{ EndOfStream, InvalidFileFormat }!void {
    // first read: read everything to avoid a bunch of sys calls
    while (self.readByte()) |byte| {
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
        if (ascii.isWhitespace(byte)) continue;

        if (byte == '[') {
            return;
        }
        log.err("First non-whitespace character was not '['. Instead was: '{c}'. '{s}', line: {d}, pos: {d}", .{
            byte,
            self.telemetry.file_path,
            self.telemetry.line,
            self.telemetry.pos,
        });
        return error.InvalidFileFormat;
    } else |err| {
        log.err("Encountered error opening array ('{s}', line: {d}, pos: {d}): {s} -> {?}", .{
            self.telemetry.file_path,
            self.telemetry.line,
            self.telemetry.pos,
            @errorName(err),
            @errorReturnTrace(),
        });
        return error.InvalidFileFormat;
    }
}

fn parseNextObject(self: *FeedReader, buf: []u8) error{ InvalidFormat, ObjectNotTerminated, BufferOverflow }!?[]const u8 {
    var open_brace: bool = false;
    var close_brace: bool = false;
    var inside_quotes: bool = false;
    var i: usize = 0;
    while (self.readByte()) |byte| {
        if (i >= buf.len) {
            log.err("FATAL: Overflowed buffer of {d} bytes at '{s}', line: {d}, pos: {d}. This requires a code change to increase buffer size.", .{
                buf.len,
                self.telemetry.file_path,
                self.telemetry.line,
                self.telemetry.pos,
            });
            return error.BufferOverflow;
        }

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
        if (!inside_quotes and ascii.isWhitespace(byte)) continue;

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
            if (!inside_quotes and byte == '}') {
                close_brace = true;
                break;
            }
        } else {
            log.err("Unexpected token '{c}': '{s}', line {d}, pos {d}", .{
                byte,
                self.telemetry.file_path,
                self.telemetry.line,
                self.telemetry.pos,
            });
            return error.InvalidFormat;
        }
    } else |err| {
        // probably just the end
        switch (err) {
            error.EndOfStream => return null,
            else => {
                @branchHint(.cold);
                log.err("Unepxected error while parsing '{s}', line {d}, pos {d}: {s} -> {?}", .{
                    self.telemetry.file_path,
                    self.telemetry.line,
                    self.telemetry.pos,
                    @errorName(err),
                    @errorReturnTrace(),
                });
                return error.InvalidFormat;
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

    const file: File = self.getFile();
    file.close();
    self.arena.deinit();
    parent_allocator.destroy(arena_ptr);
}

const Telemetry = struct {
    line: usize,
    pos: usize,
    file_path: [:0]const u8,

    pub fn init(file_path: [:0]const u8) Telemetry {
        return .{
            .file_path = file_path,
            .line = 1,
            .pos = 0,
        };
    }
};

const Scan = struct {
    imb: ?[:0]const u8,
    mailPhase: ?[:0]const u8,
};

pub const ReadScanStatus = enum(i32) {
    success = 0,
    noActiveReader = 1,
    failedToRead = 2,
    outOfMemory = 3,
    eof = -1,
};

pub const ScanResult = extern struct {
    status: ReadScanStatus,
    imb: ?[*:0]const u8,
    mailPhase: ?[*:0]const u8,

    pub fn ok(scan: Scan) ScanResult {
        return .{
            .status = .success,
            .imb = if (scan.imb != null) scan.imb.?.ptr else null,
            .mailPhase = if (scan.mailPhase != null) scan.mailPhase.?.ptr else null,
        };
    }

    pub fn err(status: ReadScanStatus) ScanResult {
        return .{
            .status = status,
            .imb = null,
            .mailPhase = null,
        };
    }

    pub const eof: ScanResult = .{
        .status = .eof,
        .imb = null,
        .mailPhase = null,
    };
};
