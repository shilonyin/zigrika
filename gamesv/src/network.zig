const std = @import("std");
const common = @import("common");
const Assets = @import("data/Assets.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const FileSystem = common.FileSystem;
const SessionSupervisor = @import("network/SessionSupervisor.zig");
const KcpTransport = @import("network/KcpTransport.zig");

const udp_receive_capacity: usize = 1500;
const udp_packet_queue_capacity: usize = 256;
const krkcp_syn: u8 = 0xED;
const krkcp_ack: u8 = 0xEE;
const kcp_overhead = KcpTransport.overhead;

pub const OwnedMessage = struct {
    bytes: []u8,
};
pub const OwnedFrame = struct {
    bytes: []u8,
};

const IncomingPacket = struct {
    buffer: [udp_receive_capacity]u8,
    len: u16,
    from: Io.net.IpAddress,

    fn data(packet: *const IncomingPacket) []const u8 {
        return packet.buffer[0..packet.len];
    }
};

pub const CloseReason = enum(u8) {
    active,
    replaced,
    gameplay_exit,
    invalid_kcp_packet,
    transport_error,
    kcp_dead_link,
    send_failed,
    pre_auth_timeout,
    idle_timeout,
    shutdown,
};

pub fn bind(io: Io, gpa: Allocator, fs: *FileSystem, assets: *const Assets, address: Io.net.IpAddress) !Io.Future(void) {
    const log = std.log.scoped(.net_bind);

    const socket = address.bind(io, .{ .mode = .dgram }) catch |err| {
        log.err("failed to bind at {f}: {t}", .{ address, err });
        if (err == error.AddressInUse) log.err("another instance of this server might be already running", .{});
        return err;
    };

    const recv_args = .{ io, gpa, fs, assets, socket };
    return io.concurrent(receiveLoop, recv_args) catch io.async(receiveLoop, recv_args);
}

pub const ConnectionHandle = struct {
    conv_id: u32,
    socket: *const Io.net.Socket,
    address: Io.net.IpAddress,
    inbound_buf: [128]OwnedMessage,
    inbound: Io.Queue(OwnedMessage),
    outbound_buf: [512]OwnedFrame,
    outbound: Io.Queue(OwnedFrame),
    closed_event: Io.Event,
    transport_work: *Io.Event,
    gameplay_completions: *Io.Queue(*ConnectionHandle),
    gameplay_future: Io.Future(*ConnectionHandle),
    close_reason: std.atomic.Value(CloseReason),
    authenticated: std.atomic.Value(bool),

    pub fn init(
        handle: *ConnectionHandle,
        socket: *const Io.net.Socket,
        address: Io.net.IpAddress,
        conv_id: u32,
        transport_work: *Io.Event,
        gameplay_completions: *Io.Queue(*ConnectionHandle),
    ) void {
        handle.socket = socket;
        handle.address = address;
        handle.conv_id = conv_id;
        handle.inbound = Io.Queue(OwnedMessage).init(handle.inbound_buf[0..]);
        handle.outbound = Io.Queue(OwnedFrame).init(handle.outbound_buf[0..]);
        handle.closed_event = .unset;
        handle.transport_work = transport_work;
        handle.gameplay_completions = gameplay_completions;
        handle.gameplay_future = undefined;
        handle.close_reason = .init(.active);
        handle.authenticated = .init(false);
    }

    pub fn close(handle: *ConnectionHandle, io: Io, reason: CloseReason) void {
        _ = handle.close_reason.cmpxchgStrong(.active, reason, .acq_rel, .acquire);
        handle.closed_event.set(io);
        handle.inbound.close(io);
        handle.outbound.close(io);
        handle.signalTransportWork(io);
    }

    pub fn closeReason(handle: *const ConnectionHandle) CloseReason {
        return handle.close_reason.load(.acquire);
    }

    pub fn markAuthenticated(handle: *ConnectionHandle, io: Io) void {
        handle.authenticated.store(true, .release);
        handle.signalTransportWork(io);
    }

    pub fn isAuthenticated(handle: *const ConnectionHandle) bool {
        return handle.authenticated.load(.acquire);
    }

    pub fn signalTransportWork(handle: *ConnectionHandle, io: Io) void {
        handle.transport_work.set(io);
    }
};

pub const SessionManager = struct {
    mutex: Io.Mutex = .init,
    sessions: std.AutoHashMapUnmanaged(i32, *ConnectionHandle) = .empty,

    const replacement_timeout_ms = 5_000;
    const replacement_poll_ms = 10;

    pub fn deinit(manager: *SessionManager, gpa: Allocator) void {
        manager.sessions.deinit(gpa);
    }

    pub fn acquire(
        manager: *SessionManager,
        io: Io,
        gpa: Allocator,
        handle: *ConnectionHandle,
        player_id: i32,
    ) !void {
        const clock: Io.Clock = .awake;
        const deadline_ms = clock.now(io).toMilliseconds() + replacement_timeout_ms;
        var replacement_requested: ?*ConnectionHandle = null;

        while (true) {
            try manager.mutex.lock(io);
            {
                defer manager.mutex.unlock(io);

                if (manager.sessions.get(player_id)) |existing| {
                    if (existing == handle) return;

                    if (replacement_requested != existing) {
                        existing.close(io, .replaced);
                        replacement_requested = existing;
                    }
                } else {
                    try manager.sessions.put(gpa, player_id, handle);
                    return;
                }
            }

            if (clock.now(io).toMilliseconds() >= deadline_ms) {
                return error.SessionReplacementTimedOut;
            }
            try io.sleep(.fromMilliseconds(replacement_poll_ms), .awake);
        }
    }

    pub fn release(manager: *SessionManager, io: Io, handle: *ConnectionHandle, player_id: i32) void {
        manager.mutex.lockUncancelable(io);
        defer manager.mutex.unlock(io);

        if (manager.sessions.get(player_id) == handle) {
            _ = manager.sessions.remove(player_id);
        }
    }
};

const Wake = struct {
    packet: ?IncomingPacket = null,
    receiver_closed: bool = false,
    gameplay_done: ?*ConnectionHandle = null,
    transport_ready: bool = false,
};

const SelectResult = union(enum) {
    packet: (Io.QueueClosedError || Io.Cancelable)!IncomingPacket,
    gameplay_done: (Io.QueueClosedError || Io.Cancelable)!*ConnectionHandle,
    transport_ready: Io.Cancelable!void,
};

fn waitForTransportWork(event: *Io.Event, io: Io, deadline_delay_ms: ?i64) Io.Cancelable!void {
    if (deadline_delay_ms) |delay_ms| {
        event.waitTimeout(io, .{ .duration = .{
            .clock = .awake,
            .raw = .fromMilliseconds(@max(delay_ms, 0)),
        } }) catch |err| switch (err) {
            error.Timeout => return,
            error.Canceled => |e| return e,
        };
        return;
    }
    try event.wait(io);
}

fn applySelectResult(wake: *Wake, result: SelectResult) void {
    switch (result) {
        .packet => |packet_result| {
            wake.packet = packet_result catch |err| switch (err) {
                error.Canceled => return,
                error.Closed => {
                    wake.receiver_closed = true;
                    return;
                },
            };
        },
        .gameplay_done => |done| wake.gameplay_done = done catch |err| switch (err) {
            error.Canceled, error.Closed => return,
        },
        .transport_ready => |work| {
            work catch |err| switch (err) {
                error.Canceled => return,
            };
            wake.transport_ready = true;
        },
    }
}

fn waitForWake(
    io: Io,
    incoming_packets: *Io.Queue(IncomingPacket),
    transport_work: *Io.Event,
    gameplay_completions: *Io.Queue(*ConnectionHandle),
    deadline_delay_ms: ?i64,
) (Io.ConcurrentError || Io.Cancelable)!Wake {
    var results: [3]SelectResult = undefined;
    var select: Io.Select(SelectResult) = .init(io, &results);
    errdefer select.cancelDiscard();

    try select.concurrent(.packet, Io.Queue(IncomingPacket).getOne, .{ incoming_packets, io });
    try select.concurrent(.gameplay_done, Io.Queue(*ConnectionHandle).getOne, .{ gameplay_completions, io });
    try select.concurrent(.transport_ready, waitForTransportWork, .{ transport_work, io, deadline_delay_ms });

    const first = try select.await();

    var wake: Wake = .{};
    applySelectResult(&wake, first);
    while (select.cancel()) |extra| applySelectResult(&wake, extra);
    return wake;
}

fn receivePackets(
    io: Io,
    socket: *const Io.net.Socket,
    incoming_packets: *Io.Queue(IncomingPacket),
) void {
    const log = std.log.scoped(.net_recv);
    defer incoming_packets.close(io);

    while (true) {
        var packet: IncomingPacket = undefined;
        const message = socket.receive(io, &packet.buffer) catch |err| switch (err) {
            error.Canceled => return,
            error.PortUnreachable => {
                log.debug("discarding ICMP port unreachable report", .{});
                continue;
            },
            else => {
                log.err("UDP receive failed: {t}", .{err});
                return;
            },
        };
        if (message.flags.trunc) {
            log.warn("discarding truncated UDP datagram from {f}", .{message.from});
            continue;
        }

        packet.len = @intCast(message.data.len);
        packet.from = message.from;
        incoming_packets.putOne(io, packet) catch |err| switch (err) {
            error.Canceled, error.Closed => return,
        };
    }
}

fn startSession(
    io: Io,
    gpa: Allocator,
    fs: *FileSystem,
    assets: *const Assets,
    socket: *const Io.net.Socket,
    from: Io.net.IpAddress,
    transport_work: *Io.Event,
    gameplay_completions: *Io.Queue(*ConnectionHandle),
    session_manager: *SessionManager,
    registry: *KcpTransport.Registry,
    now_ms: i64,
) !*ConnectionHandle {
    const handle = try gpa.create(ConnectionHandle);
    errdefer gpa.destroy(handle);

    const conv_id = try registry.allocateConvId();
    handle.init(socket, from, conv_id, transport_work, gameplay_completions);
    try registry.create(io, handle, now_ms);
    errdefer {
        handle.close(io, .transport_error);
        registry.finalize(io, handle, now_ms);
    }

    const args = .{ io, handle, session_manager, gpa, fs, assets };
    handle.gameplay_future = io.concurrent(SessionSupervisor.run, args) catch
        io.async(SessionSupervisor.run, args);
    return handle;
}

fn receiveLoop(io: Io, gpa: Allocator, fs: *FileSystem, assets: *const Assets, socket: Io.net.Socket) void {
    const log = std.log.scoped(.net_recv);
    defer socket.close(io);

    var session_manager: SessionManager = .{};
    defer session_manager.deinit(gpa);

    var registry = KcpTransport.Registry.init(gpa);
    defer registry.deinit();

    var transport_work: Io.Event = .unset;
    var completion_buffer: [128]*ConnectionHandle = undefined;
    var gameplay_completions = Io.Queue(*ConnectionHandle).init(&completion_buffer);
    const packet_buffer = gpa.alloc(IncomingPacket, udp_packet_queue_capacity) catch |err| {
        log.err("failed to allocate UDP packet queue: {t}", .{err});
        return;
    };
    defer gpa.free(packet_buffer);
    var incoming_packets = Io.Queue(IncomingPacket).init(packet_buffer);
    var receiver = io.concurrent(receivePackets, .{ io, &socket, &incoming_packets }) catch
        io.async(receivePackets, .{ io, &socket, &incoming_packets });
    defer {
        incoming_packets.close(io);
        receiver.cancel(io);
    }

    while (true) {
        transport_work.reset();
        const before_wait_ms = Io.Clock.awake.now(io).toMilliseconds();
        if (registry.drainReady(io, before_wait_ms)) continue;

        const wake = waitForWake(
            io,
            &incoming_packets,
            &transport_work,
            &gameplay_completions,
            registry.nextWakeDelayMs(before_wait_ms),
        ) catch |err| {
            log.err("failed to wait for transport work: {t}", .{err});
            break;
        };

        const now_ms = Io.Clock.awake.now(io).toMilliseconds();
        if (wake.receiver_closed) break;
        if (wake.packet) |packet| {
            const data = packet.data();
            if (data.len == 35 and data[0] == krkcp_syn) {
                if (startSession(
                    io,
                    gpa,
                    fs,
                    assets,
                    &socket,
                    packet.from,
                    &transport_work,
                    &gameplay_completions,
                    &session_manager,
                    &registry,
                    now_ms,
                )) |handle| {
                    var ack: [5]u8 = undefined;
                    ack[0] = krkcp_ack;
                    std.mem.writeInt(u32, ack[1..5], handle.conv_id, .little);
                    socket.send(io, &packet.from, ack[0..]) catch {};
                } else |err| {
                    log.err("failed to initialize session: {t}", .{err});
                }
            } else if (data.len >= kcp_overhead) {
                const conv_id = std.mem.readInt(u32, data[0..4], .little);
                _ = registry.input(io, conv_id, &packet.from, data, now_ms);
            }
        }

        if (wake.gameplay_done) |handle| {
            _ = handle.gameplay_future.await(io);
            registry.finalize(io, handle, now_ms);
            gpa.destroy(handle);
        }

        if (registry.drainReady(io, now_ms)) transport_work.set(io);
    }

    const previous_cancel_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous_cancel_protection);

    registry.closeAll(io, .shutdown);
    while (registry.sessionCount() != 0) {
        const handle = gameplay_completions.getOneUncancelable(io) catch |err| switch (err) {
            error.Closed => break,
        };
        _ = handle.gameplay_future.await(io);
        registry.finalize(io, handle, Io.Clock.awake.now(io).toMilliseconds());
        gpa.destroy(handle);
    }
}

