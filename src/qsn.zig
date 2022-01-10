const std = @import("std");
const LinearFifo = std.fifo.LinearFifo;
const Case = std.fmt.Case;
const testing = std.testing;

// https://www.oilshell.org/release/latest/doc/qsn.html

const Decoder = struct {
    // This stores at most one UTF-8-encoded character which will be returned in the future.
    const Pending = LinearFifo(u8, .{ .Static = 4 });

    pending: Pending,

    state: enum {
        start,
        inner,
        escape,
        unicode,
        unicode_digits,
        hex,
    } = .start,

    pub const Error = error{
        UnexpectedEndOfStream,
        StartConditionFailed,
        UnexpectedEscape,
        UnicodeStartConditionError,
        CodepointTooLong,
        EmptyCodepoint,
        InvalidUnicodeDigit,
        InvalidHexDigit,
    };

    const Self = @This();

    pub fn init() Self {
        return Self{ .pending = Pending.init() };
    }

    fn readNext(self: *Self, reader: anytype) !?u8 {
        var offset: usize = 0;
        // Hexadecimal escapes accept exactly 2 digits.
        var hex_buffer: u8 = 0;
        // QSN Unicode codepoints accept at most 6 hexadecimal digits (24 bits).
        var unicode_buffer: u24 = 0;

        while (true) {
            const c = reader.readByte() catch |err| switch (err) {
                error.EndOfStream => {
                    return Error.UnexpectedEndOfStream;
                },
                else => {
                    return err;
                },
            };

            switch (self.state) {
                .start => switch (c) {
                    '\'' => {
                        self.state = .inner;
                    },
                    else => {
                        return Error.StartConditionFailed;
                    },
                },
                .inner => switch (c) {
                    '\\' => {
                        self.state = .escape;
                    },
                    '\'' => {
                        return null;
                    },
                    else => {
                        return c;
                    },
                },
                .escape => {
                    switch (c) {
                        'x' => {
                            self.state = .hex;
                        },
                        'u' => {
                            self.state = .unicode;
                        },
                        'n' => {
                            self.state = .inner;
                            return '\n';
                        },
                        'r' => {
                            self.state = .inner;
                            return '\r';
                        },
                        't' => {
                            self.state = .inner;
                            return '\t';
                        },
                        '\\' => {
                            self.state = .inner;
                            return '\\';
                        },
                        '0' => {
                            self.state = .inner;
                            return '\x00';
                        },
                        '\'' => {
                            self.state = .inner;
                            return '\'';
                        },
                        '"' => {
                            self.state = .inner;
                            return '"';
                        },
                        else => {
                            return Error.UnexpectedEscape;
                        },
                    }
                },
                .unicode => {
                    switch (c) {
                        '{' => {
                            self.state = .unicode_digits;
                        },
                        else => {
                            return Error.UnicodeStartConditionError;
                        },
                    }
                },
                .unicode_digits => {
                    switch (c) {
                        '0'...'9', 'a'...'f', 'A'...'F' => {
                            unicode_buffer <<= 4;
                            unicode_buffer |= try std.fmt.parseInt(u4, &[_]u8{c}, 16);
                            offset += 1;
                            if (offset > 5) {
                                return Error.CodepointTooLong;
                            }
                        },
                        '}' => {
                            if (offset == 0) {
                                return Error.EmptyCodepoint;
                            }
                            var buffer: [4]u8 = undefined;
                            const len = try std.unicode.utf8Encode(try std.math.cast(u21, unicode_buffer), &buffer);
                            if (len > buffer.len) {
                                @panic("Buffer length exceeded");
                            }

                            for (buffer[0..len]) |elem| {
                                try self.pending.writeItem(elem);
                            }

                            self.state = .inner;
                            offset = 0;
                            unicode_buffer = 0;
                            return self.pending.readItem().?;
                        },
                        else => {
                            return Error.InvalidUnicodeDigit;
                        },
                    }
                },
                .hex => {
                    switch (c) {
                        '0'...'9', 'a'...'f', 'A'...'F' => {
                            hex_buffer <<= 4;
                            hex_buffer |= try std.fmt.parseInt(u4, &[_]u8{c}, 16);
                            offset += 1;

                            if (offset == 2) {
                                self.state = .inner;
                                offset = 0;
                                return hex_buffer;
                            }
                            if (offset > 2) {
                                unreachable;
                            }
                        },
                        else => {
                            return Error.InvalidHexDigit;
                        },
                    }
                },
            }
        }
    }

    pub fn next(self: *Self, reader: anytype) !?u8 {
        if (self.pending.count != 0) {
            return self.pending.readItem().?;
        }

        return try self.readNext(reader);
    }
};

