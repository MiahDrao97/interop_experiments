//! This structure represents the reader that does the actual parsing of the feed file.
const FeedReader = @This();

/// Arena allocator used to parse each JSON object
arena: *ArenaAllocator,
/// Indicates that we've parsed the "events" field and are parsing the JSON objects in that array
open_events: bool = false,
/// Track the file's name, line, and position through debug statements and error logs
telemetry: Telemetry,
/// The file stream we're reading from
file_stream: AsyncFileStream,
/// The last error encountered, saved for visibility to the managed code (owned by the `arena`)
last_err: ?[:0]const u8 = null,

/// scoped logger
const log = std.log.scoped(.feed_reader);
/// Key on the JSON object that holds the events array
const events_key: []const u8 = "events";

/// Open a new `FeedReader`
///     `arena` - arena allocator
///     `file` - contains the file handler that we'll use for the file stream
///     `file_path` - path to the file we've opened
///     `with_file_lock` - indicates that we opened the file with a lock and it needs to be unlocked on close
pub fn open(
    arena: *ArenaAllocator,
    file: File,
    file_path: [:0]const u8,
    with_file_lock: bool,
) (Thread.SpawnError || Allocator.Error)!*FeedReader {
    const allocator: Allocator = arena.allocator();
    const feed_reader: *FeedReader = try allocator.create(FeedReader);
    errdefer allocator.destroy(feed_reader);
    feed_reader.* = .{
        .arena = arena,
        .telemetry = .init(file_path),
        .file_stream = .init(allocator, file, with_file_lock),
    };

    const read_thread: Thread = try feed_reader.file_stream.startRead();
    read_thread.detach();

    return feed_reader;
}

