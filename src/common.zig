const std = @import("std");

pub const MessageHeader = struct {
    fin: bool = true,
    rsv1: bool = false,
    rsv2: bool = false,
    rsv3: bool = false,
    opcode: Opcode,
    length: u64,
    mask: ?[4]u8 = null,
};

pub const Opcode = enum(u4) {
    continuation = 0x00,
    text = 0x01,
    binary = 0x02,
    close = 0x08,
    ping = 0x09,
    pong = 0x0a,
    _,
};

pub const ParserState = enum {
    header,
    chunk,
};

/// Compares two of any type for equality. Containers are compared on a field-by-field basis,
/// where possible. Pointers are not followed. Slices are compared by contents.
pub fn reworkedMetaEql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);

    switch (@typeInfo(T)) {
        .Struct => |info| {
            inline for (info.fields) |field_info| {
                if (!reworkedMetaEql(@field(a, field_info.name), @field(b, field_info.name))) return false;
            }
            return true;
        },
        .ErrorUnion => {
            if (a) |a_p| {
                if (b) |b_p| return reworkedMetaEql(a_p, b_p) else |_| return false;
            } else |a_e| {
                if (b) |_| return false else |b_e| return a_e == b_e;
            }
        },
        .Union => |info| {
            if (info.tag_type) |Tag| {
                const tag_a = std.meta.activeTag(a);
                const tag_b = std.meta.activeTag(b);
                if (tag_a != tag_b) return false;

                inline for (info.fields) |field_info| {
                    if (@field(Tag, field_info.name) == tag_a) {
                        return reworkedMetaEql(@field(a, field_info.name), @field(b, field_info.name));
                    }
                }
                return false;
            }

            @compileError("cannot compare untagged union type " ++ @typeName(T));
        },
        .Array => {
            if (a.len != b.len) return false;
            for (&a, &b) |e1, e2|
                if (!reworkedMetaEql(e1, e2)) return false;
            return true;
        },
        .Vector => {
            for (&a, &b) |e1, e2|
                if (!reworkedMetaEql(e1, e2)) return false;
            return true;
        },
        .Pointer => |info| {
            return switch (info.size) {
                .One, .Many, .C => a == b,
                .Slice => std.mem.eql(info.child, a, b),
            };
        },
        .Optional => {
            if (a == null and b == null) return true;
            if (a == null or b == null) return false;
            return reworkedMetaEql(a.?, b.?);
        },
        else => return a == b,
    }
}
