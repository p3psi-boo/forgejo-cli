const std = @import("std");
const App = @import("app.zig").App;
const util = @import("util.zig");
const config = @import("config.zig");

pub const RepoName = struct {
    owner: []const u8,
    name: []const u8,

    pub fn parse(s: []const u8) ?RepoName {
        const stripped = util.stripSuffix(s, ".git");
        const parts = util.rsplitOnce(stripped, '/') orelse return null;
        var host_and_owner = parts[0];
        const name = parts[1];
        if (util.rsplitOnce(host_and_owner, '/')) |again| {
            host_and_owner = again[1];
        }
        if (host_and_owner.len == 0 or name.len == 0) return null;
        return .{ .owner = host_and_owner, .name = name };
    }

    pub fn parseArg(s: []const u8) RepoArg {
        const stripped = util.stripSuffix(s, ".git");
        const slash = std.mem.lastIndexOfScalar(u8, stripped, '/') orelse
            util.fatal("repo argument must be owner/name", .{});
        const name = stripped[slash + 1 ..];
        const head = stripped[0..slash];
        if (std.mem.lastIndexOfScalar(u8, head, '/')) |i| {
            return .{ .host = head[0..i], .owner = head[i + 1 ..], .name = name };
        }
        return .{ .host = null, .owner = head, .name = name };
    }
};

pub const RepoArg = struct {
    host: ?[]const u8,
    owner: []const u8,
    name: []const u8,

    pub fn asName(self: RepoArg) RepoName {
        return .{ .owner = self.owner, .name = self.name };
    }
};

pub const IssueId = struct {
    repo: ?RepoArg = null,
    number: i64,

    pub fn parse(s: []const u8) IssueId {
        if (util.rsplitOnce(s, '#')) |parts| {
            const repo = RepoName.parseArg(parts[0]);
            const number = util.parseI64(parts[1]) orelse util.fatal("invalid issue number: {s}", .{parts[1]});
            return .{ .repo = repo, .number = number };
        }
        const number = util.parseI64(util.stripPrefix(s, "#")) orelse util.fatal("invalid issue number: {s}", .{s});
        return .{ .number = number };
    }
};

pub const RepoInfo = struct {
    url: []const u8, // https://host[/path]
    host: []const u8, // host[:port][/path] without scheme
    name: ?RepoName,
    remote_name: ?[]const u8,
};

pub const Git = struct {
    app: *App,

    pub fn run(self: Git, argv: []const []const u8) !std.process.RunResult {
        return std.process.run(self.app.gpa, self.app.io, .{
            .argv = argv,
            .stdout_limit = .unlimited,
            .stderr_limit = .unlimited,
        }) catch |err| {
            util.fatal("git failed: {t}", .{err});
        };
    }

    pub fn forward(self: Git, argv: []const []const u8) !void {
        var child = std.process.spawn(self.app.io, .{
            .argv = argv,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch |err| {
            util.fatal("git failed: {t}", .{err});
        };
        const term = child.wait(self.app.io) catch |err| {
            util.fatal("git wait failed: {t}", .{err});
        };
        if (!term.success()) util.fatal("git failed", .{});
    }

    pub fn capture(self: Git, argv: []const []const u8) ![]u8 {
        const result = try self.run(argv);
        defer self.app.gpa.free(result.stderr);
        if (!result.term.success()) {
            self.app.gpa.free(result.stdout);
            return error.GitFailed;
        }
        const out = util.trim(result.stdout);
        const duped = try self.app.arena.dupe(u8, out);
        self.app.gpa.free(result.stdout);
        return duped;
    }

    pub fn config(self: Git, key: []const u8) !?[]const u8 {
        const result = self.capture(&.{ "git", "config", "--get", key }) catch return null;
        if (result.len == 0) return null;
        return result;
    }

    pub fn remotes(self: Git) ![][]const u8 {
        const out = self.capture(&.{ "git", "remote" }) catch return &.{};
        if (out.len == 0) return &.{};
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, out, '\n');
        while (it.next()) |line| {
            const t = util.trim(line);
            if (t.len > 0) try list.append(self.app.arena, t);
        }
        return list.toOwnedSlice(self.app.arena);
    }

    pub fn remoteUrl(self: Git, name: []const u8) !?[]const u8 {
        return self.capture(&.{ "git", "remote", "get-url", name }) catch return null;
    }

    pub fn currentBranch(self: Git) !?[]const u8 {
        return self.capture(&.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }) catch return null;
    }

    pub fn upstreamRemote(self: Git) !?[]const u8 {
        const branch = try self.currentBranch() orelse return null;
        const key = try std.fmt.allocPrint(self.app.arena, "branch.{s}.remote", .{branch});
        return self.config(key);
    }

    pub fn inRepo(self: Git) bool {
        const result = self.capture(&.{ "git", "rev-parse", "--is-inside-work-tree" }) catch return false;
        return util.eql(result, "true");
    }
};

