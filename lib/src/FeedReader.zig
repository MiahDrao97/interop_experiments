//! This structure represents the reader that does the actual parser of the feed file.
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
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const assert = std.debug.assert;

/// Arena allocator used to parse each JSON object
arena: ArenaAllocator,
/// Indicates that we've parsed the "events" field and are parsing the JSON objects in that array
open_events: bool = false,
/// Track the file's name, line, and position through debug statements and error logs
telemetry: Telemetry,
/// The file stream we're reading from
file_stream: FileStream(8192),

/// global buffer, since we're dipping into this with every `nextScan()` call
threadlocal var global_buf: [4096]u8 = undefined;

/// This structure represents the reader that does the actual parser of the feed file.
const FeedReader = @This();

/// Open a new `FeedReader`
///     `allocator` - used to back the arena
///     `file` - contains the file handler that we'll use for the file stream
///     `file_path` - path to the file we've opened
///     `with_file_lock` - indicates that we opened the file with a lock and it needs to be unlocked on close
pub fn new(allocator: Allocator, file: File, file_path: [:0]const u8, with_file_lock: bool) FeedReader {
    return .{
        .arena = .init(allocator),
        .telemetry = .init(file_path),
        .file_stream = .init(file, with_file_lock),
    };
}

/// Get the next scan result
pub fn nextScan(self: *FeedReader) ScanResult {
    // the file is supposed to be a massive JSON file; we care about the "events" field, which is an array of objects with depth 1
    if (self.open_events) {
        // parse JSON object: from '{' until '}'
        const slice: []const u8 = self.parseNextObject(&global_buf) catch |err| {
            log.err("Failed to parse next object: {s} -> {?}", .{ @errorName(err), @errorReturnTrace() });
            return .err(.failedToRead);
        } orelse return .eof;

        log.debug("\nParsed object: '{s}'", .{slice});

        // we're using an arena, so all the allocations will get destroyed when our arena dies
        const parsed: Scan = json.parseFromSliceLeaky(
            Scan,
            self.arena.allocator(),
            slice,
            ParseOptions{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed },
        ) catch |err| switch (err) {
            error.OutOfMemory => {
                @branchHint(.cold);
                return .err(.outOfMemory);
            },
            else => {
                log.err("Failed to parse feeder object: {s} -> {?}\nObject:\n{s}\n", .{
                    @errorName(err),
                    @errorReturnTrace(),
                    slice,
                });
                return .err(.failedToRead);
            },
        };
        return .ok(parsed);
    } else {
        // we only care about the "events" field
        self.openEvents() catch |err| switch (err) {
            error.EndOfStream => {
                log.warn("Read until end of stream. The \"events\" field was not found ('{s}', line {d}, pos {d}) -> {?}", .{
                    self.telemetry.file_path,
                    self.telemetry.line,
                    self.telemetry.pos,
                    @errorReturnTrace(),
                });
                return .eof;
            },
            else => {
                log.err("Unexpected error while opening array in file '{s}', line {d}, pos {d}: {s} -> {?}", .{
                    self.telemetry.file_path,
                    self.telemetry.line,
                    self.telemetry.pos,
                    @errorName(err),
                    @errorReturnTrace(),
                });
                return .err(.failedToRead);
            },
        };
        // great, we're in the "events" field and past opening square bracket, so we'll denote that
        self.open_events = true;
        return self.nextScan();
    }
}