fn decodeEqual(comptime in: []const u8, out: []const u8) !bool {
    const reader = std.io.fixedBufferStream(in).reader();
    var decoder = Decoder.init();
    var i: usize = 0;
    while (try decoder.next(reader)) |c| : (i += 1) {
        if (i >= out.len or out[i] != c) {
            return false;
        }
    }
    return true;
}

test "decode simple string" {
    try testing.expect(try decodeEqual(
        "'my favorite song.mp3'",
        "my favorite song.mp3",
    ));
}

test "decode simple escapes" {
    try testing.expect(try decodeEqual(
        "'bob\\t1.0\\ncarol\\t2.0\\n'",
        "bob\t1.0\ncarol\t2.0\n",
    ));
}

test "decode hex escapes" {
    try testing.expect(try decodeEqual(
        "'Hello W\\x6frld'",
        "Hello World",
    ));
}

test "decode unicode escapes" {
    try testing.expect(try decodeEqual(
        "'Hello W\\u{6f}rld'",
        "Hello World",
    ));
}

test "decode unicode escapes with leading zeroes" {
    try testing.expect(try decodeEqual(
        "'Hello W\\u{006f}rld'",
        "Hello World",
    ));
}

test "decode large unicode escapes" {
    try testing.expect(try decodeEqual(
        "'goblin \\u{1f47a}'",
        "goblin \u{1f47a}",
    ));
}

test "decode multiple hex escapes" {
    try testing.expect(try decodeEqual(
        "'goblin \\xf0\\x9f\\x91\\xba'",
        "goblin \u{1f47a}",
    ));
}

test "decode quote escapes" {
    try testing.expect(try decodeEqual(
        "'it\\'s 6AM'",
        "it's 6AM",
    ));
}

pub const UnicodeMode = enum {
    unicode,
    hex,
    raw,
};

pub const UnicodeOptions = struct {
    mode: UnicodeMode = .raw,
    padding: usize = 2,
};

