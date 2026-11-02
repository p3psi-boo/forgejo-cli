const std = @import("std");
const App = @import("app.zig").App;
const cli = @import("cli.zig");
const util = @import("util.zig");
const git_mod = @import("git.zig");
const api_mod = @import("api.zig");
const style = @import("style.zig");
const loc = @import("loc.zig");

pub fn run(app: *App, args: *cli.ArgList) !void {
    const remote = args.takeOpt("remote", 'R');
    const sub = args.takePositional() orelse {
        cli.help(app.arena, "issue");
        return;
    };
    if (util.eql(sub, "create")) {
        try create(app, args, remote);
    } else if (util.eql(sub, "view")) {
        try view(app, args, remote);
    } else if (util.eql(sub, "search")) {
        try search(app, args, remote, "issues");
    } else if (util.eql(sub, "comment")) {
        try comment(app, args, remote);
    } else if (util.eql(sub, "close")) {
        try closeIssue(app, args, remote);
    } else if (util.eql(sub, "assign")) {
        try assign(app, args, remote, true);
    } else if (util.eql(sub, "unassign")) {
        try assign(app, args, remote, false);
    } else if (util.eql(sub, "edit")) {
        try edit(app, args, remote);
    } else if (util.eql(sub, "browse")) {
        try browse(app, args, remote);
    } else if (util.eql(sub, "templates")) {
        try templates(app, args, remote);
    } else if (util.eql(sub, "depend")) {
        try depend(app, args, remote, false);
    } else if (util.eql(sub, "block")) {
        try depend(app, args, remote, true);
    } else {
        util.fatal("unknown issue command: {s}", .{sub});
    }
}

fn repoFrom(app: *App, args: *cli.ArgList, remote: ?[]const u8, maybe_id: ?git_mod.IssueId) !struct { git_mod.RepoInfo, git_mod.RepoName } {
    const repo_flag = if (args.takeOpt("repo", 'r')) |s| git_mod.RepoName.parseArg(s) else null;
    const from_id = if (maybe_id) |id| id.repo else null;
    const info = try git_mod.getCurrent(app, app.host_flag, repo_flag orelse from_id, remote);
    return .{ info, git_mod.requireName(info) };
}

fn create(app: *App, args: *cli.ArgList, remote: ?[]const u8) !void {
    const web = args.takeFlag("web", null);
    const body_flag = args.takeOpt("body", null);
    const body_file = args.takeOpt("body-file", null);
    const milestone = args.takeOpt("milestone", null);
    const pair = try repoFrom(app, args, remote, null);
    const title_or_null = args.takePositional();
    args.rejectUnknownFlags();
    const info = pair[0];
    const name = pair[1];
    var api = app.apiFor(info.url);
    if (web) {
        const url = try std.fmt.allocPrint(app.arena, "{s}/{s}/{s}/issues/new", .{ info.url, name.owner, name.name });
        try util.openUrl(app, url);
        return;
    }
    const title = title_or_null orelse util.fatal("title is required (or pass --web)", .{});
    var body: []const u8 = body_flag orelse "";
    if (body_file) |p| body = try util.readFile(app, p);
    if (body_flag == null and body_file == null) {
        try util.editor(app, &body, "md");
    }
    var milestone_id: ?i64 = null;
    if (milestone) |m| milestone_id = try lookupMilestone(app, &api, name, m);
    const payload = try util.jsonStringify(app.arena, .{
        .title = title,
        .body = body,
        .milestone = milestone_id,
    });
    const issue = api.parse(api_mod.Issue, try api.post("/repos/{s}/{s}/issues", .{ name.owner, name.name }, payload));
    app.say("msg-issue-create-success", &.{
        loc.num("number", issue.number orelse 0),
        loc.str("title", issue.title orelse title),
    });
}

pub fn lookupMilestone(app: *App, api: *api_mod.Api, name: git_mod.RepoName, title: []const u8) !i64 {
    if (util.parseI64(title)) |n| return n;
    const all = api.parse([]api_mod.Milestone, try api.getQuery("/repos/{s}/{s}/milestones", .{ name.owner, name.name }, "?state=all"));
    for (all) |m| {
        if (m.title) |t| if (util.eql(t, title)) return m.id orelse util.fatal("milestone has no id", .{});
    }
    app.die("msg-milestone-not_found", &.{});
}