/// Parse until the "events" field
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
            if (idx < key.len) {
                if (byte == key[idx]) {
                    idx += 1;
                    if (idx == key.len) {
                        inside_events = true;
                        log.debug("Found \"events\" field at '{s}', line {d}, pos {d}", .{
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

        // ok, we've found the "events" field, we're outside the quotes, and we're on the colon character:
        // it has to be the opening of the array next
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

/// Parse until the open square brack ('['). After this, we'll be ready to start parsing objects out of the array.
fn openArray(self: *FeedReader) error{ EndOfStream, InvalidFileFormat }!void {
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

/// Parse next JSON object in our file stream, outputting the bytes read to `buf`
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

/// Destroys the arena and all memory it allocated. Also closes the file stream.
pub fn deinit(self: *FeedReader) void {
    self.file_stream.close();
    self.arena.deinit();
}

/// Tracks basic data about where we are in the open file
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

/// Data stream that loads parts of the file's contents in chunks that are `buf_size` bytes long.
/// Really, there are two buffers. While the one is being read, the other is populated on another thread.
/// Switches between the two to prevent having to wait on the syscall to read from the file.
/// This prevents having to call the OS's read file function more than a few times.
fn FileStream(comptime buf_size: usize) type {
    return struct {
        /// Owned by the OS; underlying type varies on each platform
        file_handle: fd_t,
        /// If true, we'll need to unlock the file when we close the stream
        file_locked: bool,
        /// Buffer a
        buf_a: [buf_size]u8 = [_]u8{0} ** buf_size,
        /// Buffer b
        buf_b: [buf_size]u8 = [_]u8{0} ** buf_size,
        /// Slice of the buffer we're currently reading
        read_buffer: []u8 = undefined,
        /// Set when reading the next buffer to indicate how long `read_buffer` will be on switch
        next_len: usize = 0,
        /// Cursor on the `read_buffer`.
        /// Starts at -1 to indicate that we're starting with no data and need to read in the first chunk.
        cursor: isize = -1,
        /// Which buffer we're reading
        reading: bufId = .a,
        /// Which buffer is loading with the next segment (on its own thread)
        loading: bufId = .b,
        /// Can only load 1 buffer at a time, so this mutex prevents the buffer being read from bleeding into the one on loading
        load_mutex: Mutex,
        /// Since we're got some multi-thread happening, we need to capture any errors that happen
        read_error: ?anyerror = null,
        /// If true, we've encountered the end of the file.
        /// Once the `cursor` reaches the length of the `read_buffer`, we've streamed the whole file.
        eof: bool = false,
        /// Kinda "for real this time" flag to indicate that we're on the last stretch of the buffer, on the way to EOF
        on_final: bool = false,

        const bufId = enum(u1) { a, b };

        /// Initialize with a `file` and `with_file_lock` to indicate that we're reading with a lock
        pub fn init(file: File, with_file_lock: bool) @This() {
            return .{
                .file_handle = file.handle,
                .file_locked = with_file_lock,
                .load_mutex = Mutex{},
            };
        }

        /// Stream the next byte or `null` if EOF
        pub fn nextByte(self: *@This()) !?u8 {
            if (self.cursor < 0) {
                try self.start();
            } else if (self.cursor == self.read_buffer.len) {
                if (self.on_final) {
                    return null;
                }
                try self.switchBuf();
            }
            assert(self.cursor >= 0);

            defer self.cursor += 1;
            return self.read_buffer[@bitCast(self.cursor)];
        }

        fn start(self: *@This()) !void {
            assert(self.cursor < 0);

            try self.nextSegment(.a);
            self.read_buffer = self.buf_a[0..self.next_len];
            self.cursor = 0;

            self.beginNext(.b) catch |err| {
                self.read_error = err;
                return err;
            };
        }

        fn beginNext(self: *@This(), load_buf: bufId) !void {
            if (self.eof) {
                // early return if we determine we're done reading
                return;
            }
            if (self.read_error) |err| {
                // encountered error, which also terminates our read
                return err;
            }
            const thread: Thread = try .spawn(.{}, nextSegment, .{ self, load_buf });
            thread.detach();
        }

        fn switchBuf(self: *@This()) !void {
            self.load_mutex.lock();
            defer self.load_mutex.unlock();

            self.reading = @enumFromInt(~@intFromEnum(self.reading));
            self.loading = @enumFromInt(~@intFromEnum(self.loading));

            self.cursor = 0;
            if (self.eof) {
                self.on_final = true;
            }
            switch (self.reading) {
                .a => self.read_buffer = self.buf_a[0..self.next_len],
                .b => self.read_buffer = self.buf_b[0..self.next_len],
            }
            try self.beginNext(self.loading);
        }

        /// Loads the next chunk of the file into `buf` and resets the `cursor` to 0.
        fn nextSegment(self: *@This(), load_buf: bufId) !void {
            self.load_mutex.lock();
            errdefer |err| self.read_error = err;
            defer self.load_mutex.unlock();

            if (self.eof) {
                return;
            }
            if (self.read_error) |_| {
                // encountered error, which also terminates our read
                return;
            }

            const file: File = .{ .handle = self.file_handle };
            const reader: AnyReader = file.reader().any();

            var to_load: []u8 = undefined;
            switch (load_buf) {
                .a => to_load = &self.buf_a,
                .b => to_load = &self.buf_b,
            }

            const bytes_read: usize = try reader.readAtLeast(to_load, buf_size);
            if (bytes_read < buf_size) {
                self.eof = true;
                self.on_final = bytes_read == 0;
            }
            self.next_len = bytes_read;
        }

        /// Errors stop the stream. Call this to resume the stream.
        pub fn clearError(self: *@This()) void {
            if (self.eof) {
                return;
            }

            if (self.read_error) |_| {
                self.load_mutex.lock();
                defer self.load_mutex.unlock();

                self.read_error = null;
                self.cursor = -1;
            }
        }

        /// Close the file and unlock it if `file_locked`
        pub fn close(self: *@This()) void {
            const file: File = .{ .handle = self.file_handle };
            if (self.file_locked) {
                file.unlock();
            }
            file.close();
            self.* = undefined;
        }
    };
}

/// Represents the JSON fields we care about
const Scan = struct {
    imb: ?[:0]const u8,
    mailPhase: ?[:0]const u8,
};

/// Status of reading our scan that will be passed through our exported function
pub const ReadScanStatus = enum(i32) {
    /// Successfully read scan
    success = 0,
    /// No reader is currently active
    noActiveReader = 1,
    /// Failed to read the file, likely because its contents did not follow the expected format.
    /// If this error is returned, it is quite possibly a bug.
    /// Definitely check the console logs when this happens.
    failedToRead = 2,
    /// Reader is out of memory - extremely unlikely and would be a catastrophic failure
    outOfMemory = 3,
    /// End of file (not an error, but simply indicates that the feed file was completely read and the reader should be closed)
    eof = -1,
};

/// Structure holding the `ReadScanStatus` for the overall success of this operation as well as fields from the scan in the success case.
pub const ScanResult = extern struct {
    /// Status for reading this scan
    status: ReadScanStatus,
    /// IMB code for this scan (can be null, but shouldn't be in success cases)
    imb: ?[*:0]const u8,
    /// Mail phase for this scan (can be null, but shouldn't be in success cases)
    mailPhase: ?[*:0]const u8,

    /// Ok result: pass in the parsed `Scan` object with the fields that we care about
    pub fn ok(scan: Scan) ScanResult {
        return .{
            .status = .success,
            .imb = if (scan.imb != null) scan.imb.?.ptr else null,
            .mailPhase = if (scan.mailPhase != null) scan.mailPhase.?.ptr else null,
        };
    }

    /// Error result: pass in the appropiate status for the failure
    pub fn err(status: ReadScanStatus) ScanResult {
        return .{
            .status = status,
            .imb = null,
            .mailPhase = null,
        };
    }

    /// End of file result
    pub const eof: ScanResult = .{
        .status = .eof,
        .imb = null,
        .mailPhase = null,
    };
};
