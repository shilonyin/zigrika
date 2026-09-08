const IntMap = @import("int_map.zig").IntMap;

RoleId: i32,
FightBuffs: []const i64,
AdditionalFightBuffs: ?[]const i64 = null,
CustomConcomitantIds: []const i32,
ConcomitantBuffs: IntMap(i32, []const i64)
