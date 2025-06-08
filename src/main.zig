// (c) 2025 Lawrence Laz
// This code is licensed under MIT license (see LICENSE for details)

// TOOD: Implement parsing as per https://www.json.org/json-en.html
// TODO: Pass the test suite at https://github.com/nst/JSONTestSuite

const std = @import("std");

pub const json = struct {
    pub fn stringify(value: anytype, writer: std.io.AnyWriter) !void {
        const T = @TypeOf(value);
        if (isString(T, value)) {
            try writer.writeAll("\"");
        } else if (isArray(T)) {
            try writer.writeAll("[");
        }
        try stringifyValue(value, writer);
        if (isString(T, value)) {
            try writer.writeAll("\"");
        } else if (isArray(T)) {
            try writer.writeAll("]");
        }
    }

    fn stringifyValue(value: anytype, writer: std.io.AnyWriter) !void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .bool => try writer.writeAll(if (value) "true" else "false"),
            .int => try stringifyInt(value, writer),
            .comptime_int => try writer.print("{d}", .{value}),
            .float => try writer.print("{d}", .{value}),
            .comptime_float => try writer.print("{d}", .{value}),
            .pointer => |ptr_info| switch (ptr_info.size) {
                .One => switch (@typeInfo(ptr_info.child)) {
                    .array => |array_info| if (array_info.child == u8)
                        try writer.writeAll(@as([]const std.meta.Elem(ptr_info.child), value))
                    else
                        try stringifyArray(@as([]const std.meta.Elem(ptr_info.child), value), writer),
                    else => try stringifyValue(value.*, writer),
                },
                .Many, .Slice => {
                    if (ptr_info.size == .Many and ptr_info.sentinel == null)
                        @compileError("Cannot stringify type '" ++ @typeName(T) ++ "' without sentinel");
                    const slice = if (ptr_info.size == .Many) std.mem.span(value) else value;
                    if (ptr_info.child == u8)
                        try writer.writeAll(slice)
                    else
                        try stringifyArray(slice, writer);
                },
                else => @compileError("Cannot stringify type '" ++ @typeName(T) ++ "'"),
            },
            .array => |array_info| if (array_info.child == u8)
                try writer.writeAll(@as([]const array_info.child, &value))
            else
                try stringifyArray(@as([]const array_info.child, &value), writer),
            .@"struct" => |struct_info| if (struct_info.is_tuple)
                try stringifyTuple(value, writer)
            else if (isArray(T))
                try stringifyArray(value.items, writer)
            else if (isHashMap(T))
                try stringifyHashMap(value, writer)
            else
                try stringifyStruct(value, writer),
            .null => try writer.writeAll("null"),
            .optional => if (value) |unwrapped| try stringifyValue(unwrapped, writer) else try writer.writeAll("null"),
            .@"enum" => |enum_info| if (enum_info.is_exhaustive) try writer.writeAll(@tagName(value)) else {
                if (std.enums.tagName(T, value)) |tag|
                    try writer.writeAll(tag)
                else
                    try writer.print("{d}", .{@as(enum_info.tag_type, @intFromEnum(value))});
            },
            .enum_literal => try writer.writeAll(@tagName(value)),
            .@"union" => try stringifyUnion(value, writer),
            else => @compileError("Cannot stringify type '" ++ @typeName(T) ++ "'"),
        }
    }

    fn stringifyInt(value: anytype, writer: std.io.AnyWriter) !void {
        const char_map = "0123456789";
        const T = @TypeOf(value);
        const int_info = @typeInfo(T).int;
        var abs_value = if (int_info.signedness == .unsigned) value else @abs(value);
        const digit_count = comptime blk: {
            break :blk std.math.log10(std.math.maxInt(T)) +
                1 +
                (if (int_info.signedness == .signed) 1 else 0);
        };
        var buf: [digit_count]u8 = undefined;
        var index: usize = digit_count - 1;
        if (abs_value == 0) {
            buf[index] = '0';
            index -= 1;
        } else while (abs_value != 0 and index != 0) {
            buf[index] = char_map[@as(usize, @intCast(abs_value % 10))];
            index -= 1;
            abs_value /= 10;
        }
        if (int_info.signedness == .signed and value < 0) {
            buf[index] = '-';
        } else {
            index += 1;
        }
        try writer.writeAll(buf[index..]);
    }

    fn stringifyArray(value: anytype, writer: std.io.AnyWriter) !void {
        if (value.len == 0) {
            return;
        }
        for (value[0 .. value.len - 1]) |item| {
            try stringifyValue(item, writer);
            try writer.writeAll(","); // TODO: Optimize
        }
        try stringifyValue(value[value.len - 1], writer);
    }

    fn stringifyUnion(value: anytype, writer: std.io.AnyWriter) !void {
        const T = @TypeOf(value);
        const union_info = @typeInfo(T).@"union";
        if (union_info.tag_type) |UnionTagType| {
            const fields: []const std.builtin.Type.UnionField = std.meta.fields(T);
            inline for (fields) |field| {
                if (value == @field(UnionTagType, field.name)) {
                    const array_open = if (isArray(field.type)) "[" else "";
                    const string_open = if (isString(field.type, @field(value, field.name))) "\"" else "";
                    try writer.writeAll("{\"" ++ field.name ++ "\":" ++ array_open ++ string_open);
                    if (field.type == void) {
                        try writer.writeAll("{}");
                    } else {
                        try stringifyValue(@field(value, field.name), writer);
                    }
                    const last_array_close = if (isArray(field.type)) "]" else "";
                    const last_string_close = if (isString(field.type, @field(value, field.name))) "\"" else "";
                    try writer.writeAll(last_array_close ++ last_string_close ++ "}");
                    break;
                }
            }
            return;
        } else {
            @compileError("Cannot stringify untagged union '" ++ @typeName(T) ++ "'");
        }
    }

    fn stringifyStruct(value: anytype, writer: std.io.AnyWriter) !void {
        const T = @TypeOf(value);
        const fields: []const std.builtin.Type.StructField = std.meta.fields(T);
        inline for (fields, 0..) |field, i| {
            const prev_field: ?std.builtin.Type.StructField = if (i != 0) fields[i - 1] else null;
            const prev_array_close = if (prev_field != null and isArray(prev_field.?.type)) "]" else "";
            const prev_string_close = if (prev_field != null and isString(prev_field.?.type, @field(value, prev_field.?.name))) "\"" else "";
            const object_open_or_comma = if (i == 0) "{" else ",";
            const array_open = if (isArray(field.type)) "[" else "";
            const string_open = if (isString(field.type, @field(value, field.name))) "\"" else "";
            try writer.writeAll(prev_array_close ++ prev_string_close ++ object_open_or_comma ++
                "\"" ++ field.name ++ "\":" ++
                array_open ++ string_open);
            try stringifyValue(@field(value, field.name), writer);
        }
        const last_field = fields[fields.len - 1];
        const last_array_close = if (isArray(last_field.type)) "]" else "";
        const last_string_close = if (isString(last_field.type, @field(value, last_field.name))) "\"" else "";
        try writer.writeAll(last_array_close ++ last_string_close ++ "}");
    }

    fn stringifyTuple(value: anytype, writer: std.io.AnyWriter) !void {
        const T = @TypeOf(value);
        const struct_info = @typeInfo(T).@"struct";
        if (!struct_info.is_tuple) @compileError("Expected a tuple but got '" ++ @typeName(T) ++ "'");
        const fields: []const std.builtin.Type.StructField = std.meta.fields(T);
        inline for (fields, 0..) |field, i| {
            const prev_field: ?std.builtin.Type.StructField = if (i != 0) fields[i - 1] else null;
            const prev_array_close = if (i != 0 and isArray(prev_field.?.type)) "]" else "";
            const prev_string_close = if (i != 0 and isString(prev_field.?.type, @field(value, prev_field.?.name))) "\"" else "";
            const array_open_or_comma = if (i == 0) "[" else ",";
            const array_open = if (isArray(field.type)) "[" else "";
            const string_open = if (isString(field.type, @field(value, field.name))) "\"" else "";
            try writer.writeAll(prev_array_close ++ prev_string_close ++ array_open_or_comma ++ array_open ++ string_open);
            try stringifyValue(@field(value, field.name), writer);
        }
        const last_field = fields[fields.len - 1];
        const last_array_close = if (isArray(last_field.type)) "]" else "";
        const last_string_close = if (isString(last_field.type, @field(value, last_field.name))) "\"" else "";
        try writer.writeAll(last_array_close ++ last_string_close ++ "]");
    }

    fn stringifyHashMap(value: anytype, writer: std.io.AnyWriter) !void {
        const T = @TypeOf(value);
        const TKey = getHashMapKeyType(T);
        const TVal = getHashMapValueType(T);
        var iter = value.iterator();
        var prev_val: ?TVal = null;
        while (iter.next()) |kvp| {
            if (prev_val != null and isArray(TVal)) try writer.writeByte(']');
            if (prev_val != null and isString(TVal, prev_val.?)) try writer.writeByte('"');
            const object_open_or_comma = if (prev_val == null) "{" else ",";
            const array_open = if (isArray(TVal)) "[" else "";
            const string_open = if (isString(TVal, kvp.value_ptr.*)) "\"" else "";
            try writer.writeAll(object_open_or_comma ++ "\"");
            if (hasToString(TKey)) {
                try stringifyValue(kvp.key_ptr.toString(), writer);
            } else {
                try stringifyValue(kvp.key_ptr.*, writer);
            }
            try writer.writeAll("\":" ++ array_open ++ string_open);
            try stringifyValue(kvp.value_ptr.*, writer);
            prev_val = kvp.value_ptr.*;
        }
        if (prev_val == null) try writer.writeByte('{');
        if (isArray(TVal)) try writer.writeByte(']');
        if (prev_val != null and isString(TVal, prev_val.?)) try writer.writeByte('"');
        try writer.writeByte('}');
    }

    inline fn isArray(T: type) bool {
        comptime {
            return switch (@typeInfo(T)) {
                .array => |array_type_info| array_type_info.child != u8,
                .pointer => |ptr_type_info| ptr_type_info.child != u8,
                .@"struct" => @hasField(T, "items") and
                    (T == std.ArrayList(std.meta.Child(std.meta.FieldType(T, .items))) or
                    T == std.ArrayListUnmanaged(std.meta.Child(std.meta.FieldType(T, .items)))),
                else => false,
            };
        }
    }

    inline fn isHashMap(comptime T: type) bool {
        comptime {
            return std.meta.activeTag(@typeInfo(T)) == .@"struct" and
                @hasDecl(T, "iterator") and
                (T == std.StringHashMapUnmanaged(getHashMapValueType(T)) or
                T == std.AutoHashMapUnmanaged(getHashMapKeyType(T), getHashMapValueType(T)));
        }
    }

    inline fn hasToString(comptime T: type) bool {
        comptime {
            return switch (@typeInfo(T)) {
                .@"struct" => @hasDecl(T, "toString"),
                else => false,
            };
        }
    }

    inline fn getHashMapKeyType(comptime T: type) type {
        return @typeInfo(@typeInfo(@TypeOf(T.getKey)).@"fn".return_type.?).optional.child;
    }

    inline fn getHashMapValueType(comptime T: type) type {
        return @typeInfo(@typeInfo(@TypeOf(T.get)).@"fn".return_type.?).optional.child;
    }

    inline fn isString(T: type, val: T) bool {
        return switch (@typeInfo(T)) {
            .array => |array_info| array_info.child == u8,
            .pointer => |ptr_info| switch (ptr_info.size) {
                .One => switch (@typeInfo(ptr_info.child)) {
                    .array => |array_info| array_info.child == u8,
                    else => false,
                },
                .Many, .Slice => ptr_info.child == u8,
                else => false,
            },
            .@"enum" => |enum_info| if (enum_info.is_exhaustive)
                true
            else
                std.enums.tagName(T, val) != null,
            .enum_literal => true,
            else => false,
        };
    }

    pub fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        try stringify(value, buf.writer().any());
        return buf.toOwnedSlice();
    }

    const ParseError = error{invalid_json};

    const Parser = struct {
        const buf_len: usize = 256;

        buf: [buf_len]u8 = .{0} ** buf_len,
        slice: []u8 = &.{},
        reader: std.io.AnyReader,

        fn init(reader: std.io.AnyReader) Parser {
            return .{ .reader = reader };
        }

        fn feed(parser: *Parser) !void {
            if (parser.slice.len == 0) {
                const bytes_read = try parser.reader.read(&parser.buf);
                if (bytes_read > 0) {
                    parser.slice = (&parser.buf)[0..bytes_read];
                }
            }
        }

        fn peekByte(parser: *Parser) !?u8 {
            try parser.feed();
            return if (parser.slice.len > 0) parser.slice[0] else null;
        }

        fn isNthByteScalar(parser: *Parser, index: usize, slice: []const u8) !bool {
            try parser.feed();
            if (parser.slice.len > index) {
                if (std.mem.indexOfScalar(u8, slice, parser.slice[index])) |_| {
                    return true;
                } else {
                    return false;
                }
            } else {
                return false;
            }
        }

        fn peekByteAssume(parser: *Parser) !u8 {
            try parser.feed();
            return if (parser.slice.len > 0) parser.slice[0] else error.invalid_json;
        }

        fn peekBytesAtLeast(parser: *Parser, comptime len: usize) !?[]const u8 {
            if (len > buf_len) @compileError("peekBytes len has to be less than 256");
            try parser.feed();
            return if (len < parser.slice.len) parser.slice[0..len] else parser.slice;
        }

        // TODO: Assume variants without .feed, maybe all should be like that?
        fn consumeByte(parser: *Parser) !u8 {
            try parser.feed();
            defer parser.slice = parser.slice[1..];
            return parser.slice[0];
        }

        fn discardBytes(parser: *Parser, len: usize) void {
            parser.slice = parser.slice[len..];
        }

        fn consumeBytesBufAssume(parser: *Parser, comptime size: usize, buf: []u8) !void {
            try parser.feed();
            defer parser.slice = parser.slice[size..];
            buf[0..size].* = parser.slice[0..size].*;
        }

        fn consumeWhitespace(parser: *Parser) !void {
            while (try parser.peekByte()) |byte| {
                switch (byte) {
                    ' ', '\n', '\r', '\t' => _ = try parser.consumeByte(),
                    else => return,
                }
            }
        }

        fn checkSlice(parser: *Parser, comptime slice: []const u8) !bool {
            return std.mem.eql(u8, slice, try parser.peekBytesAtLeast(slice.len) orelse "");
        }
    };

    // TODO: Accept anytype for reader?

    /// Parses JSON string from reader into a given target value.
    /// Does not allocate.
    pub fn parse(value_ptr: anytype, reader: std.io.AnyReader) !void {
        var parser: Parser = .init(reader);
        try parseElement(value_ptr, &parser);
    }

    fn isPtr(comptime T: type) bool {
        return std.meta.activeTag(@typeInfo(T)) == .pointer;
    }

    fn parseElement(value_ptr: anytype, parser: *Parser) !void {
        comptime if (!isPtr(@TypeOf(value_ptr))) @compileError("Expected a pointer, got '" ++ @typeName(@TypeOf(value_ptr)) ++ "'.");

        try parser.consumeWhitespace();
        try parseValue(value_ptr, parser);
        try parser.consumeWhitespace();
        // TOOD: Make sure nothing else is left to parse?
    }

    fn parseValue(value_ptr: anytype, parser: *Parser) !void {
        const TPtr = @TypeOf(value_ptr);
        const T = std.meta.Child(TPtr);

        switch (@typeInfo(T)) {
            .bool => try parseBool(value_ptr, parser),
            .int, .float => try parseNumber(value_ptr, parser),
            .pointer => |ptr_info| switch (ptr_info.size) {
                .One => switch (@typeInfo(ptr_info.child)) {
                    .array => |array_info| {
                        if (array_info.child == u8) {
                            @compileError("string not implemented");
                        } else {
                            const TItem = @typeInfo(T).array.child;
                            try parseArrayBuf(TItem, value_ptr, parser);
                        }
                    },
                    else => @compileError("value not implemented"),
                },
                .Many, .Slice => {
                    var len: usize = 0;
                    if (ptr_info.child == u8) {
                        const slice = try parseStringBuf(value_ptr.*, parser);
                        len = slice.len;
                    } else {
                        const slice = try parseArrayBuf(ptr_info.child, value_ptr.*, parser);
                        len = slice.len;
                    }

                    if (ptr_info.sentinel) |sentinel| {
                        value_ptr.*[len] = @as(*const ptr_info.child, @ptrCast(@alignCast(sentinel))).*;
                    }
                },
                .C => @compileError("Cannot parse JSON into 'C' ptr"),
            },
            .array => |array_info| {
                const slice = if (array_info.child == u8)
                    try parseStringBuf(value_ptr, parser)
                else
                    try parseArrayBuf(array_info.child, value_ptr, parser);

                if (array_info.sentinel) |sentinel| {
                    value_ptr.*[slice.len] = @as(*const array_info.child, @ptrCast(@alignCast(sentinel))).*;
                }
            },
            .vector => @compileError("TODO: Implement vector"),
            .@"struct" => |struct_info| if (struct_info.is_tuple)
                @compileError("TODO: Implement tuple")
            else if (isArray(T))
                @compileError("TODO: Implement array list")
            else if (isHashMap(T))
                @compileError("TODO: Implement hashmap")
            else
                try parseObject(value_ptr, parser),
            .optional => try parseOptional(value_ptr, parser),
            .@"enum" => |enum_info| if (enum_info.is_exhaustive) {
                @compileError("TODO: Implement exhaustivve enum");
            } else {
                @compileError("TODO: Implement non-exhaustive enum");
            },
            .@"union" => @compileError("TODO: Implement union"),
            .comptime_int => @compileError("Cannot parse JSON into 'comptime_int'"),
            .comptime_float => @compileError("Cannot parse JSON into 'comptime_float'"),
            .null => @compileError("Cannot parse JSON into 'null'"),
            .enum_literal => @compileError("Cannot parse JSON into 'enum_literal'"),
            .type => @compileError("Cannot parse JSON into 'type'"),
            .void => @compileError("Cannot parse JSON into 'void'"),
            .noreturn => @compileError("Cannot parse JSON into 'noreturn'"),
            .undefined => @compileError("Cannot parse JSON into 'undefined'"),
            .error_union => @compileError("Cannot parse JSON into 'error_union'"),
            .error_set => @compileError("Cannot parse JSON into 'error_set'"),
            .@"fn" => @compileError("Cannot parse JSON into 'fn'"),
            .@"opaque" => @compileError("Cannot parse JSON into 'opaque'"),
            .frame => @compileError("Cannot parse JSON into 'frame'"),
            .@"anyframe" => @compileError("Cannot parse JSON into 'anyframe'"),
        }
    }

    fn parseArrayBuf(comptime T: type, buf: []T, parser: *Parser) ![]T {
        var slice: []T = buf[0..0];

        if (try parser.consumeByte() != '[') {
            return error.invalid_json;
        }
        try parser.consumeWhitespace();

        // TODO: consumeByte should return optional for when stream ends?
        sw: switch (try parser.peekByte() orelse return error.invalid_json) {
            ']' => return slice,
            // TODO: validate incorrect consecutive commas, etc.
            ',' => if (slice.len == 0) return error.invalid_json else {
                _ = try parser.consumeByte();
                continue :sw try parser.peekByte() orelse return error.invalid_json;
            },
            else => {
                try parseElement(&buf[slice.len], parser);
                slice = try appendBuf(
                    T,
                    buf,
                    slice.len,
                    buf[slice.len],
                );
                continue :sw try parser.peekByte() orelse return error.invalid_json;
            },
        }
    }

    fn parseObject(value_ptr: anytype, parser: *Parser) !void {
        const TPtr = @TypeOf(value_ptr);
        const T = std.meta.Child(TPtr);
        // TODO: would trying to init class with exact fields be faster somehow? idk.
        // var result: T = std.mem.zeroInit(T, .{});
        value_ptr.* = std.mem.zeroInit(T, .{});
        var buf: [256]u8 = @splat(0);
        if (try parser.consumeByte() != '{') {
            return error.invalid_json;
        }
        try parser.consumeWhitespace();
        sw: switch (try parser.peekByte() orelse return error.invalid_json) {
            '}' => {
                _ = try parser.consumeByte();
                return;
            },
            ',' => {
                _ = try parser.consumeByte();
                continue :sw try parser.peekByte() orelse return error.invalid_json;
            },
            else => {
                const member_name = try parseStringBuf(&buf, parser);
                try parser.consumeWhitespace();
                if (try parser.consumeByte() != ':') {
                    return error.invalid_json;
                }

                var member_found = false;
                // TODO: non-linear search with early exit?
                inline for (std.meta.fields(T)) |field| {
                    const struct_field: std.builtin.Type.StructField = field;
                    if (std.mem.eql(u8, struct_field.name, member_name)) {
                        member_found = true;
                        try parseElement(&@field(value_ptr, struct_field.name), parser);
                        // @field(result, struct_field.name) = member_value;
                    }
                }

                if (member_found) {
                    // _ = parser.consumeByte()

                } else {
                    return error.invalid_json;
                }

                continue :sw try parser.peekByte() orelse return error.invalid_json;
            },
        }
        return error.invalid_json;
    }

    fn parseNumber(value_ptr: anytype, parser: *Parser) !void {
        const TPtr = @TypeOf(value_ptr);
        const T = std.meta.Child(TPtr);
        switch (@typeInfo(T)) {
            .int => try parseInteger(value_ptr, parser),
            .float => {
                try parser.feed();
                // var slice: []u8 = parser.buf[0..0];
                var len: usize = 0;
                if (try parser.isNthByteScalar(len, "-")) { // TODO: Would it be faster to do a simple check?
                    len += 1;
                }

                // TODO check bounds
                integer: switch (parser.slice[len]) {
                    '0'...'9' => {
                        len += 1;
                        if (parser.slice.len > len) continue :integer parser.slice[len];
                    },
                    else => {},
                }

                if (try parser.isNthByteScalar(len, ".")) {
                    len += 1;
                    digits: switch (parser.slice[len]) {
                        '0'...'9' => {
                            len += 1;
                            if (parser.slice.len > len) continue :digits parser.slice[len];
                        },
                        else => {},
                    }
                }

                if (try parser.isNthByteScalar(len, "eE")) {
                    len += 1;
                    if (try parser.isNthByteScalar(len, "-+")) {
                        len += 1;
                    }
                    digits: switch (parser.slice[len]) {
                        '0'...'9' => {
                            len += 1;
                            if (parser.slice.len > len) continue :digits parser.slice[len];
                        },
                        else => {},
                    }
                }

                value_ptr.* = try std.fmt.parseFloat(T, parser.slice[0..len]);
                parser.discardBytes(len);
                return;
            },
            else => @compileError("Type '" ++ @typeName(T) ++ "' is not a number."),
        }
    }

    fn parseInteger(value_ptr: anytype, parser: *Parser) !void {
        const TPtr = @TypeOf(value_ptr);
        const T = std.meta.Child(TPtr);
        switch (@typeInfo(T)) {
            .int => |int_info| {
                switch (int_info.signedness) {
                    .signed => if ((try parser.peekByte() orelse return error.invalid_json) == '-') {
                        _ = try parser.consumeByte();
                        try parseUnsignedInteger(value_ptr, parser);
                        value_ptr.* *= -1;
                    } else {
                        try parseUnsignedInteger(value_ptr, parser);
                    },
                    .unsigned => try parseUnsignedInteger(value_ptr, parser),
                }
            },
            else => @compileError("Type '" ++ @typeName(T) ++ "' is not an integer."),
        }
    }

    fn parseUnsignedInteger(value_ptr: anytype, parser: *Parser) !void {
        const TPtr = @TypeOf(value_ptr);
        const T = std.meta.Child(TPtr);
        // TODO: handle empty
        sw: switch (try parser.peekByte() orelse return error.invalid_json) {
            '0'...'9' => {
                const digit: T = try parser.consumeByte() - '0';
                value_ptr.* = value_ptr.* * 10 + digit;
                continue :sw try parser.peekByte() orelse return;
            },
            else => return,
            // TODO: fraction
            // TODO: exponent
            // TODO: handle good exit vs empty number
        }
    }

    fn parseBool(value_ptr: *bool, parser: *Parser) !void {
        var buf: [5]u8 = @splat(0);
        if (try parser.peekByte()) |byte|
            switch (byte) {
                't' => {
                    if (parser.slice.len >= 4) {
                        try parser.consumeBytesBufAssume(4, &buf);
                    } else {
                        return error.invalid_json;
                    }

                    if (std.mem.eql(u8, buf[0..4], "true")) {
                        value_ptr.* = true;
                        return;
                    } else {
                        return error.invalid_json;
                    }
                },
                'f' => {
                    if (parser.slice.len >= 5) {
                        try parser.consumeBytesBufAssume(5, &buf);
                    } else {
                        return error.invalid_json;
                    }

                    if (std.mem.eql(u8, buf[0..5], "false")) {
                        value_ptr.* = false;
                        return;
                    } else {
                        return error.invalid_json;
                    }
                },
                else => return error.invalid_json,
            }
        else
            return error.invalid_json;
    }

    fn parseStringBuf(buf: []u8, parser: *Parser) ![]u8 {
        var first_quote: bool = true;
        var string: []u8 = buf[0..0];
        sw: switch (try parser.consumeByte()) {
            // TODO: Handle >1 byte
            // 0x0020...0x10FFFF => |char| {
            0x20...0xFF => |char| {
                switch (char) {
                    '"' => if (first_quote) {
                        first_quote = false;
                        continue :sw try parser.consumeByte();
                    },
                    '\\' => {
                        switch (try parser.consumeByte()) {
                            inline '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => |escaped_char| {
                                string = try appendBuf(u8, buf, string.len, escapeChar(escaped_char));
                                continue :sw try parser.consumeByte();
                            },
                            'u' => {
                                // TODO: This should use std.unicode.utf8Encode instead?
                                var hex_buf: [4]u8 = undefined;
                                if (parser.slice.len >= 4) {
                                    try parser.consumeBytesBufAssume(4, &hex_buf);
                                } else {
                                    return error.invalid_json;
                                }
                                const hex = try hexChar(hex_buf);
                                if (hex[0] != 0x00) string = try appendBuf(u8, buf, string.len, hex[0]);
                                string = try appendBuf(u8, buf, string.len, hex[1]);
                                continue :sw try parser.consumeByte();
                            },
                            else => return error.invalid_json,
                        }
                    },
                    else => {
                        string = try appendBuf(u8, buf, string.len, char);
                        continue :sw try parser.consumeByte();
                    },
                }
            },
            else => return error.invalid_json,
        }
        return string;
    }

    fn hexChar(hex: [4]u8) ![2]u8 {
        return .{ try std.fmt.parseUnsigned(u8, hex[0..2], 16), try std.fmt.parseUnsigned(u8, hex[2..4], 16) };
    }

    fn escapeChar(comptime char: u8) u8 {
        return switch (char) {
            inline '"' => '"',
            inline '\\' => '\\',
            inline '/' => '/',
            inline 'b' => 0x08,
            inline 'f' => 0x0C,
            inline 'n' => '\n',
            inline 'r' => '\r',
            inline 't' => '\t',
            else => unreachable,
        };
    }

    fn appendBuf(comptime T: type, buf: []T, index: usize, value: T) ![]T {
        if (buf.len < index + 1) {
            return error.insufficient_buffer_size;
        }
        buf[index] = value;
        return buf[0 .. index + 1];
    }

    // TODO: parseStringAlloc
    // TODO: how to deal with anyerror? I'd like this to have a well-defined error list.

    fn parseOptional(value_ptr: anytype, parser: *Parser) anyerror!void {
        if (try parser.peekByte()) |byte|
            switch (byte) {
                'n' => {
                    if (try parser.checkSlice("null")) {
                        value_ptr.* = null;
                    } else {
                        return error.invalid_json;
                    }
                },
                else => {
                    const T = @typeInfo(@typeInfo(@TypeOf(value_ptr)).pointer.child).optional.child;
                    var value_not_null: T = undefined;
                    try parseValue(&value_not_null, parser);
                    value_ptr.* = value_not_null;
                },
            }
        else
            return error.invalid_json;
    }

    // TODO: parseIntoExisting - this one might not require all fields, but let's not do this until there's actually a need

    // parse functions should require value, there should be optional parse function that accepts nulls
    // so if struct is not optional, then the parser treats null as invalid_json
    // fn parseValueBool(
    //     parser: *Parser,
    // ) !bool {}

    pub fn parseFromSlice(value_ptr: anytype, slice: []const u8) !void {
        var stream = std.io.fixedBufferStream(slice);
        try parse(value_ptr, stream.reader().any());
    }
};