pub fn Encoder(case: Case, unicode_options: UnicodeOptions) type {
    if (unicode_options.padding < 2 or unicode_options.padding > 6) {
        @compileError("unicode escapes must use a padding amount between 2 and 6");
    }

    return struct {
        // This stores QSN-encoded versions of byte sequences which will be returned in the future.
        // It will be able to store the following values:
        // * "\\x00" for simple bytes
        // * "\\x00" ** the length of the UTF-8 sequence (<= 16 bytes)
        // * "\\u{000000}"
        // * raw UTF-8
        const Pending = LinearFifo(u8, .{ .Static = 16 });
        // This keeps track of any remaining bytes of an invalid UTF-8 sequence.
        const Reread = LinearFifo(u8, .{ .Static = 3 });

        pending: Pending,
        reread: Reread,

        state: enum {
            start,
            inner,
            unicode,
            end,
        } = .start,

        const Self = @This();

        pub fn init() Self {
            return Self{ .pending = Pending.init(), .reread = Reread.init() };
        }

        fn formatHex(value: u8, writer: anytype) !void {
            _ = try writer.write("\\x");
            try std.fmt.formatInt(value, 16, case, .{ .width = 2, .fill = '0' }, writer);
        }

        fn formatUnicode(value: u21, writer: anytype) !void {
            _ = try writer.write("\\u{");
            try std.fmt.formatInt(value, 16, case, .{ .width = unicode_options.padding, .fill = '0' }, writer);
            _ = try writer.write("}");
        }

        fn readNext(self: *Self, reader: anytype) !?u8 {
            var curr_unicode: struct {
                buffer: [4]u8 = undefined,
                index: usize = 0,
                len: usize = 0,
            } = .{};

            while (true) {
                const c = if (self.reread.count != 0)
                    self.reread.readItem().?
                else if (self.state == .inner or self.state == .unicode and curr_unicode.len > curr_unicode.index)
                    reader.readByte() catch |err| switch (err) {
                        error.EndOfStream => {
                            self.state = .end;
                            return '\'';
                        },
                        else => {
                            return err;
                        },
                    }
                else
                    null;

                switch (self.state) {
                    .start => {
                        self.state = .inner;
                        return '\'';
                    },
                    .inner => {
                        if (std.ascii.isASCII(c.?)) {
                            if (!std.ascii.isGraph(c.?) and !std.ascii.isSpace(c.?)) {
                                // Not visually representable in ASCII.
                                try Self.formatHex(c.?, self.pending.writer());
                                return self.pending.readItem().?;
                            } else {
                                const suffix: ?u8 = switch (c.?) {
                                    '\n' => 'n',
                                    '\r' => 'r',
                                    '\t' => 't',
                                    '\\' => '\\',
                                    '\x00' => '0',
                                    '\'' => '\'',
                                    '"' => '"',
                                    else => null,
                                };

                                if (suffix == null) {
                                    // An ASCII character.
                                    return c.?;
                                } else {
                                    // An ASCII escape.
                                    const writer = self.pending.writer();
                                    try writer.writeByte('\\');
                                    try writer.writeByte(suffix.?);
                                    return self.pending.readItem().?;
                                }
                            }
                        } else if (unicode_options.mode == .unicode) {
                            curr_unicode.len = std.unicode.utf8ByteSequenceLength(c.?) catch {
                                // A raw byte, not unicode or ASCII.
                                try Self.formatHex(c.?, self.pending.writer());
                                return self.pending.readItem().?;
                            };

                            curr_unicode.buffer[curr_unicode.index] = c.?;
                            curr_unicode.index += 1;
                            self.state = .unicode;
                            continue;
                        } else {
                            try Self.formatHex(c.?, self.pending.writer());
                            return self.pending.readItem().?;
                        }
                    },
                    .unicode => {
                        if (curr_unicode.len > curr_unicode.index) {
                            curr_unicode.buffer[curr_unicode.index] = c.?;
                            curr_unicode.index += 1;
                        } else {
                            // The maximum amount of unicode bytes has been reached.
                            const decoded = std.unicode.utf8Decode(curr_unicode.buffer[0..curr_unicode.len]) catch {
                                try Self.formatHex(curr_unicode.buffer[0], self.pending.writer());
                                if (curr_unicode.len > 1) {
                                    // The remaining bytes should be reread to not dismiss any potential ASCII/Unicode characters.
                                    _ = try self.reread.writer().write(curr_unicode.buffer[1..curr_unicode.len]);
                                }
                                self.state = .inner;
                                return self.pending.readItem().?;
                            };

                            switch (unicode_options.mode) {
                                .hex => {
                                    for (curr_unicode.buffer) |uc| {
                                        try Self.formatHex(uc, self.pending.writer());
                                    }
                                },
                                .unicode => {
                                    try Self.formatUnicode(decoded, self.pending.writer());
                                },
                                .raw => {
                                    try self.pending.writer().write(curr_unicode.buffer[0..]);
                                },
                            }
                            self.state = .inner;
                            return self.pending.readItem().?;
                        }
                    },
                    .end => {
                        return null;
                    },
                }
            }
        }

        pub fn next(self: *Self, reader: anytype) !?u8 {
            if (self.pending.count != 0) {
                return self.pending.readItem().?;
            }

            return try self.readNext(reader);
        }
    };
}

