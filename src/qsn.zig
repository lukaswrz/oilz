const std = @import("std");
const LinearFifo = std.fifo.LinearFifo;
const testing = std.testing;

// https://www.oilshell.org/release/latest/doc/qsn.html

const Decoder = struct {
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
    var p = Decoder.init();
    var i: usize = 0;
    while (try p.next(reader)) |c| : (i += 1) {
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
        "'goblin \\xf0\\x9f\\x91\\xBA'",
        "goblin \u{1f47a}",
    ));
}

test "decode quote escapes" {
    try testing.expect(try decodeEqual(
        "'it\\'s 6AM'",
        "it's 6AM",
    ));
}

// Incomplete.
pub fn Encoder() type {
    return struct {
        const Pending = LinearFifo(u8, .{ .Static = 9 });

        pending: Pending,

        state: enum {
            Start,
            Inner,
            End,
        } = .Start,

        const Self = @This();

        pub fn init() Self {
            return Self{ .pending = Pending.init() };
        }

        pub fn next(self: *Self, reader: anytype) !?u8 {
            while (true) {
                switch (self.state) {
                    .Start => {
                        self.state = .Inner;
                        return '\'';
                    },
                    .Inner => {
                        const ch = reader.readByte() catch |err| switch (err) {
                            error.EndOfStream => {
                                self.state = .End;
                                return '\'';
                            },
                            else => {
                                return err;
                            },
                        };

                        if (std.ascii.isASCII(ch)) {
                            return ch;
                        } else {
                            // TODO: Options to specify whether unicode should be escaped
                            return ch;
                        }
                    },
                    .End => {
                        return null;
                    },
                }
            }
        }
    };
}

fn encodeEqual(comptime in: []const u8, out: []const u8) !bool {
    const reader = std.io.fixedBufferStream(in).reader();
    var s = Encoder().init();
    var i: usize = 0;
    while (try s.next(reader)) |c| : (i += 1) {
        if (i >= out.len or out[i] != c) {
            return false;
        }
    }
    return true;
}

test "encode simple string" {
    try testing.expect(try encodeEqual(
        "test",
        "'test'",
    ));
}