// Parsing to a target of slice requires the target
// to have sufficient length to fit the parsed items.
// When length is unknown use allocating parse function.
test "parse array -> []f32" {
    var buf: []f32 = try std.testing.allocator.alloc(f32, 5);
    defer std.testing.allocator.free(buf);
    buf[0..5].* = @splat(0);
    try json.parseFromSlice(
        &buf,
        \\ [1.23, 2.34, 3.45, 4.56]
        ,
    );
    try std.testing.expectEqualSlices(
        f32,
        &.{ 1.23, 2.34, 3.45, 4.56, 0 },
        buf,
    );
}

test "parse array -> [_:0]f32" {
    var buf: [100:0]f32 = @splat(1);
    try json.parseFromSlice(
        &buf,
        \\ [1.23, 2.34, 3.45, 4.56]
        ,
    );
    try std.testing.expectEqualSlices(
        f32,
        &.{ 1.23, 2.34, 3.45, 4.56 },
        buf[0..std.mem.indexOfSentinel(f32, 0, &buf)],
    );
}

test "parse array -> [_]f32" {
    var buf: [100]f32 = @splat(0);
    try json.parseFromSlice(
        &buf,
        \\ [1.23, 2.34, 3.45, 4.56]
        ,
    );
    try std.testing.expectEqualSlices(f32, &.{ 1.23, 2.34, 3.45, 4.56 }, buf[0..4]);
}

