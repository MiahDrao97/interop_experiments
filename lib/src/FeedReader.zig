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
open_events: bool = false,
telemetry: Telemetry,
file_stream: FileStream(6000),

const FeedReader = @This();

pub fn new(allocator: Allocator, file: File, file_path: [:0]const u8, with_file_lock: bool) Allocator.Error!FeedReader {
    const arena_ptr: *ArenaAllocator = try allocator.create(ArenaAllocator);
    arena_ptr.* = .init(allocator);

    return .{
        .parent_allocator = allocator,
        .arena = arena_ptr,
        .telemetry = .init(file_path),
        .file_stream = .init(file, with_file_lock),
    };
}

pub fn nextScan(self: *FeedReader) ScanResult {
    // the file is supposed to be a massive JSON file; we care about the "events" field, which is an array of objects with depth 1
    if (self.open_events) {
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
        // we only care about the "events" field
        self.openEvents() catch |err| {
            switch (err) {
                error.EndOfStream => {
                    log.warn("Read until end of stream. Presumably an empty file ('{s}', line {d}, pos {d}) -> {?}", .{
                        self.telemetry.file_path,
                        self.telemetry.line,
                        self.telemetry.pos,
                        @errorReturnTrace(),
                    });
                    return .eof;
                },
                else => {
                    @branchHint(.cold);
                    log.err("Unexpected error while opening array: {s} -> {?}", .{ @errorName(err), @errorReturnTrace() });
                    return .err(.failedToRead);
                },
            }
        };
        // great, we're in the "events" field and past opening square bracket, so we'll denote that
        self.open_events = true;
        return self.nextScan();
    }
}

fn openEvents(self: *FeedReader) error{ EndOfStream, InvalidFileFormat }!void {
    const key: []const u8 = "events";
    var inside_quotes: bool = false;
    var idx: usize = 0;
    var inside_events: bool = false;
    while (self.file_stream.nextByte()) |byte| {
        if (byte == null) {
            return error.EndOfStream;
        }
        log.debug("Next byte: {c}", .{byte.?});
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
        if (!inside_quotes and ascii.isWhitespace(byte.?)) continue;

        if (byte == '"') {
            inside_quotes = !inside_quotes;
            continue;
        }

        if (inside_quotes) {
            log.debug("Byte inside quotes: {c}", .{byte.?});
            if (idx < key.len) {
                if (byte == key[idx]) {
                    idx += 1;
                    if (idx == key.len) {
                        inside_events = true;
                        log.debug("Found events field '{s}', line {d}, pos {d}", .{
                            self.telemetry.file_path,
                            self.telemetry.line,
                            self.telemetry.pos,
                        });
                    }
                } else {
                    idx = 0;
                }
            }
        } else {
            idx = 0;
        }

        if (!inside_quotes and inside_events and byte == ':') {
            try self.openArray();
            return;
        }
    } else |err| {
        log.err("Encountered error opening events ('{s}', line: {d}, pos: {d}): {s} -> {?}", .{
            self.telemetry.file_path,
            self.telemetry.line,
            self.telemetry.pos,
            @errorName(err),
            @errorReturnTrace(),
        });
        return error.InvalidFileFormat;
    }
}