test "central wake preserves simultaneous completions" {
    const from = try Io.net.IpAddress.parseLiteral("127.0.0.1:7777");
    const packet: IncomingPacket = .{
        .buffer = [_]u8{1} ++ [_]u8{0} ** (udp_receive_capacity - 1),
        .len = 1,
        .from = from,
    };
    var handle: ConnectionHandle = undefined;
    var wake: Wake = .{};

    applySelectResult(&wake, .{ .packet = packet });
    applySelectResult(&wake, .{ .gameplay_done = &handle });
    applySelectResult(&wake, .{ .transport_ready = {} });

    try std.testing.expect(wake.packet != null);
    try std.testing.expect(!wake.receiver_closed);
    try std.testing.expect(wake.gameplay_done == &handle);
    try std.testing.expect(wake.transport_ready);
}

test "canceled central waits do not become wake reasons" {
    var wake: Wake = .{};
    applySelectResult(&wake, .{ .packet = error.Canceled });
    applySelectResult(&wake, .{ .gameplay_done = error.Canceled });
    applySelectResult(&wake, .{ .transport_ready = error.Canceled });

    try std.testing.expect(wake.packet == null);
    try std.testing.expect(!wake.receiver_closed);
    try std.testing.expect(wake.gameplay_done == null);
    try std.testing.expect(!wake.transport_ready);
}