fn view(app: *App, args: *cli.ArgList, remote: ?[]const u8) !void {
    const id = git_mod.IssueId.parse(args.expectPositional("ID"));
    const what = args.takePositional() orelse "body";
    const idx = if (util.eql(what, "comment")) args.takePositional() else null;
    args.rejectUnknownFlags();
    const pair = try repoFrom(app, args, remote, id);
    const name = pair[1];
    var api = app.apiFor(pair[0].url);
    const issue = api.parse(api_mod.Issue, try api.get("/repos/{s}/{s}/issues/{d}", .{ name.owner, name.name, id.number }));
    if (issue.pull_request != null) {
        std.debug.print("(this is a pull request)\n", .{});
    }
    if (util.eql(what, "body")) {
        printIssue(app, issue);
    } else if (util.eql(what, "comments")) {
        try printComments(app, &api, name, id.number, null);
    } else if (util.eql(what, "comment")) {
        const n = util.parseU32(idx orelse util.fatal("comment index required", .{})) orelse util.fatal("invalid index", .{});
        try printComments(app, &api, name, id.number, n);
    } else if (util.eql(what, "assignees")) {
        if (issue.assignees) |as| {
            for (as) |u| std.debug.print("{s}\n", .{u.login orelse "?"});
        }
    } else {
        util.fatal("unknown view command: {s}", .{what});
    }
}

pub fn printIssue(app: *App, issue: api_mod.Issue) void {
    const r = app.render;
    const state = issue.state orelse "?";
    const author = if (issue.user) |u| u.login orelse "?" else "?";
    std.debug.print("{s}{s}{s} #{d} {s}{s}{s} by {s}\n", .{
        r.bold,
        issue.title orelse "?",
        r.reset,
        issue.number orelse 0,
        if (util.eql(state, "open")) r.green else r.red,
        state,
        r.reset,
        author,
    });
    if (issue.labels) |labels| {
        for (labels) |label| {
            style.renderLabel(r, label.name orelse "???", label.color orelse "FFFFFF", label.exclusive orelse false);
            std.debug.print(" ", .{});
        }
        if (labels.len > 0) std.debug.print("\n", .{});
    }
    if (issue.body) |b| {
        if (b.len > 0) {
            std.debug.print("\n", .{});
            style.markdown(r, b);
        }
    }
    std.debug.print("\n{d} comments\n", .{issue.comments orelse 0});
}

pub fn printComments(app: *App, api: *api_mod.Api, name: git_mod.RepoName, number: i64, only: ?u32) !void {
    const comments = api.parse([]api_mod.Comment, try api.get("/repos/{s}/{s}/issues/{d}/comments", .{ name.owner, name.name, number }));
    for (comments, 1..) |c, i| {
        if (only) |n| {
            if (n != i) continue;
        }
        const author = if (c.user) |u| u.login orelse "?" else "?";
        std.debug.print("{s}#{d}{s} {s}\n", .{ app.render.bold, i, app.render.reset, author });
        if (c.body) |b| style.markdown(app.render, b);
        std.debug.print("\n", .{});
    }
}

