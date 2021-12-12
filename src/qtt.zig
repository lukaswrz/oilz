const std = @import("std");
const math = std.math;
const testing = std.testing;

// https://www.oilshell.org/release/latest/doc/qtt.html

const AnnotatedData = union(enum) {
    int: math.big.int.Managed,
    float: f64,
    bytes: []u8,
    string: []u8,
    boolean: bool,
};

const Field = struct {
    data: AnnotatedData,
    name: []u8,
};

const Parser = struct {
    pub const Error = error{
        UnexpectedEndOfStream,
    };

    const Self = @This();

    pub fn init() Self {
        return Self{};
    }

    pub fn nextRecord(self: *Self, reader: anytype) !?[]Field {
        _ = self;
        _ = reader;
        return null;
    }
};

const Serializer = struct {};