test "parse object -> struct" {
    const Foo = struct { bar: bool, baz: f32, fizz: u32 };
    var foo = std.mem.zeroInit(Foo, .{});
    try json.parseFromSlice(
        &foo,
        \\ {"bar":true,"baz":1.23,"fizz":456}
        ,
    );
    try std.testing.expectEqual(Foo{ .bar = true, .baz = 1.23, .fizz = 456 }, foo);
}

test "parse object nested" {
    const Bar = struct { burbur: bool };
    const Foo = struct { bar: Bar, baz: f32, fizz: u32 };
    var foo = std.mem.zeroInit(Foo, .{});
    try json.parseFromSlice(
        &foo,
        \\ {"bar":{"burbur":false},"baz":1.23,"fizz":456}
        ,
    );
    try std.testing.expectEqual(Foo{ .bar = .{ .burbur = false }, .baz = 1.23, .fizz = 456 }, foo);
}

test "parse object string member" {
    {
        // Array
        const Foo = struct { bar: [100]u8, baz: bool };
        var foo = std.mem.zeroInit(Foo, .{});
        try json.parseFromSlice(
            &foo,
            \\ {"bar":"hello, world!","baz":true}
            ,
        );
        try std.testing.expectEqualSlices(
            u8,
            "hello, world!",
            foo.bar[0..13],
        );
    }
}