pub fn search(app: *App, args: *cli.ArgList, remote: ?[]const u8, kind: []const u8) !void {
    const labels = args.takeOpt("labels", 'l');
    const creator = args.takeOpt("creator", 'c');
    const assignee = args.takeOpt("assignee", 'a');
    const state = args.takeOpt("state", 's');
    const page_s = args.takeOpt("page", 'p');
    const all = args.takeFlag("all", null);
    const milestones = args.takeOpt("milestones", 'm');
    const pair = try repoFrom(app, args, remote, null);
    const q = args.takePositional();
    args.rejectUnknownFlags();
    const name = pair[1];
    var api = app.apiFor(pair[0].url);
    var qs = api_mod.query(app.arena);
    try qs.add("type", kind);
    try qs.addOpt("q", q);
    try qs.addOpt("labels", labels);
    try qs.addOpt("created_by", creator);
    try qs.addOpt("assigned_by", assignee);
    try qs.addOpt("state", state);
    try qs.addOpt("milestones", milestones);
    if (!all) try qs.addInt("page", util.parseU32(page_s orelse "1") orelse 1);
    try qs.addInt("limit", 25);
    const issues = api.parse([]api_mod.Issue, try api.getQuery("/repos/{s}/{s}/issues", .{ name.owner, name.name }, qs.slice()));
    std.debug.print("{d} {s}\n", .{ issues.len, kind });
    for (issues) |issue| {
        const author = if (issue.user) |u| u.login orelse "?" else "?";
        std.debug.print("#{d} {s} ({s})\n", .{ issue.number orelse 0, issue.title orelse "?", author });
    }
}

fn comment(app: *App, args: *cli.ArgList, remote: ?[]const u8) !void {
    const body_file = args.takeOpt("body-file", null);
    const id = git_mod.IssueId.parse(args.expectPositional("ID"));
    var body = args.takePositional();
    args.rejectUnknownFlags();
    if (body_file) |p| body = try util.readFile(app, p);
    var contents = body orelse "";
    if (body == null) try util.editor(app, &contents, "md");
    const pair = try repoFrom(app, args, remote, id);
    const name = pair[1];
    var api = app.apiFor(pair[0].url);
    const payload = try util.jsonStringify(app.arena, .{ .body = contents });
    _ = try api.post("/repos/{s}/{s}/issues/{d}/comments", .{ name.owner, name.name, id.number }, payload);
    std.debug.print("commented on #{d}\n", .{id.number});
}

fn closeIssue(app: *App, args: *cli.ArgList, remote: ?[]const u8) !void {
    const with_msg = args.takeOptMaybe("with-msg", 'w');
    const id = git_mod.IssueId.parse(args.expectPositional("ID"));
    args.rejectUnknownFlags();
    const pair = try repoFrom(app, args, remote, id);
    const name = pair[1];
    var api = app.apiFor(pair[0].url);
    if (with_msg) |msg| {
        var contents: []const u8 = if (msg.len == 0) "" else msg;
        if (msg.len == 0) try util.editor(app, &contents, "md");
        if (contents.len > 0) {
            const payload = try util.jsonStringify(app.arena, .{ .body = contents });
            _ = try api.post("/repos/{s}/{s}/issues/{d}/comments", .{ name.owner, name.name, id.number }, payload);
        }
    }
    const payload = try util.jsonStringify(app.arena, .{ .state = "closed" });
    const closed = api.parse(api_mod.Issue, try api.patch("/repos/{s}/{s}/issues/{d}", .{ name.owner, name.name, id.number }, payload));
    app.say("msg-issue-close-success", &.{
        loc.num("number", id.number),
        loc.str("title", closed.title orelse ""),
    });
}

fn assign(app: *App, args: *cli.ArgList, remote: ?[]const u8, add: bool) !void {
    const id = git_mod.IssueId.parse(args.expectPositional("ID"));
    const users = try args.remainingPositionals();
    if (users.len == 0) util.fatal("specify at least one user", .{});
    const pair = try repoFrom(app, args, remote, id);
    const name = pair[1];
    var api = app.apiFor(pair[0].url);
    const issue = api.parse(api_mod.Issue, try api.get("/repos/{s}/{s}/issues/{d}", .{ name.owner, name.name, id.number }));
    var list: std.ArrayList([]const u8) = .empty;
    if (issue.assignees) |as| {
        for (as) |u| if (u.login) |l| try list.append(app.arena, l);
    }
    if (add) {
        for (users) |u| try list.append(app.arena, u);
    } else {
        var kept: std.ArrayList([]const u8) = .empty;
        for (list.items) |existing| {
            var drop = false;
            for (users) |u| if (util.eql(existing, u)) {
                drop = true;
                break;
            };
            if (!drop) try kept.append(app.arena, existing);
        }
        list = kept;
    }
    const payload = try util.jsonStringify(app.arena, .{ .assignees = list.items });
    _ = try api.patch("/repos/{s}/{s}/issues/{d}", .{ name.owner, name.name, id.number }, payload);
    std.debug.print("{s} #{d}\n", .{ if (add) "assigned" else "unassigned", id.number });
}

