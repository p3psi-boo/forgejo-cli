const std = @import("std");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const util = @import("util.zig");
const style = @import("style.zig");
const config = @import("config.zig");
const git_mod = @import("git.zig");
const App = @import("app.zig").App;

const cmd_auth = @import("cmd_auth.zig");
const cmd_repo = @import("cmd_repo.zig");
const cmd_issue = @import("cmd_issue.zig");
const cmd_pr = @import("cmd_pr.zig");
const cmd_misc = @import("cmd_misc.zig");
const cmd_actions = @import("cmd_actions.zig");
const cmd_release = @import("cmd_release.zig");
const cmd_user = @import("cmd_user.zig");
const cmd_org = @import("cmd_org.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var list = try cli.ArgList.init(arena, args[1..]);
    const help = list.takeFlag("help", 'h');
    const cwd = list.takeOpt("cwd", 'C');
    const host = list.takeOpt("host", 'H');
    const style_s = list.takeOpt("style", null);

    if (cwd) |dir| {
        std.process.setCurrentPath(init.io, dir) catch |err| {
            util.fatal("failed to change directory to {s}: {t}", .{ dir, err });
        };
    }

    const is_tty = std.Io.File.stdout().isTty(init.io) catch false;
    const kind = if (style_s) |s| style.StyleKind.parse(s) orelse util.fatal("invalid --style: {s}", .{s}) else .fancy;

    var http: std.http.Client = .{
        .allocator = init.gpa,
        .io = init.io,
    };
    defer http.deinit();
    http.initDefaultProxies(arena, init.environ_map) catch {};

    var app: App = .{
        .gpa = init.gpa,
        .arena = arena,
        .io = init.io,
        .environ = init.environ_map,
        .http = http,
        .keys = .{},
        .git = .{ .app = undefined },
        .render = style.Render.init(kind, is_tty),
        .host_flag = host,
    };
    app.git.app = &app;
    app.keys = try config.KeyInfo.load(&app);

    const cmd = list.takePositional();
    if (help and cmd == null) {
        cli.printTopHelp();
        return;
    }
    const name = cmd orelse {
        cli.printTopHelp();
        util.fatal("missing command", .{});
    };
    if (help) {
        cli.help(name);
        return;
    }

    if (util.eql(name, "auth")) {
        try cmd_auth.run(&app, &list);
    } else if (util.eql(name, "repo")) {
        try cmd_repo.run(&app, &list);
    } else if (util.eql(name, "issue")) {
        try cmd_issue.run(&app, &list);
    } else if (util.eql(name, "pr")) {
        try cmd_pr.run(&app, &list);
    } else if (util.eql(name, "milestone")) {
        try cmd_misc.milestone(&app, &list);
    } else if (util.eql(name, "wiki")) {
        try cmd_misc.wiki(&app, &list);
    } else if (util.eql(name, "actions")) {
        try cmd_actions.run(&app, &list);
    } else if (util.eql(name, "whoami")) {
        try cmd_misc.whoami(&app, &list);
    } else if (util.eql(name, "release")) {
        try cmd_release.run(&app, &list);
    } else if (util.eql(name, "tag")) {
        try cmd_misc.tag(&app, &list);
    } else if (util.eql(name, "user")) {
        try cmd_user.run(&app, &list);
    } else if (util.eql(name, "org")) {
        try cmd_org.run(&app, &list);
    } else if (util.eql(name, "version")) {
        try cmd_misc.version(&app, &list);
    } else if (util.eql(name, "completion")) {
        try cmd_misc.completion(&app, &list);
    } else {
        util.fatal("unknown command: {s}", .{name});
    }
}

test {
    _ = @import("git.zig");
    _ = @import("cli.zig");
    _ = @import("util.zig");
}