test "closed packet queue becomes a terminal wake reason" {
    var wake: Wake = .{};
    applySelectResult(&wake, .{ .packet = error.Closed });

    try std.testing.expect(wake.packet == null);
    try std.testing.expect(wake.receiver_closed);
}

test "packet queue owns an inline copy" {
    var storage: [1]IncomingPacket = undefined;
    var queue = Io.Queue(IncomingPacket).init(&storage);
    const from = try Io.net.IpAddress.parseLiteral("127.0.0.1:7777");
    var packet: IncomingPacket = .{
        .buffer = [_]u8{0} ** udp_receive_capacity,
        .len = 3,
        .from = from,
    };
    @memcpy(packet.buffer[0..3], "kcp");

    try queue.putOne(std.testing.io, packet);
    @memset(packet.buffer[0..3], 0);

    const queued = try queue.getOne(std.testing.io);
    try std.testing.expectEqualStrings("kcp", queued.data());
    try std.testing.expect(queued.from.eql(&from));
}

test "full packet queue applies backpressure until space is available" {
    var storage: [1]IncomingPacket = undefined;
    var queue = Io.Queue(IncomingPacket).init(&storage);
    const from = try Io.net.IpAddress.parseLiteral("127.0.0.1:7777");
    const first: IncomingPacket = .{
        .buffer = [_]u8{1} ++ [_]u8{0} ** (udp_receive_capacity - 1),
        .len = 1,
        .from = from,
    };
    const second: IncomingPacket = .{
        .buffer = [_]u8{2} ++ [_]u8{0} ** (udp_receive_capacity - 1),
        .len = 1,
        .from = from,
    };
    try queue.putOne(std.testing.io, first);

    const Producer = struct {
        fn run(packet_queue: *Io.Queue(IncomingPacket), packet: IncomingPacket, started: *Io.Event) !void {
            started.set(std.testing.io);
            try packet_queue.putOne(std.testing.io, packet);
        }
    };
    var started: Io.Event = .unset;
    var producer = std.testing.io.concurrent(Producer.run, .{ &queue, second, &started }) catch
        std.testing.io.async(Producer.run, .{ &queue, second, &started });
    try started.wait(std.testing.io);

    const queued_first = try queue.getOne(std.testing.io);
    try std.testing.expectEqual(@as(u8, 1), queued_first.data()[0]);
    try producer.await(std.testing.io);
    const queued_second = try queue.getOne(std.testing.io);
    try std.testing.expectEqual(@as(u8, 2), queued_second.data()[0]);
}

