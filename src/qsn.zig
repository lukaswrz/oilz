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
        Start,
        Inner,
        Escape,
        Unicode,
        UnicodeDigits,
        Hex,
    } = .Start,

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
        // QSN unicode codepoints accept at most 6 hexadecimal digits (24 bits).
        var unicode_buffer: u24 = 0;

        while (true) {
            const ch = reader.readByte() catch |err| switch (err) {
                error.EndOfStream => {
                    return Error.UnexpectedEndOfStream;
                },
                else => {
                    return err;
                },
            };

            switch (self.state) {
                .Start => switch (ch) {
                    '\'' => {
                        self.state = .Inner;
                    },
                    else => {
                        return Error.StartConditionFailed;
                    },
                },
                .Inner => switch (ch) {
                    '\\' => {
                        self.state = .Escape;
                    },
                    '\'' => {
                        return null;
                    },
                    else => {
                        return ch;
                    },
                },
                .Escape => {
                    switch (ch) {
                        'x' => {
                            self.state = .Hex;
                        },
                        'u' => {
                            self.state = .Unicode;
                        },
                        'n' => {
                            self.state = .Inner;
                            return '\n';
                        },
                        'r' => {
                            self.state = .Inner;
                            return '\r';
                        },
                        't' => {
                            self.state = .Inner;
                            return '\t';
                        },
                        '\\' => {
                            self.state = .Inner;
                            return '\\';
                        },
                        '0' => {
                            self.state = .Inner;
                            return '\x00';
                        },
                        '\'' => {
                            self.state = .Inner;
                            return '\'';
                        },
                        '"' => {
                            self.state = .Inner;
                            return '"';
                        },
                        else => {
                            return Error.UnexpectedEscape;
                        },
                    }
                },
                .Unicode => {
                    switch (ch) {
                        '{' => {
                            self.state = .UnicodeDigits;
                        },
                        else => {
                            return Error.UnicodeStartConditionError;
                        },
                    }
                },
                .UnicodeDigits => {
                    switch (ch) {
                        '0'...'9', 'a'...'f', 'A'...'F' => {
                            unicode_buffer <<= 4;
                            unicode_buffer |= try std.fmt.parseInt(u4, &[_]u8{ch}, 16);
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

                            self.state = .Inner;
                            offset = 0;
                            unicode_buffer = 0;
                            return self.pending.readItem().?;
                        },
                        else => {
                            return Error.InvalidUnicodeDigit;
                        },
                    }
                },
                .Hex => {
                    switch (ch) {
                        '0'...'9', 'a'...'f', 'A'...'F' => {
                            hex_buffer <<= 4;
                            hex_buffer |= try std.fmt.parseInt(u4, &[_]u8{ch}, 16);
                            offset += 1;

                            if (offset == 2) {
                                self.state = .Inner;
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
    var d = Decoder.init();
    var i: usize = 0;
    while (try d.next(reader)) |c| : (i += 1) {
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
    Unicode,
    Hex,
    Raw,
};

pub const UnicodeOptions = struct {
    mode: UnicodeMode = .Raw,
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

        pending: Pending,

        state: enum {
            Start,
            Inner,
            Unicode,
            End,
        } = .Start,

        const Self = @This();

        pub fn init() Self {
            return Self{ .pending = Pending.init() };
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
                const ch = if (self.state == .Inner or self.state == .Unicode and curr_unicode.len > curr_unicode.index)
                    reader.readByte() catch |err| switch (err) {
                        error.EndOfStream => {
                            self.state = .End;
                            return '\'';
                        },
                        else => {
                            return err;
                        },
                    }
                else
                    null;

                switch (self.state) {
                    .Start => {
                        self.state = .Inner;
                        return '\'';
                    },
                    .Inner => {
                        if (std.ascii.isASCII(ch.?)) {
                            if (!std.ascii.isGraph(ch.?) and !std.ascii.isSpace(ch.?)) {
                                // Not visually representable in ASCII.
                                try Self.formatHex(ch.?, self.pending.writer());
                                return self.pending.readItem().?;
                            } else {
                                const suffix: ?u8 = switch (ch.?) {
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
                                    return ch.?;
                                } else {
                                    // An ASCII escape.
                                    const writer = self.pending.writer();
                                    try writer.writeByte('\\');
                                    try writer.writeByte(suffix.?);
                                    return self.pending.readItem().?;
                                }
                            }
                        } else if (unicode_options.mode == .Unicode) {
                            curr_unicode.len = std.unicode.utf8ByteSequenceLength(ch.?) catch {
                                // A raw byte, not unicode or ASCII.
                                try Self.formatHex(ch.?, self.pending.writer());
                                return self.pending.readItem().?;
                            };

                            curr_unicode.buffer[curr_unicode.index] = ch.?;
                            curr_unicode.index += 1;
                            self.state = .Unicode;
                            continue;
                        } else {
                            try Self.formatHex(ch.?, self.pending.writer());
                            return self.pending.readItem().?;
                        }
                    },
                    .Unicode => {
                        if (curr_unicode.len > curr_unicode.index) {
                            curr_unicode.buffer[curr_unicode.index] = ch.?;
                            curr_unicode.index += 1;
                        } else {
                            // The maximum amount of unicode bytes has been reached.
                            const decoded = std.unicode.utf8Decode(curr_unicode.buffer[0..curr_unicode.len]) catch {
                                // Fall back to hex-escaping the bytes if decoding UTF-8 did not succeed.
                                // TODO: Re-read these bytes (except the first one)
                                for (curr_unicode.buffer[0..curr_unicode.len]) |unicode_ch| {
                                    try Self.formatHex(unicode_ch, self.pending.writer());
                                    return self.pending.readItem().?;
                                }
                                self.state = .Inner;
                                return self.pending.readItem().?;
                            };

                            switch (unicode_options.mode) {
                                .Hex => {
                                    for (curr_unicode.buffer) |unicode_ch| {
                                        try Self.formatHex(unicode_ch, self.pending.writer());
                                    }
                                },
                                .Unicode => {
                                    try Self.formatUnicode(decoded, self.pending.writer());
                                },
                                .Raw => {
                                    try self.pending.writer().write(curr_unicode.buffer[0..]);
                                },
                            }
                            self.state = .Inner;
                            return self.pending.readItem().?;
                        }
                    },
                    .End => {
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
    var e = Encoder(case, unicode_options).init();
    var i: usize = 0;
    while (try e.next(reader)) |c| : (i += 1) {
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
        .{ .mode = .Hex, .padding = 2 },
    ));
}

test "encode simple escapes" {
    try testing.expect(try encodeEqual(
        "bob\t1.0\ncarol\t2.0\n",
        "'bob\\t1.0\\ncarol\\t2.0\\n'",
        .lower,
        .{ .mode = .Hex, .padding = 2 },
    ));
}

test "encode hex escapes (lower)" {
    try testing.expect(try encodeEqual(
        "Hello World\x7f",
        "'Hello World\\x7f'",
        .lower,
        .{ .mode = .Hex, .padding = 2 },
    ));
}

test "encode hex escapes (upper)" {
    try testing.expect(try encodeEqual(
        "Hello World\x7F",
        "'Hello World\\x7F'",
        .upper,
        .{ .mode = .Hex, .padding = 2 },
    ));
}

test "encode unicode escapes (lower)" {
    try testing.expect(try encodeEqual(
        "Hello W\u{f6}rld",
        "'Hello W\\u{f6}rld'",
        .lower,
        .{ .mode = .Unicode, .padding = 2 },
    ));
}

test "encode unicode escapes (upper)" {
    try testing.expect(try encodeEqual(
        "Hello W\u{F6}rld",
        "'Hello W\\u{F6}rld'",
        .upper,
        .{ .mode = .Unicode, .padding = 2 },
    ));
}

test "encode large unicode escapes (lower)" {
    try testing.expect(try encodeEqual(
        "goblin \u{1f47a}",
        "'goblin \\u{1f47a}'",
        .lower,
        .{ .mode = .Unicode, .padding = 2 },
    ));
}

test "encode large unicode escapes (upper)" {
    try testing.expect(try encodeEqual(
        "goblin \u{1f47a}",
        "'goblin \\u{1f47a}'",
        .lower,
        .{ .mode = .Unicode, .padding = 2 },
    ));
}

test "encode multiple hex escapes (lower)" {
    try testing.expect(try encodeEqual(
        "goblin \xf0\x9f\x91\xba",
        "'goblin \\xf0\\x9f\\x91\\xba'",
        .lower,
        .{ .mode = .Hex, .padding = 2 },
    ));
}

test "encode multiple hex escapes (upper)" {
    try testing.expect(try encodeEqual(
        "goblin \xF0\x9F\x91\xBA",
        "'goblin \\xF0\\x9F\\x91\\xBA'",
        .upper,
        .{ .mode = .Hex, .padding = 2 },
    ));
}

test "encode quote escapes" {
    try testing.expect(try encodeEqual(
        "it's 6AM",
        "'it\\'s 6AM'",
        .lower,
        .{ .mode = .Hex, .padding = 2 },
    ));
}