test "parse numbers" {
    try testParseFromSlice(u32, 123, "123");
    try testParseFromSlice(i32, 123, "123");
    try testParseFromSlice(i32, -123, "-123");
    try testParseFromSlice(f32, 123.456, "123.456");
    try testParseFromSlice(f32, -123.456, "-123.456");
}

test "parse string -> [_]u8" {
    // TODO: Fix multi-byte unicode

    try testParseFromSlice([11]u8, "hello world".*, "\n\"hello \\u0077\\u006f\\u0072\\u006c\\u0064\"");
    try testParseFromSlice([15]u8, "hello\nworld\x00\x00\x00\x00".*, "\n\"hello\\n\\u0077\\u006f\\u0072\\u006c\\u0064\"");
}

test "parse string -> [_:0]u8" {
    // TODO: Fix multi-byte unicode

    try testParseFromSlice([11:0]u8, "hello world".*, "\n\"hello \\u0077\\u006f\\u0072\\u006c\\u0064\"");
    try testParseFromSlice([15:0]u8, "hello\nworld\x00\x00\x00\x00".*, "\n\"hello\\n\\u0077\\u006f\\u0072\\u006c\\u0064\"");
}

test "parse bool" {
    try testParseFromSlice(bool, true, "true");
    try testParseFromSlice(bool, false, "false");

    try testParseFromSlice(?bool, null, "null");
    try testParseFromSlice(?bool, true, "true");
    try testParseFromSlice(?bool, false, "false");

    try testParseFromSliceError(bool, error.invalid_json, "tru");
    try testParseFromSliceError(bool, error.invalid_json, "fals");
    try testParseFromSliceError(bool, error.invalid_json, "null");
}

