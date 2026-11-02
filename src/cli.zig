const std = @import("std");
const util = @import("util.zig");

pub const ArgList = struct {
    items: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, args: []const [:0]const u8) !ArgList {
        var items: std.ArrayList([]const u8) = .empty;
        try items.ensureTotalCapacity(allocator, args.len);
        for (args) |a| items.appendAssumeCapacity(a);
        return .{ .items = items, .allocator = allocator };
    }

    pub fn deinit(self: *ArgList) void {
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn takeFlag(self: *ArgList, long: []const u8, short: ?u8) bool {
        var i: usize = 0;
        while (i < self.items.items.len) {
            const a = self.items.items[i];
            if (isLong(a, long) or isShort(a, short)) {
                _ = self.items.orderedRemove(i);
                return true;
            }
            i += 1;
        }
        return false;
    }

    pub fn takeOpt(self: *ArgList, long: []const u8, short: ?u8) ?[]const u8 {
        var i: usize = 0;
        while (i < self.items.items.len) {
            const a = self.items.items[i];
            if (longEqPrefix(a, long)) |val| {
                _ = self.items.orderedRemove(i);
                return val;
            }
            if (isLong(a, long) or isShort(a, short)) {
                _ = self.items.orderedRemove(i);
                if (i >= self.items.items.len) util.fatal("missing value for --{s}", .{long});
                const v = self.items.orderedRemove(i);
                if (std.mem.startsWith(u8, v, "-") and v.len > 1) util.fatal("missing value for --{s}", .{long});
                return v;
            }
            if (short) |s| {
                if (a.len >= 3 and a[0] == '-' and a[1] != '-' and a[1] == s) {
                    const v = a[2..];
                    _ = self.items.orderedRemove(i);
                    return v;
                }
            }
            i += 1;
        }
        return null;
    }

    pub fn takeOptMaybe(self: *ArgList, long: []const u8, short: ?u8) ?[]const u8 {
        // Present with optional value. Returns "" if flag present without value.
        var i: usize = 0;
        while (i < self.items.items.len) {
            const a = self.items.items[i];
            if (longEqPrefix(a, long)) |val| {
                _ = self.items.orderedRemove(i);
                return val;
            }
            if (isLong(a, long) or isShort(a, short)) {
                _ = self.items.orderedRemove(i);
                if (i < self.items.items.len) {
                    const v = self.items.items[i];
                    if (!(std.mem.startsWith(u8, v, "-") and v.len > 1)) {
                        return self.items.orderedRemove(i);
                    }
                }
                return "";
            }
            i += 1;
        }
        return null;
    }

    pub fn takeAll(self: *ArgList, long: []const u8, short: ?u8) ![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        while (self.takeOpt(long, short)) |v| {
            try out.append(self.allocator, v);
        }
        return out.toOwnedSlice(self.allocator);
    }

    pub fn takeBool(self: *ArgList, long: []const u8, short: ?u8) ?bool {
        const v = self.takeOpt(long, short) orelse return null;
        return util.parseBool(v) orelse util.fatal("invalid boolean for --{s}: {s}", .{ long, v });
    }

    pub fn takePositional(self: *ArgList) ?[]const u8 {
        var i: usize = 0;
        while (i < self.items.items.len) {
            const a = self.items.items[i];
            if (std.mem.eql(u8, a, "--")) {
                _ = self.items.orderedRemove(i);
                if (self.items.items.len == 0) return null;
                return self.items.orderedRemove(0);
            }
            if (std.mem.startsWith(u8, a, "-") and a.len > 1) {
                i += 1;
                continue;
            }
            return self.items.orderedRemove(i);
        }
        return null;
    }

    pub fn expectPositional(self: *ArgList, name: []const u8) []const u8 {
        return self.takePositional() orelse util.fatal("missing required argument <{s}>", .{name});
    }

    pub fn remainingPositionals(self: *ArgList) ![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        while (self.takePositional()) |p| try out.append(self.allocator, p);
        return out.toOwnedSlice(self.allocator);
    }

    pub fn rejectUnknownFlags(self: *ArgList) void {
        for (self.items.items) |a| {
            if (std.mem.startsWith(u8, a, "-") and a.len > 1 and !std.mem.eql(u8, a, "--")) {
                util.fatal("unexpected argument: {s}", .{a});
            }
        }
    }

    pub fn peekCommand(self: *ArgList) ?[]const u8 {
        for (self.items.items) |a| {
            if (std.mem.startsWith(u8, a, "-") and a.len > 1) continue;
            return a;
        }
        return null;
    }
};

