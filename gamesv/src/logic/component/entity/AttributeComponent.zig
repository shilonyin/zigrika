const Component = @This();
const pb = @import("proto").pb;
const mem = @import("../../../mem.zig");
const std = @import("std");

const ATTR_COUNT = @as(usize, @intCast(@intFromEnum(pb.EAttributeType.MAX)));

pub const Attribute = struct {
    base: i32,
    increment: i32,
    current: i32,
};
attributes: [ATTR_COUNT]Attribute = @splat(.{ .base = 0, .increment = 0, .current = 0 }),
hardness_mode_id: i32 = 0,
rage_mode_id: i32 = 0,

pub fn toProto(comp: Component, alloc: mem.Alloc) !pb.AttributeComponentPb {
    var comp_pb: pb.AttributeComponentPb = .{
        .HardnessModeId = comp.hardness_mode_id,
        .RageModeId = comp.rage_mode_id,
    };

    inline for (comptime std.meta.fields(pb.EAttributeType), 0..) |field, i| {
        try comp_pb.AttrData.append(alloc.arena, .{
            .AttributeType = @field(pb.EAttributeType, field.name),
            .CurrentValue = if (i < comp.attributes.len) comp.attributes[i].base else 0,
            .CurrentValue2 = if (i < comp.attributes.len) comp.attributes[i].base else 0,
            .ValueIncrement = if (i < comp.attributes.len) comp.attributes[i].increment else 0,
        });
    }

    return comp_pb;
}

pub fn create(base_prop: []const i32) !Component {
    return createWithModes(base_prop, 0, 0);
}

pub fn createWithModes(base_prop: []const i32, hardness_mode_id: i32, rage_mode_id: i32) !Component {
    var comp = Component{
        .hardness_mode_id = hardness_mode_id,
        .rage_mode_id = rage_mode_id,
    };
    for (base_prop, 0..) |prop, i| {
        if (i >= ATTR_COUNT) break;
        comp.attributes[i] = .{
            .base = prop,
            .increment = 0,
            .current = prop,
        };
    }
    return comp;
}

pub fn createWithIncrements(base_prop: []const i32, increments: []const i32) !Component {
    var comp = Component{};
    for (base_prop, 0..) |prop, i| {
        if (i >= ATTR_COUNT) break;
        const increment = if (i < increments.len) increments[i] else 0;
        comp.attributes[i] = .{
            .base = prop,
            .increment = increment,
            .current = prop + increment,
        };
    }
    return comp;
}