test "closing a full packet queue wakes its producer" {
    var storage: [1]IncomingPacket = undefined;
    var queue = Io.Queue(IncomingPacket).init(&storage);
    const from = try Io.net.IpAddress.parseLiteral("127.0.0.1:7777");
    const packet: IncomingPacket = .{
        .buffer = [_]u8{1} ++ [_]u8{0} ** (udp_receive_capacity - 1),
        .len = 1,
        .from = from,
    };
    try queue.putOne(std.testing.io, packet);

    const Producer = struct {
        fn run(packet_queue: *Io.Queue(IncomingPacket), value: IncomingPacket, started: *Io.Event) !void {
            started.set(std.testing.io);
            try packet_queue.putOne(std.testing.io, value);
        }
    };
    var started: Io.Event = .unset;
    var producer = std.testing.io.concurrent(Producer.run, .{ &queue, packet, &started }) catch
        std.testing.io.async(Producer.run, .{ &queue, packet, &started });
    try started.wait(std.testing.io);

    queue.close(std.testing.io);
    try std.testing.expectError(error.Closed, producer.await(std.testing.io));
    _ = try queue.getOne(std.testing.io);
    try std.testing.expectError(error.Closed, queue.getOne(std.testing.io));
}

test "transport work waits for either an event or its deadline" {
    var event: Io.Event = .unset;

    event.set(std.testing.io);
    try waitForTransportWork(&event, std.testing.io, null);

    event.reset();
    try waitForTransportWork(&event, std.testing.io, 0);
}