test "stringify struct" {
    const Bar = struct {
        bar: i32,
        barbar: []const u8,
    };
    const Foo = struct {
        bars: []const Bar,
        foo: f32,
        foofoo: []const u8,
    };
    try testStringify(
        "{\"bars\":[{\"bar\":123,\"barbar\":\"first\"},{\"bar\":234,\"barbar\":\"second\"}],\"foo\":345.678,\"foofoo\":\"Hello\"}",
        Foo{
            .bars = &.{
                .{ .bar = 123, .barbar = "first" },
                .{ .bar = 234, .barbar = "second" },
            },
            .foo = 345.678,
            .foofoo = "Hello",
        },
    );
}

test "stringify basic types" {
    try testStringify("false", false);
    try testStringify("true", true);
    try testStringify("null", null);
    try testStringify("null", @as(?u8, null));
    try testStringify("null", @as(?*u32, null));
    try testStringify("42", 42);
    try testStringify("42", 42.0);
    try testStringify("42", @as(u8, 42));
    try testStringify("42", @as(u128, 42));
    try testStringify("-2147483648", @as(i32, -2147483648));
    try testStringify("0", @as(i32, 0));
    try testStringify("9999999999999999", 9999999999999999);
    try testStringify("42.123", @as(f32, 42.123));
    try testStringify("42", @as(f64, 42));
}