fn openArray(self: *FeedReader) error{ EndOfStream, InvalidFileFormat }!void {
    // first read: read everything to avoid a bunch of sys calls
    while (self.file_stream.nextByte()) |byte| {
        if (byte == null) {
            return error.EndOfStream;
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
        if (ascii.isWhitespace(byte.?)) continue;

        if (byte == '[') {
            return;
        }
        log.err("First non-whitespace character in \"events\" field was not '['. Instead was: '{c}'. '{s}', line: {d}, pos: {d}", .{
            byte.?,
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
    while (self.file_stream.nextByte()) |byte| {
        if (i >= buf.len) {
            log.err("FATAL: Overflowed buffer of {d} bytes at '{s}', line: {d}, pos: {d}. This requires a code change to increase buffer size.", .{
                buf.len,
                self.telemetry.file_path,
                self.telemetry.line,
                self.telemetry.pos,
            });
            return error.BufferOverflow;
        }

        if (byte == null) {
            if (i == 0) {
                return null;
            }
            return buf;
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
        if (!inside_quotes and ascii.isWhitespace(byte.?)) continue;

        if (byte == ']' and i == 0) {
            // we're all done here
            return null;
        }

        defer i += 1;
        if (!open_brace and byte == '{') {
            buf[i] = byte.?;
            open_brace = true;
        } else if (open_brace) {
            buf[i] = byte.?;
            if (!inside_quotes and byte == '}') {
                close_brace = true;
                break;
            }
        } else {
            log.err("Unexpected token '{c}': '{s}', line {d}, pos {d}", .{
                byte.?,
                self.telemetry.file_path,
                self.telemetry.line,
                self.telemetry.pos,
            });
            return error.InvalidFormat;
        }
    } else |err| {
        // probably just the end
        switch (err) {
            error.EndOfStream => {
                if (i == 0) {
                    return null;
                }
                return buf;
            },
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

    self.file_stream.close();
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

fn FileStream(comptime buf_size: usize) type {
    return struct {
        file_handle: fd_t,
        file_locked: bool,
        buf: [buf_size]u8 = [_]u8{0} ** buf_size,
        read_buffer: []u8 = undefined,
        cursor: isize = -1,
        eof: bool = false,

        pub fn init(file: File, with_file_lock: bool) @This() {
            return .{
                .file_handle = file.handle,
                .file_locked = with_file_lock,
            };
        }

        pub fn nextByte(self: *@This()) !?u8 {
            if (self.cursor < 0 or self.cursor == self.read_buffer.len) {
                if (self.eof) {
                    return null;
                }
                try self.nextSegment();
                self.cursor = 0;
            }
            defer self.cursor += 1;

            return self.read_buffer[@bitCast(self.cursor)];
        }

        // TODO : Implement these for better ergonomics

        pub fn readUntil(self: *@This(), delimiter: []const u8, buf: []u8, telemetry: *Telemetry) ![]u8 {
            _ = self.*;
            _ = delimiter.ptr;
            _ = buf.ptr;
            _ = telemetry.*;
            unreachable;
        }

        pub fn readUntilIgnore(self: *@This(), delimiter: []const u8, telemetry: *Telemetry) error{ EndOfStream, ReadError }!usize {
            var idx: usize = 0;
            var bytes_read: usize = 0;
            while (self.nextByte()) |byte| {
                if (byte) {
                    var new_line: bool = false;
                    defer {
                        bytes_read += 1;
                        if (!new_line) {
                            telemetry.pos += 1;
                        } else {
                            telemetry.pos = 0;
                            telemetry.line += 1;
                        }
                    }
                    if (byte == '\n') {
                        new_line = true;
                    }
                    if (idx < delimiter.len) {
                        if (byte == delimiter[idx]) {
                            idx += 1;
                            // we have a match
                            if (idx == delimiter.len) {
                                return bytes_read;
                            }
                        } else {
                            idx = 0;
                        }
                    }
                }
                return error.EndOfStream;
            } else |err| {
                log.err("Unexpected error at '{s}', line {d}, pos {d}: {s} -> {?}", .{
                    telemetry.file_path,
                    telemetry.line,
                    telemetry.pos,
                    @errorName(err),
                    @errorReturnTrace(),
                });
                return error.ReadError;
            }
        }

        fn nextSegment(self: *@This()) !void {
            const file: File = .{ .handle = self.file_handle };
            const reader: AnyReader = file.reader().any();

            const bytes_read: usize = try reader.readAtLeast(&self.buf, buf_size);
            if (bytes_read < buf_size) {
                self.eof = true;
            }
            self.read_buffer = self.buf[0..bytes_read];
        }

        pub fn close(self: @This()) void {
            const file: File = .{ .handle = self.file_handle };
            if (self.file_locked) {
                file.unlock();
            }
            file.close();
        }
    };
}

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