fn edit(app: *App, args: *cli.ArgList, remote: ?[]const u8) !void {
    const id = git_mod.IssueId.parse(args.expectPositional("ID"));
    const what = args.expectPositional("FIELD");
    const pair = try repoFrom(app, args, remote, id);
    const name = pair[1];
    var api = app.apiFor(pair[0].url);
    if (util.eql(what, "title")) {
        var title = args.takePositional() orelse "";
        if (title.len == 0) try util.editor(app, &title, null);
        args.rejectUnknownFlags();
        const payload = try util.jsonStringify(app.arena, .{ .title = title });
        _ = try api.patch("/repos/{s}/{s}/issues/{d}", .{ name.owner, name.name, id.number }, payload);
    } else if (util.eql(what, "body")) {
        var body = args.takePositional() orelse "";
        if (body.len == 0) {
            const issue = api.parse(api_mod.Issue, try api.get("/repos/{s}/{s}/issues/{d}", .{ name.owner, name.name, id.number }));
            body = issue.body orelse "";
            try util.editor(app, &body, "md");
        }
        args.rejectUnknownFlags();
        const payload = try util.jsonStringify(app.arena, .{ .body = body });
        _ = try api.patch("/repos/{s}/{s}/issues/{d}", .{ name.owner, name.name, id.number }, payload);
    } else if (util.eql(what, "labels")) {
        const add = try args.takeAll("add", 'a');
        const rm = try args.takeAll("rm", 'r');
        args.rejectUnknownFlags();
        try editLabels(app, &api, name, id.number, add, rm);
    } else if (util.eql(what, "milestone")) {
        const unset = args.takeFlag("unset", 'u');
        const title = args.takePositional();
        args.rejectUnknownFlags();
        const mid: ?i64 = if (unset) 0 else if (title) |t| try lookupMilestone(app, &api, name, t) else util.fatal("specify a milestone or --unset", .{});
        const payload = try util.jsonStringify(app.arena, .{ .milestone = mid });
        _ = try api.patch("/repos/{s}/{s}/issues/{d}", .{ name.owner, name.name, id.number }, payload);
    } else if (util.eql(what, "comment")) {
        const idx_s = args.expectPositional("IDX");
        var new_body = args.takePositional() orelse "";
        const idx = util.parseU32(idx_s) orelse util.fatal("invalid index", .{});
        const comments = api.parse([]api_mod.Comment, try api.get("/repos/{s}/{s}/issues/{d}/comments", .{ name.owner, name.name, id.number }));
        if (idx == 0 or idx > comments.len) util.fatal("comment index out of range", .{});
        const comment_id = comments[idx - 1].id orelse util.fatal("comment has no id", .{});
        if (new_body.len == 0) {
            new_body = comments[idx - 1].body orelse "";
            try util.editor(app, &new_body, "md");
        }
        const payload = try util.jsonStringify(app.arena, .{ .body = new_body });
        _ = try api.patch("/repos/{s}/{s}/issues/comments/{d}", .{ name.owner, name.name, comment_id }, payload);
    } else {
        util.fatal("unknown edit field: {s}", .{what});
    }
    std.debug.print("updated #{d}\n", .{id.number});
}