test "stringify string" {
    try testStringify("\"hello\"", "hello");
    try testStringify("\"hello\"", @as([*:0]const u8, "hello"));
}

test "stringify enum" {
    const Foo = enum { foo, bar };
    try testStringify("\"foo\"", Foo.foo);
    try testStringify("\"bar\"", Foo.bar);

    const Bar = enum(u8) { foo = 0, _ };
    try testStringify("\"foo\"", Bar.foo);
    try testStringify("1", @as(Bar, @enumFromInt(1)));

    try testStringify("\"foo\"", .foo);
    try testStringify("\"bar\"", .bar);
}

test "stringify tagged union" {
    const T = union(enum) {
        nothing,
        foo: u32,
        bar: bool,
    };
    try testStringify("{\"nothing\":{}}", T{ .nothing = {} });
    try testStringify("{\"foo\":42}", T{ .foo = 42 });
    try testStringify("{\"bar\":true}", T{ .bar = true });
}

test "stringify array" {
    const Foo = struct { foo: u32 };
    try testStringify("[{\"foo\":42},{\"foo\":100},{\"foo\":1000}]", [_]Foo{
        Foo{ .foo = 42 },
        Foo{ .foo = 100 },
        Foo{ .foo = 1000 },
    });
}

test "stringify tuple" {
    try testStringify("[\"foo\",42]", std.meta.Tuple(&.{ []const u8, usize }){ "foo", 42 });
}