fn isLong(a: []const u8, long: []const u8) bool {
    if (a.len < 3 or !std.mem.startsWith(u8, a, "--")) return false;
    return std.mem.eql(u8, a[2..], long);
}

fn isShort(a: []const u8, short: ?u8) bool {
    const s = short orelse return false;
    return a.len == 2 and a[0] == '-' and a[1] == s;
}

fn longEqPrefix(a: []const u8, long: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, a, "--")) return null;
    const rest = a[2..];
    if (rest.len <= long.len) return null;
    if (!std.mem.startsWith(u8, rest, long)) return null;
    if (rest[long.len] != '=') return null;
    return rest[long.len + 1 ..];
}

pub fn printTopHelp() void {
    std.debug.print(
        \\CLI tool for Forgejo
        \\
        \\Usage: fj [OPTIONS] <COMMAND>
        \\
        \\Commands:
        \\  repo         Manage repositories
        \\  issue        Manage issues
        \\  pr           Manage pull requests
        \\  milestone    Manage milestones
        \\  wiki         Wiki pages
        \\  actions      Forgejo Actions
        \\  whoami       Show the authenticated user
        \\  auth         Authentication
        \\  release      Manage releases
        \\  tag          Manage tags
        \\  user         Users
        \\  org          Organizations
        \\  version      Show version
        \\  completion   Generate shell completions
        \\
        \\Options:
        \\  -H, --host <HOST>     Forgejo host URL
        \\  -C, --cwd <DIR>       Change to this directory first
        \\      --style <STYLE>   fancy | minimal
        \\  -h, --help            Print help
        \\
    , .{});
}

pub fn help(topic: []const u8) void {
    if (util.eql(topic, "auth")) {
        std.debug.print(
            \\Usage: fj auth <COMMAND>
            \\
            \\Commands:
            \\  login              Log in to an instance (opens a browser)
            \\  logout <HOST>      Deletes login info for an instance
            \\  add-token [TOKEN]  Add an application token (alias: add-key)
            \\  use-ssh [BOOL]     Enable or disable SSH by default
            \\  list               List logged-in instances
            \\
        , .{});
        return;
    }
    if (util.eql(topic, "repo")) {
        std.debug.print(
            \\Usage: fj repo <COMMAND>
            \\
            \\Commands:
            \\  create <NAME>     Create a repository
            \\  fork <REPO>       Fork a repository
            \\  migrate <URL> <NAME>
            \\  view [REPO]       View a repository
            \\  readme [REPO]     Print the README
            \\  clone <REPO> [PATH]
            \\  star / unstar / star-status
            \\  watch / unwatch / watch-status
            \\  delete <REPO>
            \\  browse [REPO]
            \\  labels            Manage labels (alias: label)
            \\  edit [REPO]
            \\  units             Toggle repo units (alias: unit)
            \\
        , .{});
        return;
    }
    if (util.eql(topic, "issue")) {
        std.debug.print(
            \\Usage: fj issue [OPTIONS] <COMMAND>
            \\
            \\Commands:
            \\  create [TITLE]    Create an issue (--web to open in browser)
            \\  edit <ID>         Edit title/body/comment/labels/milestone
            \\  comment <ID> [BODY]
            \\  assign / unassign
            \\  close <ID>
            \\  search [QUERY]
            \\  view <ID>         View body/comments/assignees
            \\  templates
            \\  browse <ID>
            \\  depend / block    add|remove|list
            \\
        , .{});
        return;
    }
    if (util.eql(topic, "pr")) {
        std.debug.print(
            \\Usage: fj pr [OPTIONS] <COMMAND>
            \\
            \\Commands:
            \\  search / create / view / status / checkout
            \\  comment / assign / unassign / edit / close / merge
            \\  browse / review / depend / block
            \\
        , .{});
        return;
    }
    std.debug.print("Usage: fj {s} [OPTIONS] [COMMAND]\nUse `fj {s} --help` for details.\n", .{ topic, topic });
}

test "ArgList flags and options" {
    const args = [_][:0]const u8{ "--host", "codeberg.org", "-h", "repo", "view" };
    var list = try ArgList.init(std.testing.allocator, &args);
    defer list.deinit();
    try std.testing.expect(list.takeFlag("help", 'h'));
    try std.testing.expectEqualStrings("codeberg.org", list.takeOpt("host", 'H').?);
    try std.testing.expectEqualStrings("repo", list.takePositional().?);
    try std.testing.expectEqualStrings("view", list.takePositional().?);
    try std.testing.expect(list.takePositional() == null);
}