pub fn editLabels(app: *App, api: *api_mod.Api, name: git_mod.RepoName, number: i64, add: []const []const u8, rm: []const []const u8) !void {
    const labels = api.parse([]api_mod.Label, try api.get("/repos/{s}/{s}/labels", .{ name.owner, name.name }));
    var ids: std.ArrayList(i64) = .empty;
    for (add) |n| {
        var found = false;
        for (labels) |label| {
            if (label.name) |ln| {
                if (util.eql(ln, n)) {
                    if (label.id) |id| try ids.append(app.arena, id);
                    found = true;
                    break;
                }
            }
        }
        if (!found) std.debug.print("'{s}' doesn't exist\n", .{n});
    }
    if (ids.items.len > 0) {
        const payload = try util.jsonStringify(app.arena, .{ .labels = ids.items });
        _ = try api.post("/repos/{s}/{s}/issues/{d}/labels", .{ name.owner, name.name, number }, payload);
    }
    for (rm) |n| {
        api.delete("/repos/{s}/{s}/issues/{d}/labels/{s}", .{ name.owner, name.name, number, n }) catch {};
    }
}

fn browse(app: *App, args: *cli.ArgList, remote: ?[]const u8) !void {
    const id = git_mod.IssueId.parse(args.expectPositional("ID"));
    args.rejectUnknownFlags();
    const pair = try repoFrom(app, args, remote, id);
    const name = pair[1];
    var api = app.apiFor(pair[0].url);
    const issue = api.parse(api_mod.Issue, try api.get("/repos/{s}/{s}/issues/{d}", .{ name.owner, name.name, id.number }));
    try util.openUrl(app, issue.html_url orelse util.fatal("no html url", .{}));
}

fn templates(app: *App, args: *cli.ArgList, remote: ?[]const u8) !void {
    const pair = try repoFrom(app, args, remote, null);
    args.rejectUnknownFlags();
    const name = pair[1];
    var api = app.apiFor(pair[0].url);
    const body = api.get("/repos/{s}/{s}/issue_templates", .{ name.owner, name.name }) catch {
        std.debug.print("no issue templates\n", .{});
        return;
    };
    const Tmpl = struct { name: ?[]const u8 = null, title: ?[]const u8 = null, about: ?[]const u8 = null };
    const tmpls = api.parse([]Tmpl, body);
    for (tmpls) |t| std.debug.print("{s}{s} {s}{s}\n", .{
        app.render.bullet,
        if (t.name) |n| n else "?",
        app.render.dash,
        t.about orelse t.title orelse "",
    });
}

fn depend(app: *App, args: *cli.ArgList, remote: ?[]const u8, blocking: bool) !void {
    const sub = args.expectPositional("ACTION");
    const id = git_mod.IssueId.parse(args.expectPositional("ISSUE"));
    const pair = try repoFrom(app, args, remote, id);
    const name = pair[1];
    var api = app.apiFor(pair[0].url);
    const kind: []const u8 = if (blocking) "blocks" else "dependencies";
    if (util.eql(sub, "list")) {
        args.rejectUnknownFlags();
        const issues = api.parse([]api_mod.Issue, try api.get("/repos/{s}/{s}/issues/{d}/{s}", .{ name.owner, name.name, id.number, kind }));
        for (issues) |issue| std.debug.print("#{d} {s}\n", .{ issue.number orelse 0, issue.title orelse "?" });
        return;
    }
    const targets = try args.remainingPositionals();
    if (targets.len == 0) util.fatal("specify target issues", .{});
    if (util.eql(sub, "add")) {
        for (targets) |t| {
            const target = git_mod.IssueId.parse(t);
            const tn = target.repo orelse git_mod.RepoArg{ .host = null, .owner = name.owner, .name = name.name };
            const payload = try util.jsonStringify(app.arena, .{
                .index = target.number,
                .owner = tn.owner,
                .repo = tn.name,
            });
            _ = try api.post("/repos/{s}/{s}/issues/{d}/{s}", .{ name.owner, name.name, id.number, kind }, payload);
        }
        std.debug.print("updated #{d}\n", .{id.number});
    } else if (util.eql(sub, "remove")) {
        for (targets) |t| {
            const target = git_mod.IssueId.parse(t);
            try api.delete("/repos/{s}/{s}/issues/{d}/{s}/{d}", .{ name.owner, name.name, id.number, kind, target.number });
        }
        std.debug.print("updated #{d}\n", .{id.number});
    } else {
        util.fatal("unknown {s} command: {s}", .{ kind, sub });
    }
}