fn encodeEqual(comptime in: []const u8, out: []const u8, comptime case: Case, comptime unicode_options: UnicodeOptions) !bool {
    const reader = std.io.fixedBufferStream(in).reader();
    var encoder = Encoder(case, unicode_options).init();
    var i: usize = 0;
    while (try encoder.next(reader)) |c| : (i += 1) {
        if (i >= out.len or out[i] != c) {
            return false;
        }
    }
    return true;
}

test "encode simple string" {
    try testing.expect(try encodeEqual(
        "my favorite song.mp3",
        "'my favorite song.mp3'",
        .lower,
        .{ .mode = .hex, .padding = 2 },
    ));
}

test "encode simple escapes" {
    try testing.expect(try encodeEqual(
        "bob\t1.0\ncarol\t2.0\n",
        "'bob\\t1.0\\ncarol\\t2.0\\n'",
        .lower,
        .{ .mode = .hex, .padding = 2 },
    ));
}

test "encode hex escapes (lower)" {
    try testing.expect(try encodeEqual(
        "Hello World\x7f",
        "'Hello World\\x7f'",
        .lower,
        .{ .mode = .hex, .padding = 2 },
    ));
}

test "encode hex escapes (upper)" {
    try testing.expect(try encodeEqual(
        "Hello World\x7F",
        "'Hello World\\x7F'",
        .upper,
        .{ .mode = .hex, .padding = 2 },
    ));
}

test "encode unicode escapes (lower)" {
    try testing.expect(try encodeEqual(
        "Hello W\u{f6}rld",
        "'Hello W\\u{f6}rld'",
        .lower,
        .{ .mode = .unicode, .padding = 2 },
    ));
}

test "encode unicode escapes (upper)" {
    try testing.expect(try encodeEqual(
        "Hello W\u{F6}rld",
        "'Hello W\\u{F6}rld'",
        .upper,
        .{ .mode = .unicode, .padding = 2 },
    ));
}

test "encode large unicode escapes (lower)" {
    try testing.expect(try encodeEqual(
        "goblin \u{1f47a}",
        "'goblin \\u{1f47a}'",
        .lower,
        .{ .mode = .unicode, .padding = 2 },
    ));
}

test "encode large unicode escapes (upper)" {
    try testing.expect(try encodeEqual(
        "goblin \u{1f47a}",
        "'goblin \\u{1f47a}'",
        .lower,
        .{ .mode = .unicode, .padding = 2 },
    ));
}

test "encode unicode nonsense (lower)" {
    try testing.expect(try encodeEqual(
        "goblin \xf0\xff\xff\xfe",
        "'goblin \\xf0\\xff\\xff\\xfe'",
        .lower,
        .{ .mode = .unicode, .padding = 2 },
    ));
}

test "encode unicode nonsense with valid ascii (lower)" {
    try testing.expect(try encodeEqual(
        "goblin \xf0abc",
        "'goblin \\xf0abc'",
        .lower,
        .{ .mode = .unicode, .padding = 2 },
    ));
}

test "encode multiple hex escapes (lower)" {
    try testing.expect(try encodeEqual(
        "goblin \xf0\x9f\x91\xba",
        "'goblin \\xf0\\x9f\\x91\\xba'",
        .lower,
        .{ .mode = .hex, .padding = 2 },
    ));
}

test "encode multiple hex escapes (upper)" {
    try testing.expect(try encodeEqual(
        "goblin \xF0\x9F\x91\xBA",
        "'goblin \\xF0\\x9F\\x91\\xBA'",
        .upper,
        .{ .mode = .hex, .padding = 2 },
    ));
}

test "encode quote escapes" {
    try testing.expect(try encodeEqual(
        "it's 6AM",
        "'it\\'s 6AM'",
        .lower,
        .{ .mode = .hex, .padding = 2 },
    ));
}