pub fn normalizeRemoteUrl(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, s, "://") != null) return s;
    const at = std.mem.indexOfScalar(u8, s, '@') orelse 0;
    if (std.mem.indexOfScalarPos(u8, s, at, ':')) |colon| {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(allocator, "ssh://");
        try out.appendSlice(allocator, s[0..colon]);
        try out.append(allocator, '/');
        try out.appendSlice(allocator, s[colon + 1 ..]);
        return out.toOwnedSlice(allocator);
    }
    return s;
}

pub fn hostName(url: []const u8) []const u8 {
    var s = url;
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    if (std.mem.indexOfScalar(u8, s, '@')) |i| s = s[i + 1 ..];
    s = util.stripSuffix(s, "/");
    return s;
}

pub fn hostOnly(url: []const u8) []const u8 {
    var s = hostName(url);
    if (std.mem.indexOfScalar(u8, s, '/')) |i| s = s[0..i];
    return s;
}

pub fn stripRepoFromUrl(url: []const u8) !struct { []const u8, RepoName } {
    var parsed = url;
    parsed = util.stripSuffix(parsed, "/");
    parsed = util.stripSuffix(parsed, ".git");
    const name_slash = std.mem.lastIndexOfScalar(u8, parsed, '/') orelse return error.InvalidUrl;
    const name = parsed[name_slash + 1 ..];
    const head = parsed[0..name_slash];
    const owner_slash = std.mem.lastIndexOfScalar(u8, head, '/') orelse return error.InvalidUrl;
    const owner = head[owner_slash + 1 ..];
    return .{ head[0..owner_slash], .{ .owner = owner, .name = name } };
}

pub fn toHttps(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var s = url;
    if (std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://")) {
        return util.stripSuffix(s, "/");
    }
    if (std.mem.startsWith(u8, s, "ssh://")) s = s["ssh://".len..];
    if (std.mem.indexOfScalar(u8, s, '@')) |i| s = s[i + 1 ..];
    if (std.mem.indexOfScalar(u8, s, ':')) |i| {
        if (std.mem.indexOfScalar(u8, s, '/') == null) {
            // host:path already converted
        } else {
            // host:port/path - keep
        }
        _ = i;
    }
    const host = hostOnly(url);
    return std.fmt.allocPrint(allocator, "https://{s}", .{host});
}