/// Get the next scan result
pub fn nextScan(self: *FeedReader) ScanResult {
    // the file is supposed to be a massive JSON file; we care about the "events" field, which is an array of objects with depth 1
    if (self.open_events) {
        // parse JSON object: from '{' until '}'
        var buf: [4096]u8 = undefined;
        const slice: []const u8 = self.parseNextObject(&buf) catch |err| {
            // don't assign `last_err` here; that happened deeper down
            log.err("Failed to parse next object: {s} -> {?}", .{ @errorName(err), @errorReturnTrace() });
            return .err(switch (err) {
                error.OutOfMemory => .outOfMemory,
                else => .failedToRead,
            });
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
                return .err(.outOfMemory);
            },
            else => {
                const src: SourceLocation = @src();
                self.last_err = fmt.allocPrintZ(self.arena.allocator(), "{s}: {d}| Failed to parse feeder json object at '{s}', line {d}, pos {d}: {s} -> {?}\nObject:\n{s}\n", .{
                    src.file,
                    src.line,
                    self.telemetry.file_path,
                    self.telemetry.line,
                    self.telemetry.pos,
                    @errorName(err),
                    @errorReturnTrace(),
                    slice,
                }) catch return .err(.outOfMemory);
                log.err("{s}", .{self.last_err.?});
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
            error.OutOfMemory => return .err(.outOfMemory),
            else => {
                // also don't set `last_err`, as that's set deeper in the function
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
fn openEvents(self: *FeedReader) error{
    EndOfStream,
    InvalidFileFormat,
    ReadError,
    OutOfMemory,
}!void {
    var inside_quotes: bool = false;
    var idx: usize = 0;
    var inside_events: bool = false;
    while (self.file_stream.nextByte()) |byte| {
        if (byte == null) {
            // results in EOF result rather than an error
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
            if (idx < events_key.len) {
                if (byte == events_key[idx]) {
                    idx += 1;
                    if (idx == events_key.len) {
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
    } else |err| switch (err) {
        error.OutOfMemory => |oom| {
            log.err("FATAL: Out of memory", .{});
            return oom;
        },
        else => {
            const src: SourceLocation = @src();
            self.last_err = try fmt.allocPrintZ(self.arena.allocator(), "{s}: {d}| Unexpected error while parsing '{s}', line {d}, pos {d}: {s} -> {?}", .{
                src.file,
                src.line,
                self.telemetry.file_path,
                self.telemetry.line,
                self.telemetry.pos,
                @errorName(err),
                @errorReturnTrace(),
            });
            log.err("{s}", .{self.last_err.?});
            return error.ReadError;
        }
    }
}

/// Parse until the open square brack ('['). After this, we'll be ready to start parsing objects out of the array.
fn openArray(self: *FeedReader) error{
    EndOfStream,
    InvalidFileFormat,
    ReadError,
    OutOfMemory,
}!void {
    while (self.file_stream.nextByte()) |byte| {
        if (byte == null) {
            // results in EOF result rather than an error
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
        const src: SourceLocation = @src();
        self.last_err = try fmt.allocPrintZ(self.arena.allocator(), "{s}: {d}| First non-whitespace character in \"events\" field was not '['. Instead was: '{c}'. '{s}', line: {d}, pos: {d}", .{
            src.file,
            src.line,
            byte.?,
            self.telemetry.file_path,
            self.telemetry.line,
            self.telemetry.pos,
        });
        log.err("{s}", .{self.last_err.?});
        return error.InvalidFileFormat;
    } else |err| switch (err) {
        error.OutOfMemory => |oom| {
            log.err("FATAL: Out of memory", .{});
            return oom;
        },
        else => {
            const src: SourceLocation = @src();
            self.last_err = try fmt.allocPrintZ(self.arena.allocator(), "{s}: {d}| Unepxected error while parsing '{s}', line {d}, pos {d}: {s} -> {?}", .{
                src.file,
                src.line,
                self.telemetry.file_path,
                self.telemetry.line,
                self.telemetry.pos,
                @errorName(err),
                @errorReturnTrace(),
            });
            log.err("{s}", .{self.last_err.?});
            return error.ReadError;
        }
    }
}

/// Parse next JSON object in our file stream, outputting the bytes read to `buf`
fn parseNextObject(self: *FeedReader, buf: []u8) error{
    InvalidFormat,
    ObjectNotTerminated,
    BufferOverflow,
    ReadError,
    OutOfMemory,
}!?[]const u8 {
    var open_brace: bool = false;
    var close_brace: bool = false;
    var inside_quotes: bool = false;
    var i: usize = 0;
    while (self.file_stream.nextByte()) |byte| {
        if (i >= buf.len) {
            const src: SourceLocation = @src(); // this is the line no. that will show in the log
            self.last_err = try fmt.allocPrintZ(self.arena.allocator(), "{s}: {d}|FATAL: Overflowed buffer of {d} bytes at '{s}', line: {d}, pos: {d}. This requires a code change to increase buffer size. Current buf:\n\n{s}\n\n", .{
                src.file,
                src.line,
                buf.len,
                self.telemetry.file_path,
                self.telemetry.line,
                self.telemetry.pos,
                buf,
            });
            log.err("{s}", .{self.last_err.?});
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
            const src: SourceLocation = @src();
            self.last_err = try fmt.allocPrintZ(self.arena.allocator(), "{s}: {d}| Unexpected token '{c}': '{s}', line {d}, pos {d}", .{
                src.file,
                src.line,
                byte.?,
                self.telemetry.file_path,
                self.telemetry.line,
                self.telemetry.pos,
            });
            log.err("{s}", .{self.last_err.?});
            return error.InvalidFormat;
        }
    } else |err| switch (err) {
        error.OutOfMemory => |oom| {
            log.err("FATAL: Out of memory", .{});
            return oom;
        },
        else => {
            const src: SourceLocation = @src();
            self.last_err = try fmt.allocPrintZ(self.arena.allocator(), "{s}: {d}| Unexpected error while parsing '{s}', line {d}, pos {d}: {s} -> {?}", .{
                src.file,
                src.line,
                self.telemetry.file_path,
                self.telemetry.line,
                self.telemetry.pos,
                @errorName(err),
                @errorReturnTrace(),
            });
            log.err("{s}", .{self.last_err.?});
            return error.ReadError;
        }
    }

    if (!close_brace) {
        const src: SourceLocation = @src();
        self.last_err = try fmt.allocPrintZ(self.arena.allocator(), "{s}: {d}| Object was not terminated with a closing brace while parsing '{s}', line {d}, pos {d}", .{
            src.file,
            src.line,
            self.telemetry.file_path,
            self.telemetry.line,
            self.telemetry.pos,
        });
        log.err("{s}", .{self.last_err.?});
        return error.ObjectNotTerminated;
    }
    return buf[0..i];
}

/// Free memory or reset the arena to retain some/all capacity
pub fn deinit(self: *FeedReader, reset_mode: ResetMode) void {
    self.file_stream.close();
    _ = self.arena.reset(reset_mode);
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
/// This prevents having to call the OS's read file function more than a few times.
fn FileStream(comptime buf_size: usize) type {
    return struct {
        /// Owned by the OS; underlying type varies on each platform
        file_handle: fd_t,
        /// If true, we'll need to unlock the file when we close the stream
        file_locked: bool,
        /// Buffer
        buf: [buf_size]u8 = [_]u8{0} ** buf_size,
        /// Slice of the buffer we're currently reading
        read_buffer: []u8 = undefined,
        /// Cursor on the `read_buffer`.
        /// Starts at null to indicate we need to read in the first chunk.
        cursor: ?usize = null,
        /// If true, we've encountered the end of the file.
        /// Once the `cursor` reaches the length of the `read_buffer`, we've streamed the whole file.
        eof: bool = false,

        /// Initialize with a `file` and `with_file_lock` to indicate that we're reading with a lock
        pub fn init(file: File, with_file_lock: bool) @This() {
            return .{
                .file_handle = file.handle,
                .file_locked = with_file_lock,
            };
        }

        /// Stream the next byte or `null` if EOF
        pub fn nextByte(self: *@This()) !?u8 {
            if (self.cursor == null or self.cursor.? == self.read_buffer.len) {
                if (self.eof) {
                    return null;
                }
                try self.nextSegment();
            }
            defer self.cursor.? += 1;
            return self.read_buffer[self.cursor.?];
        }

        /// Loads the next chunk of the file into the buffer that matches `load_buf`
        fn nextSegment(self: *@This()) !void {
            if (self.eof) {
                return;
            }

            const file: File = .{ .handle = self.file_handle };
            const reader: AnyReader = file.reader().any();

            const bytes_read: usize = try reader.readAtLeast(&self.buf, buf_size);
            if (bytes_read < buf_size) {
                self.eof = true;
            }
            self.cursor = 0;
            self.read_buffer = self.buf[0..bytes_read];
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

/// Data stream that loads parts of the file's contents in chunks that are `buf_size` bytes long.
/// Really, there are two buffers. While the one is being read, the other is populated on another thread.
/// Switches between the two to prevent having to wait on the syscall to read from the file.
/// This prevents having to call the OS's read file function more than a few times.
fn DualBufferFileStream(comptime buf_size: usize) type {
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
        cursor: usize = 0,
        /// Which buffer we're reading
        reading: BufferId,
        /// Which buffer is loading with the next segment (on its own thread)
        loading: BufferId,
        /// async state machine
        state_machine: *StateMachine(error{ReadError}),
        /// allocator
        allocator: Allocator,
        /// If true, we've encountered the end of the file.
        /// Once the `cursor` reaches the length of the `read_buffer`, we've streamed the whole file.
        eof: bool = false,
        /// Kinda "for real this time" flag to indicate that we're on the last stretch of the buffer, on the way to EOF
        on_final: bool = false,

        const BufferId = enum(u1) { a = 0, b = 1 };
        const State = enum(u8) { running, suspended, complete };
        const dual_buf_stream_log = std.log.scoped(.dual_buffer_stream);
        const Self = @This();

        /// Initialize with a `file` and `with_file_lock` to indicate that we're reading with a lock
        pub fn startNew(
            allocator: Allocator,
            file: File,
            with_file_lock: bool,
        ) (error{ OutOfMemory, ReadError } || Thread.SpawnError)!*Self {
            const new_stream: *Self = try allocator.create(Self);
            errdefer allocator.destroy(new_stream);

            new_stream.* = Self{
                .file_handle = file.handle,
                .file_locked = with_file_lock,
                .state_machine = try .new(allocator),
                .loading = .a,
                .reading = undefined,
                .allocator = allocator,
            };
            try new_stream.state_machine.startWorker(
                SpawnConfig{},
                callNextSegment,
                new_stream,
            );
            try new_stream.firstSegment();
            return new_stream;
        }

        /// Stream the next byte or `null` if EOF
        pub fn nextByte(self: *Self) error{ReadError}!?u8 {
            if (self.cursor == self.read_buffer.len) {
                if (self.on_final) {
                    return null;
                }
                try self.switchBuf();
            }
            assert(self.cursor >= 0);

            defer self.cursor += 1;
            return self.read_buffer[self.cursor];
        }

        fn firstSegment(self: *Self) error{ReadError}!void {
            var err: ?error{ReadError} = null;
            self.state_machine.@"await"(&err, 1000, null) catch unreachable; // sleep 1 us in our loop with no timeout

            if (err) |encountered_err| {
                return encountered_err;
            }

            self.reading = .a;
            self.loading = .b;
            self.read_buffer = self.buf_a[0..self.next_len];
            self.cursor = 0;
            self.state_machine.@"resume"();
        }

        fn callNextSegment(state: *Atomic(State), args: anytype) error{ReadError}!void {
            const self: *Self = args;
            try self.nextSegment(self.loading, state);
        }

        fn switchBuf(self: *Self) error{ReadError}!void {
            var err: ?error{ReadError} = null;
            self.state_machine.@"await"(&err, 1000, null) catch unreachable; // sleep 1 us in our loop with no timeout

            if (err) |encountered_err| {
                return encountered_err;
            }

            self.reading = @enumFromInt(~@intFromEnum(self.reading));
            self.loading = @enumFromInt(~@intFromEnum(self.loading));

            self.cursor = 0;
            if (self.eof) {
                self.on_final = true;
            }
            self.read_buffer = switch (self.reading) {
                .a => self.buf_a[0..self.next_len],
                .b => self.buf_b[0..self.next_len],
            };

            // get the next one started
            self.state_machine.@"resume"();
        }

        /// Loads the next chunk of the file into the buffer that matches `load_buf`
        fn nextSegment(self: *Self, load_buf: BufferId, state: *Atomic(State)) error{ReadError}!void {
            defer {
                if (self.on_final) {
                    state.store(.complete, .release);
                }
            }

            if (self.eof) {
                self.on_final = true;
                return;
            }

            const file: File = .{ .handle = self.file_handle };
            const reader: AnyReader = file.reader().any();

            const to_load: []u8 = switch (load_buf) {
                .a => &self.buf_a,
                .b => &self.buf_b,
            };

            const bytes_read: usize = reader.readAtLeast(to_load, buf_size) catch |err| {
                dual_buf_stream_log.err("Encountered error while reading file: {s} -> {?}", .{ @errorName(err), @errorReturnTrace() });
                return error.ReadError;
            };
            if (bytes_read < buf_size) {
                self.eof = true;
                // this accounts for the unlikely scenario of the file being exactly our buffer size at the end
                self.on_final = bytes_read == 0;
            }
            self.next_len = bytes_read;
        }

        /// Close the file and unlock it if `file_locked`
        pub fn close(self: *Self) void {
            self.state_machine.deinit();
            const file: File = .{ .handle = self.file_handle };
            if (self.file_locked) {
                file.unlock();
            }
            file.close();
            self.allocator.destroy(self);
        }

        fn Worker(
            comptime TArgs: type,
            comptime TError: type,
            function: fn (*Atomic(State), anytype) TError!void,
        ) type {
            return struct {
                args: TArgs,

                pub fn execute(self: *const @This(), ext_state: *Atomic(State)) TError!void {
                    ext_state.store(.running, .release);
                    defer {
                        if (ext_state.load(.monotonic) == .running) {
                            ext_state.store(.suspended, .release);
                        }
                    }
                    try function(ext_state, self.args);
                }
            };
        }

        fn StateMachine(comptime TError: type) type {
            switch (@typeInfo(TError)) {
                .error_set => {},
                else => @compileError("Expected error set type for TError. Found '" ++ @typeName(TError) ++ "'"),
            }
            return struct {
                allocator: Allocator,
                _internals: Internals,

                const Internals = struct {
                    state: Atomic(State),
                    start_next: bool,
                    err: ?TError = null,
                };

                pub fn new(
                    allocator: Allocator,
                ) Allocator.Error!*StateMachine(TError) {
                    const state_machine: *StateMachine(TError) = try allocator.create(StateMachine(TError));
                    errdefer allocator.destroy(state_machine);
                    state_machine.* = .{
                        .allocator = allocator,
                        ._internals = Internals{
                            .state = .init(.suspended),
                            .start_next = true,
                        },
                    };

                    return state_machine;
                }

                pub fn startWorker(
                    self: *StateMachine(TError),
                    spawn_config: SpawnConfig,
                    function: fn (*Atomic(State), anytype) TError!void,
                    args: anytype,
                ) (Allocator.Error || Thread.SpawnError)!void {
                    assert(self._internals.start_next);
                    assert(self.getState() != .running);

                    const ArgsType = @TypeOf(args);
                    const worker: Worker(ArgsType, TError, function) = .{ .args = args };

                    self._internals.state.store(.running, .release);
                    // keep it on single thread, nonblocking
                    const thread: Thread = try .spawn(spawn_config, eventLoop, .{ self, ArgsType, function, worker });
                    thread.detach();
                }

                fn eventLoop(
                    self: *StateMachine(TError),
                    comptime TArgs: type,
                    function: fn (*Atomic(State), anytype) TError!void,
                    worker: Worker(TArgs, TError, function),
                ) void {
                    var i: usize = 0;
                    while (self.getState() != .complete and self._internals.err == null) {
                        defer i += 1;
                        if (self._internals.start_next) {
                            self._internals.start_next = false;
                            worker.execute(&self._internals.state) catch |err| {
                                self._internals.err = err;
                            };
                        }
                    }
                }

                pub fn @"await"(
                    self: *StateMachine(TError),
                    err_out: *?TError,
                    sleep_ns: u64,
                    timeout_ns: ?u64,
                ) error{Timeout}!void {
                    const start_time: i128 = std.time.nanoTimestamp();
                    while (self.getState() == .running and self._internals.err == null) {
                        Thread.sleep(sleep_ns);
                        if (timeout_ns) |timeout| {
                            if (std.time.nanoTimestamp() - start_time > timeout) {
                                return error.Timeout;
                            }
                        }
                    }
                    if (self._internals.err) |err| {
                        err_out.* = err;
                    }
                }

                pub fn @"resume"(self: *StateMachine(TError)) void {
                    assert(!self._internals.start_next);
                    self._internals.state.store(.running, .release);
                    self._internals.start_next = true;
                }

                pub fn cancel(self: *StateMachine(TError)) void {
                    // strongest atomic ordering to complete
                    self._internals.state.store(.complete, .seq_cst);
                }

                pub fn getState(self: *StateMachine(TError)) State {
                    return self._internals.state.load(.monotonic);
                }

                pub fn hasError(self: *StateMachine(TError)) ?TError {
                    return self._internals.err;
                }

                pub fn deinit(self: *StateMachine(TError)) void {
                    self.cancel();
                    self.allocator.destroy(self);
                }
            };
        }
    };
}

/// File stream that loads the entire file into heap memory on another thread
const AsyncFileStream = struct {
    /// File handle
    file_handle: fd_t,
    /// File opened with lock (needs to be unlocked on close)
    with_lock: bool,
    /// Whether or not the file has been read (starts as false)
    /// WARN : Please don't touch this field
    _file_read: Atomic(bool),
    /// Error encountered while reading
    err: ?anyerror = null,
    /// Position we're at in the file stream
    cursor: usize = 0,
    /// Contents of the file
    contents: []const u8,
    /// Allocator
    allocator: Allocator,

    /// Logger scoped to this struct
    const async_fs_log = std.log.scoped(.async_file_stream);

    /// Initialize a new `AsyncFileStream` with an allocator, file, and whether or not the file was opened with a lock
    pub fn init(allocator: Allocator, file: File, with_lock: bool) AsyncFileStream {
        return .{
            .file_handle = file.handle,
            .with_lock = with_lock,
            ._file_read = .init(false),
            .contents = undefined,
            .allocator = allocator,
        };
    }

    /// Start reading the file (returns the thread performing the operation)
    pub fn startRead(self: *AsyncFileStream) Thread.SpawnError!Thread {
        return try Thread.spawn(.{}, read, .{self});
    }

    fn read(self: *AsyncFileStream) !void {
        defer {
            self._file_read.store(true, .release);
            async_fs_log.info("Finished reading file", .{});
        }
        errdefer |e| self.err = e;

        const file: File = .{ .handle = self.file_handle };
        // use a buffered reader for even less sys calls
        var buf_reader: BufferedReader(4096, File.Reader) = std.io.bufferedReader(file.reader());
        const reader: AnyReader = buf_reader.reader().any();

        // TODO : What max size do we wanna handle? Should we do some chunking after a certain threshold?
        self.contents = try reader.readAllAlloc(self.allocator, std.math.maxInt(usize));
    }

    /// Get the next byte (has to wait while the file is being read)
    pub fn nextByte(self: *AsyncFileStream) !?u8 {
        while (!self._file_read.load(.monotonic)) {}
        if (self.err) |e| {
            return e;
        }

        if (self.cursor >= self.contents.len) {
            return null;
        }

        defer self.cursor += 1;
        return self.contents[self.cursor];
    }

    /// Close the file and free claimed memory
    pub fn close(self: *const AsyncFileStream) void {
        while (!self._file_read.load(.monotonic)) {}
        const file: File = .{ .handle = self.file_handle };
        if (self.with_lock) {
            file.unlock();
        }
        file.close();
    }

    /// Free the contents
    pub fn deinit(self: *AsyncFileStream) void {
        while (!self._file_read.load(.monotonic)) {}
        self.allocator.free(self.contents);
        self.* = undefined;
    }
};

/// Represents the JSON fields we care about
const Scan = struct {
    imb: ?[:0]const u8,
    mailPhase: ?[:0]const u8,
};

/// Status of reading our scan that will be passed through our exported function
pub const ReadScanStatus = enum(i8) {
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
            .imb = if (scan.imb) |imb| imb.ptr else null,
            .mailPhase = if (scan.mailPhase) |mailPhase| mailPhase.ptr else null,
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

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ResetMode = ArenaAllocator.ResetMode;
const File = std.fs.File;
const AnyReader = std.io.AnyReader;
const Parsed = json.Parsed;
const ParseOptions = json.ParseOptions;
const json = std.json;
const ascii = std.ascii;
const windows = std.os.windows;
const posix = std.posix;
const fmt = std.fmt;
const fd_t = posix.fd_t;
const Thread = std.Thread;
const SpawnConfig = Thread.SpawnConfig;
const assert = std.debug.assert;
const SourceLocation = std.builtin.SourceLocation;
const Atomic = std.atomic.Value;
const BufferedReader = std.io.BufferedReader;
