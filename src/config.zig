const std = @import("std");
const App = @import("app.zig").App;
const util = @import("util.zig");

pub const LoginKind = enum { Application, OAuth };

pub const LoginInfo = struct {
    kind: LoginKind,
    token: []const u8,
    refresh_token: []const u8 = "",
    expires_at: []const u8 = "",
};

const RawLogin = struct {
    type: []const u8,
    token: []const u8,
    refresh_token: ?[]const u8 = null,
    expires_at: ?[]const u8 = null,
};

const RawKeys = struct {
    hosts: std.json.ArrayHashMap(RawLogin) = .{},
    aliases: std.json.ArrayHashMap([]const u8) = .{},
    default_ssh: [][]const u8 = &.{},
};

pub const KeyInfo = struct {
    hosts: std.array_hash_map.String(LoginInfo) = .empty,
    aliases: std.array_hash_map.String([]const u8) = .empty,
    default_ssh: std.array_hash_map.String(void) = .empty,

    pub fn load(app: *App) !KeyInfo {
        const path = try keysPath(app);
        const file = std.Io.Dir.cwd().openFile(app.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => util.fatal("failed to read {s}: {t}", .{ path, err }),
        };
        defer file.close(app.io);
        var buf: [4096]u8 = undefined;
        var reader = file.reader(app.io, &buf);
        const json = reader.interface.allocRemaining(app.arena, .unlimited) catch util.fatal("failed to read {s}", .{path});
        const parsed = std.json.parseFromSliceLeaky(RawKeys, app.arena, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch util.fatal("invalid keys.json at {s}", .{path});

        var info: KeyInfo = .{};
        var hit = parsed.hosts.map.iterator();
        while (hit.next()) |kv| {
            const raw = kv.value_ptr.*;
            const kind: LoginKind = if (util.eql(raw.type, "OAuth")) .OAuth else .Application;
            try info.hosts.put(app.arena, kv.key_ptr.*, .{
                .kind = kind,
                .token = raw.token,
                .refresh_token = raw.refresh_token orelse "",
                .expires_at = raw.expires_at orelse "",
            });
        }
        var ait = parsed.aliases.map.iterator();
        while (ait.next()) |kv| {
            try info.aliases.put(app.arena, kv.key_ptr.*, kv.value_ptr.*);
        }
        for (parsed.default_ssh) |host| {
            try info.default_ssh.put(app.arena, host, {});
        }
        return info;
    }

    pub fn save(self: *const KeyInfo, app: *App) !void {
        const dir = try dataDir(app);
        std.Io.Dir.cwd().createDirPath(app.io, dir) catch |err| {
            util.fatal("failed to create {s}: {t}", .{ dir, err });
        };
        const path = try keysPath(app);

        var aw: std.Io.Writer.Allocating = .init(app.arena);
        var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
        try s.beginObject();
        try s.objectField("hosts");
        try s.beginObject();
        var hit = self.hosts.iterator();
        while (hit.next()) |kv| {
            try s.objectField(kv.key_ptr.*);
            try s.beginObject();
            try s.objectField("type");
            try s.write(@tagName(kv.value_ptr.kind));
            try s.objectField("token");
            try s.write(kv.value_ptr.token);
            if (kv.value_ptr.kind == .OAuth) {
                try s.objectField("refresh_token");
                try s.write(kv.value_ptr.refresh_token);
                try s.objectField("expires_at");
                try s.write(kv.value_ptr.expires_at);
            }
            try s.endObject();
        }
        try s.endObject();
        try s.objectField("aliases");
        try s.beginObject();
        var ait = self.aliases.iterator();
        while (ait.next()) |kv| {
            try s.objectField(kv.key_ptr.*);
            try s.write(kv.value_ptr.*);
        }
        try s.endObject();
        try s.objectField("default_ssh");
        try s.beginArray();
        var sit = self.default_ssh.iterator();
        while (sit.next()) |kv| try s.write(kv.key_ptr.*);
        try s.endArray();
        try s.endObject();

        util.writeFileMode(app, path, aw.written(), util.privateFilePerms()) catch {};
    }

    pub fn tokenFor(self: *const KeyInfo, host: []const u8) ?[]const u8 {
        const login = self.hosts.getPtr(host) orelse return null;
        return login.token;
    }

    pub fn derefAlias(self: *const KeyInfo, host: []const u8) []const u8 {
        return self.aliases.get(host) orelse host;
    }

    pub fn usesSsh(self: *const KeyInfo, host: []const u8) bool {
        return self.default_ssh.contains(host);
    }
};

pub fn dataDir(app: *App) ![]u8 {
    if (app.environ.get("XDG_DATA_HOME")) |xdg| {
        return std.fs.path.join(app.arena, &.{ xdg, "forgejo-cli" });
    }
    const home = app.environ.get("HOME") orelse util.fatal("HOME is not set", .{});
    return std.fs.path.join(app.arena, &.{ home, ".local", "share", "forgejo-cli" });
}

pub fn keysPath(app: *App) ![]u8 {
    return std.fs.path.join(app.arena, &.{ try dataDir(app), "keys.json" });
}

pub fn configDir(app: *App) ![]u8 {
    if (app.environ.get("XDG_CONFIG_HOME")) |xdg| {
        return std.fs.path.join(app.arena, &.{ xdg, "forgejo-cli" });
    }
    const home = app.environ.get("HOME") orelse util.fatal("HOME is not set", .{});
    return std.fs.path.join(app.arena, &.{ home, ".config", "forgejo-cli" });
}

pub fn builtinClientId(host: []const u8) ?[]const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "codeberg.org", "19ac3dd0-e101-445d-aa60-d8ea3876bc5d" },
        .{ "code.forgejo.org", "ab67d8a2-72bd-42e8-ae05-937eaba31e24" },
        .{ "v11.next.forgejo.org", "0df6d672-fe05-4c9a-a5a9-e111e4905e14" },
        .{ "v13.next.forgejo.org", "ef27a227-65f4-4bcb-be56-f8c9b44457b0" },
        .{ "v14.next.forgejo.org", "2dc5d6d7-01b0-47b4-814e-b4b60aea2376" },
        .{ "v15.next.forgejo.org", "344998d8-4139-4a51-8ef9-a5fa40673ea5" },
        .{ "v16.next.forgejo.org", "0b561d01-fd05-4321-9d46-9cb8c776fc80" },
        .{ "v17.next.forgejo.org", "e1a0797a-77af-41a5-b086-9efa6062298b" },
        .{ "git.disroot.org", "c6051ae0-6d21-4c17-92e6-41b957376d09" },
        .{ "git.pub.solar", "6c7fad2f-41c4-4c2d-90b2-5f7fd19c9be2" },
        .{ "git.kaki87.net", "951299e6-cf99-4a9e-8aaf-4b4b4ac36f04" },
        .{ "git.gay", "15233962-8f9d-4192-a7d7-129fb8c6bbff" },
        .{ "git.auxolotl.org", "09fb4377-1e98-4c94-a43f-2c9843388e11" },
        .{ "git.lix.systems", "71ec029f-b5a1-4079-8e06-5b957288b063" },
        .{ "code.ffmpeg.org", "75d19c4d-01d0-4825-8953-76ad66543f2c" },
        .{ "forge.fedoraproject.org", "b15a2f44-75b0-4d2f-a740-50e45cc161a3" },
        .{ "codefloe.com", "d8f0480c-cc0a-4cfc-8a16-4b88230d61d4" },
        .{ "openlat.dev", "4a69c5bc-64a0-482d-bd2f-7c1b1b3e0b6e" },
    };
    for (table) |row| {
        if (util.eql(row[0], host)) return row[1];
    }
    return null;
}

pub fn clientIdFor(app: *App, host: []const u8) !?[]const u8 {
    const paths = [_][]const u8{
        try std.fs.path.join(app.arena, &.{ try configDir(app), "client_ids" }),
        "/etc/fj/client_ids",
    };
    for (paths) |p| {
        const file = std.Io.Dir.cwd().openFile(app.io, p, .{}) catch continue;
        defer file.close(app.io);
        var buf: [4096]u8 = undefined;
        var reader = file.reader(app.io, &buf);
        const text = reader.interface.allocRemaining(app.arena, .unlimited) catch continue;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw_line| {
            const no_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |h| raw_line[0..h] else raw_line;
            const line = util.trim(no_comment);
            if (line.len == 0) continue;
            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            const h = parts.next() orelse continue;
            const id = parts.next() orelse continue;
            if (util.eql(h, host)) return id;
        }
    }
    return builtinClientId(host);
}