pub fn getCurrent(
    app: *App,
    host_flag: ?[]const u8,
    repo_arg: ?RepoArg,
    remote_flag: ?[]const u8,
) !RepoInfo {
    var repo_url: ?[]const u8 = null;
    var repo_name: ?RepoName = null;

    if (repo_arg) |ra| {
        if (ra.host) |h| {
            repo_url = try normalizeHost(app, h);
        }
        repo_name = ra.asName();
    }

    var host_url: ?[]const u8 = null;
    if (host_flag) |h| host_url = try normalizeHost(app, h);

    var remote_url: ?[]const u8 = null;
    var remote_repo: ?RepoName = null;
    var remote_name: ?[]const u8 = null;

    if (app.git.inRepo()) {
        var name = remote_flag;
        if (name == null) {
            const all = try app.git.remotes();
            if (all.len == 1) name = all[0];
        }
        if (name == null) {
            if (try app.git.upstreamRemote()) |up| name = up;
        }
        if (name) |n| {
            if (try app.git.remoteUrl(n)) |u| {
                const nu = try normalizeRemoteUrl(app.arena, u);
                if (stripRepoFromUrl(nu)) |pair| {
                    remote_url = try toHttps(app.arena, pair[0]);
                    remote_repo = pair[1];
                    remote_name = n;
                } else |_| {}
            }
        }
    } else if (remote_flag != null) {
        util.fatal("remote specified but no git repo found", .{});
    }

    const url: []const u8 = blk: {
        if (repo_url) |u| break :blk u;
        if (repo_name != null) {
            break :blk host_url orelse remote_url orelse fallbackHost(app) orelse
                util.fatal("can't figure out the host; try --host", .{});
        }
        if (remote_flag != null or host_url == null or hostsEqual(remote_url, host_url)) {
            break :blk remote_url orelse host_url orelse fallbackHost(app) orelse
                util.fatal("can't figure out the host; try --host", .{});
        }
        break :blk host_url.?;
    };

    const name: ?RepoName = if (repo_url != null)
        repo_name
    else if (repo_name != null)
        repo_name
    else if (remote_flag != null or host_url == null or hostsEqual(remote_url, host_url))
        remote_repo
    else
        null;

    const https = try toHttps(app.arena, url);
    return .{
        .url = https,
        .host = hostName(https),
        .name = name,
        .remote_name = remote_name,
    };
}

fn hostsEqual(a: ?[]const u8, b: ?[]const u8) bool {
    const ha = if (a) |x| hostName(x) else null;
    const hb = if (b) |x| hostName(x) else null;
    if (ha == null and hb == null) return true;
    if (ha == null or hb == null) return false;
    return util.eql(ha.?, hb.?);
}

fn fallbackHost(app: *App) ?[]const u8 {
    const env = app.environ.get("FJ_FALLBACK_HOST") orelse return null;
    return normalizeHost(app, env) catch {
        std.debug.print("FJ_FALLBACK_HOST is not a valid URL\n", .{});
        return null;
    };
}

pub fn normalizeHost(app: *App, host: []const u8) ![]const u8 {
    var u = host;
    if (std.mem.indexOf(u8, u, "://") == null) {
        u = try std.fmt.allocPrint(app.arena, "https://{s}", .{u});
    }
    u = util.stripSuffix(u, "/");
    const h = hostName(u);
    const replaced = app.keys.derefAlias(h);
    if (!util.eql(replaced, h)) {
        return std.fmt.allocPrint(app.arena, "https://{s}", .{replaced});
    }
    return u;
}

pub fn requireName(info: RepoInfo) RepoName {
    return info.name orelse util.fatal("can't figure what repo to access, try specifying with --repo", .{});
}

test "parse repo arg" {
    const a = RepoName.parseArg("owner/name");
    try std.testing.expectEqualStrings("owner", a.owner);
    try std.testing.expectEqualStrings("name", a.name);
    try std.testing.expect(a.host == null);

    const b = RepoName.parseArg("codeberg.org/owner/name.git");
    try std.testing.expectEqualStrings("codeberg.org", b.host.?);
    try std.testing.expectEqualStrings("owner", b.owner);
    try std.testing.expectEqualStrings("name", b.name);
}

test "ssh url normalize" {
    const u = try normalizeRemoteUrl(std.testing.allocator, "git@codeberg.org:forgejo-contrib/forgejo-cli.git");
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings("ssh://git@codeberg.org/forgejo-contrib/forgejo-cli.git", u);
}

test "issue id" {
    const a = IssueId.parse("12");
    try std.testing.expectEqual(@as(i64, 12), a.number);
    try std.testing.expect(a.repo == null);
    const b = IssueId.parse("owner/repo#7");
    try std.testing.expectEqual(@as(i64, 7), b.number);
    try std.testing.expectEqualStrings("owner", b.repo.?.owner);
}
