const std = @import("std");
const pb = @import("proto").pb;
const EventQueue = @import("../EventQueue.zig");
const Connection = @import("../../network/Connection.zig");
const mem = @import("../../mem.zig");

pub fn runEnterGamePhase(
    _: EventQueue.Dequeue(.enter_game),
    events: *EventQueue,
) !void {
    // events will be consumed sequentially, extend as needed
    try events.enqueue(.push_data, .{});
    try events.enqueue(.push_data_complete, .{});
    try events.enqueue(.initial_scene_join, .{});
}

pub fn notifyPushDataComplete(
    _: EventQueue.Dequeue(.push_data_complete),
    conn: *Connection,
    alloc: mem.Alloc,
    io: std.Io,
) !void {
    try conn.push(alloc.gpa, io, pb.PushContextIdNotify{ .Id = 0 });
    try conn.push(alloc.gpa, io, pb.PushDataCompleteNotify{});
}
