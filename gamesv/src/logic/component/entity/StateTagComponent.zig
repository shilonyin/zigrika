const Component = @This();
const pb = @import("proto").pb;
const mem = @import("../../../mem.zig");

state_tag_id: i32 = 0,

pub fn toProto(comp: Component) !pb.StateTagComponentPb {
    return .{ .StateTagId = comp.state_tag_id };
}