test "stringify std.ArrayList and std.ArrayListUnmanaged" {
    {
        var list: std.ArrayListUnmanaged(u32) = .{};
        defer list.deinit(std.testing.allocator);
        try list.append(std.testing.allocator, 1);
        try list.append(std.testing.allocator, 2);
        try list.append(std.testing.allocator, 3);
        try testStringify("[1,2,3]", list);
    }
    {
        var list = std.ArrayList(u32).init(std.testing.allocator);
        defer list.deinit();
        try list.append(1);
        try list.append(2);
        try list.append(3);
        try testStringify("[1,2,3]", list);
    }
}

test "stringify hash maps" {
    {
        // u32 -> bool
        var hashmap: std.AutoHashMapUnmanaged(u32, bool) = .{};
        defer hashmap.deinit(std.testing.allocator);
        try hashmap.put(std.testing.allocator, 123, true);
        try hashmap.put(std.testing.allocator, 456, false);
        try testStringify("{\"123\":true,\"456\":false}", hashmap);
    }
    {
        // bool -> u32
        var hashmap: std.AutoHashMapUnmanaged(bool, u32) = .{};
        defer hashmap.deinit(std.testing.allocator);
        try hashmap.put(std.testing.allocator, true, 123);
        try hashmap.put(std.testing.allocator, false, 456);
        try testStringify("{\"true\":123,\"false\":456}", hashmap);
    }
    {
        // u32 -> ArrayList(struct)
        const Foo = struct { foo: []const u8, bar: f32 };
        var hashmap: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(Foo)) = .{};
        defer hashmap.deinit(std.testing.allocator);
        try hashmap.put(std.testing.allocator, 1, .{});
        defer hashmap.getPtr(1).?.deinit(std.testing.allocator);
        try hashmap.getPtr(1).?.append(std.testing.allocator, .{ .foo = "hello", .bar = 123 });
        try hashmap.getPtr(1).?.append(std.testing.allocator, .{ .foo = "world", .bar = 456 });
        try hashmap.put(std.testing.allocator, 2, .{});
        defer hashmap.getPtr(2).?.deinit(std.testing.allocator);
        try hashmap.getPtr(2).?.append(std.testing.allocator, .{ .foo = "bye", .bar = 789 });
        try hashmap.getPtr(2).?.append(std.testing.allocator, .{ .foo = "world", .bar = 0.1 });
        try testStringify("{\"1\":[{\"foo\":\"hello\",\"bar\":123},{\"foo\":\"world\",\"bar\":456}],\"2\":[{\"foo\":\"bye\",\"bar\":789},{\"foo\":\"world\",\"bar\":0.1}]}", hashmap);
    }
    {
        // string -> string
        var hashmap: std.StringHashMapUnmanaged([]const u8) = .{};
        defer hashmap.deinit(std.testing.allocator);
        try hashmap.put(std.testing.allocator, "hello", "world");
        try hashmap.put(std.testing.allocator, "bye", "world");
        try testStringify("{\"hello\":\"world\",\"bye\":\"world\"}", hashmap);
    }
    {
        // struct.toString() -> bool
        const Foo = struct {
            foo: [10]u8,
            bar: [10]u8,
            pub fn toString(self: @This()) [20]u8 {
                var buf: [20]u8 = .{0} ** 20;
                buf[0..10].* = self.foo;
                buf[10..20].* = self.bar;
                return buf;
            }
        };
        var hashmap: std.AutoHashMapUnmanaged(Foo, bool) = .{};
        defer hashmap.deinit(std.testing.allocator);
        try hashmap.put(std.testing.allocator, .{ .foo = "1234567890".*, .bar = "abcdefghij".* }, true);
        try hashmap.put(std.testing.allocator, .{ .foo = "abcdefghij".*, .bar = "1234567890".* }, false);
        try testStringify("{\"1234567890abcdefghij\":true,\"abcdefghij1234567890\":false}", hashmap);
    }
    {
        // empty
        var hashmap: std.AutoHashMapUnmanaged(u32, u32) = .{};
        defer hashmap.deinit(std.testing.allocator);
        try testStringify("{}", hashmap);
    }
}

fn testStringify(expected: []const u8, value: anytype) !void {
    const actual = try json.stringifyAlloc(std.testing.allocator, value);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn testParseFromSlice(comptime T: type, expected: T, slice: []const u8) !void {
    var actual = std.mem.zeroes(T);
    try json.parseFromSlice(&actual, slice);
    try std.testing.expectEqual(expected, actual);
}

fn testParseFromSliceError(comptime T: type, err: anytype, slice: []const u8) !void {
    // var actual: T = if (std.meta.activeTag(@typeInfo(T)) == .@"struct") std.mem.zeroInit(T, .{}) else std.mem.zeroes(T);
    var actual = std.mem.zeroes(T);
    try std.testing.expectError(err, json.parseFromSlice(&actual, slice));
}
