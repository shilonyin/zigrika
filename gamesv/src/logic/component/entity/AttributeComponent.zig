const Component = @This();
const pb = @import("proto").pb;
const mem = @import("../../../mem.zig");
const std = @import("std");

const ATTR_COUNT: usize = @intCast(@intFromEnum(pb.EAttributeType.MAX));

pub const Attribute = struct {
    base: i32,
    increment: i32,
    current: i32,

    pub const zero: Attribute = .{
        .base = 0,
        .increment = 0,
        .current = 0,
    };
};
attributes: [ATTR_COUNT]Attribute = @splat(.zero),
hardness_mode_id: i32 = 0,
rage_mode_id: i32 = 0,

pub fn toProto(comp: Component, alloc: mem.Alloc) !pb.AttributeComponentPb {
    var comp_pb: pb.AttributeComponentPb = .{
        .HardnessModeId = comp.hardness_mode_id,
        .RageModeId = comp.rage_mode_id,
    };

    inline for (@typeInfo(pb.EAttributeType).@"enum".fields[0..ATTR_COUNT]) |field| {
        try comp_pb.AttrData.append(alloc.arena, .{
            .AttributeType = @field(pb.EAttributeType, field.name),
            .CurrentValue = comp.attributes[field.value].base,
            .CurrentValue2 = comp.attributes[field.value].base,
            .ValueIncrement = comp.attributes[field.value].increment,
        });
    }

    return comp_pb;
}

pub fn create(base_prop: []const i32) !Component {
    return createWithModes(base_prop, 0, 0);
}

pub fn createWithModes(base_prop: []const i32, hardness_mode_id: i32, rage_mode_id: i32) !Component {
    var comp: Component = .{
        .hardness_mode_id = hardness_mode_id,
        .rage_mode_id = rage_mode_id,
    };
    for (base_prop, &comp.attributes) |prop, *attribute| {
        attribute.* = .{
            .base = prop,
            .increment = 0,
            .current = prop,
        };
    }
    return comp;
}

pub fn createWithIncrements(base_prop: []const i32, increments: []const i32) !Component {
    var comp: Component = .{};
    for (
        base_prop,
        &comp.attributes,
        increments,
    ) |prop, *attribute, increment| {
        attribute.* = .{
            .base = prop,
            .increment = increment,
            .current = prop + increment,
        };
    }
    return comp;
}
