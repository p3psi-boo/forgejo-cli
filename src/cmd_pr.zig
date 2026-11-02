const std = @import("std");
const App = @import("app.zig").App;
const cli = @import("cli.zig");
const util = @import("util.zig");
const git_mod = @import("git.zig");
const api_mod = @import("api.zig");
const style = @import("style.zig");
const loc = @import("loc.zig");
const cmd_issue = @import("cmd_issue.zig");

pub fn run(app: *App, args: *cli.ArgList) !void {
    const remote = args.takeOpt("remote", 'R');
    const sub = args.takePositional() orelse {
        cli.help(app.arena, "pr");
        return;
    };
    if (util.eql(sub, "search")) {
        try cmd_issue.search(app, args, remote, "pulls");
    } else if (util.eql(sub, "create")) {
        try create(app, args, remote);
    } else if (util.eql(sub, "view")) {
        try view(app, args, remote);
    } else if (util.eql(sub, "status")) {
        try status(app, args, remote);
    } else if (util.eql(sub, "checkout")) {
        try checkout(app, args, remote);
    } else if (util.eql(sub, "comment")) {
        try comment(app, args, remote);
    } else if (util.eql(sub, "assign") or util.eql(sub, "unassign")) {
        try assign(app, args, remote, util.eql(sub, "assign"));
    } else if (util.eql(sub, "close")) {
        try closePr(app, args, remote);
    } else if (util.eql(sub, "merge")) {
        try merge(app, args, remote);
    } else if (util.eql(sub, "browse")) {
        try browse(app, args, remote);
    } else if (util.eql(sub, "edit")) {
        try edit(app, args, remote);
    } else if (util.eql(sub, "review")) {
        try review(app, args, remote);
    } else if (util.eql(sub, "depend")) {
        try depend(app, args, remote, false);
    } else if (util.eql(sub, "block")) {
        try depend(app, args, remote, true);
    } else {
        util.fatal("unknown pr command: {s}", .{sub});
    }
}

fn context(app: *App, args: *cli.ArgList, remote: ?[]const u8, maybe_id: ?git_mod.IssueId) !struct { git_mod.RepoInfo, git_mod.RepoName, *api_mod.Api, i64 } {
    const repo_flag = if (args.takeOpt("repo", 'r')) |s| git_mod.RepoName.parseArg(s) else null;
    const from_id = if (maybe_id) |id| id.repo else null;
    const info = try git_mod.getCurrent(app, app.host_flag, repo_flag orelse from_id, remote);
    const name = git_mod.requireName(info);
    const api_ptr = try app.arena.create(api_mod.Api);
    api_ptr.* = app.apiFor(info.url);
    const number = if (maybe_id) |id| id.number else try guessPr(app, api_ptr, name);
    return .{ info, name, api_ptr, number };
}

fn guessPr(app: *App, api: *api_mod.Api, name: git_mod.RepoName) !i64 {
    const branch = try app.git.currentBranch() orelse util.fatal("specify a PR number", .{});
    var qs = api_mod.query(app.arena);
    try qs.add("state", "open");
    try qs.add("head", try std.fmt.allocPrint(app.arena, "{s}:{s}", .{ name.owner, branch }));
    const prs = api.parse([]api_mod.PullRequest, try api.getQuery("/repos/{s}/{s}/pulls", .{ name.owner, name.name }, qs.slice()));
    if (prs.len == 0) util.fatal("could not guess PR from branch {s}; pass a number", .{branch});
    return prs[0].number orelse util.fatal("PR has no number", .{});
}

fn optionalId(args: *cli.ArgList) ?git_mod.IssueId {
    const p = args.takePositional() orelse return null;
    return git_mod.IssueId.parse(p);
}

fn create(app: *App, args: *cli.ArgList, remote: ?[]const u8) !void {
    const base = args.takeOpt("base", null);
    const head = args.takeOpt("head", null);
    const body_flag = args.takeOpt("body", null);
    const body_file = args.takeOpt("body-file", null);
    const autofill = args.takeFlag("autofill", 'A') or args.takeFlag("fill", null);
    const web = args.takeFlag("web", 'w');
    const agit = args.takeFlag("agit", 'a');
    const milestone = args.takeOpt("milestone", null);
    const repo_flag = if (args.takeOpt("repo", 'r')) |s| git_mod.RepoName.parseArg(s) else null;
    const title_opt = args.takePositional();
    args.rejectUnknownFlags();
    const info = try git_mod.getCurrent(app, app.host_flag, repo_flag, remote);
    const name = git_mod.requireName(info);
    var api = app.apiFor(info.url);
    if (web) {
        const url = try std.fmt.allocPrint(app.arena, "{s}/{s}/{s}/compare/{s}...{s}", .{
            info.url,
            name.owner,
            name.name,
            base orelse "main",
            head orelse (try app.git.currentBranch() orelse "HEAD"),
        });
        try util.openUrl(app, url);
        return;
    }
    if (agit) {
        const b = base orelse "main";
        const title = title_opt orelse util.fatal("title required for AGit PR", .{});
        var body: []const u8 = body_flag orelse "";
        if (body_file) |p| body = try util.readFile(app, p);
        const dest = try std.fmt.allocPrint(app.arena, "HEAD:refs/for/{s}", .{b});
        var extra: std.ArrayList([]const u8) = .empty;
        try extra.appendSlice(app.arena, &.{ "git", "push", "origin", dest, "-o", try std.fmt.allocPrint(app.arena, "title={s}", .{title}) });
        if (body.len > 0) try extra.appendSlice(app.arena, &.{ "-o", try std.fmt.allocPrint(app.arena, "description={s}", .{body}) });
        try app.git.forward(extra.items);
        return;
    }
    var title = title_opt orelse "";
    var body: []const u8 = body_flag orelse "";
    if (body_file) |p| body = try util.readFile(app, p);
    if (autofill) {
        const cur = try app.git.currentBranch() orelse "HEAD";
        const b = base orelse "main";
        const log = app.git.capture(&.{ "git", "log", "--format=%s", try std.fmt.allocPrint(app.arena, "{s}..{s}", .{ b, cur }) }) catch "";
        if (title.len == 0) {
            var it = std.mem.splitScalar(u8, log, '\n');
            title = it.next() orelse cur;
        }
        if (body.len == 0) body = log;
    }
    if (title.len == 0) util.fatal("title is required", .{});
    if (body_flag == null and body_file == null and !autofill) try util.editor(app, &body, "md");
    var milestone_id: ?i64 = null;
    if (milestone) |m| milestone_id = try cmd_issue.lookupMilestone(app, &api, name, m);
    const payload = try util.jsonStringify(app.arena, .{
        .title = title,
        .body = body,
        .base = base orelse "main",
        .head = head orelse (try app.git.currentBranch() orelse util.fatal("specify --head", .{})),
        .milestone = milestone_id,
    });
    const pr = api.parse(api_mod.PullRequest, try api.post("/repos/{s}/{s}/pulls", .{ name.owner, name.name }, payload));
    app.say("msg-pr-create-success", &.{
        loc.num("number", pr.number orelse 0),
        loc.str("title", pr.title orelse title),
    });
}

fn view(app: *App, args: *cli.ArgList, remote: ?[]const u8) !void {
    const maybe = optionalId(args);
    const what = args.takePositional() orelse "body";
    const ctx = try context(app, args, remote, maybe);
    const name = ctx[1];
    const api = ctx[2];
    const number = ctx[3];
    if (util.eql(what, "body")) {
        const pr = api.parse(api_mod.PullRequest, try api.get("/repos/{s}/{s}/pulls/{d}", .{ name.owner, name.name, number }));
        printPr(app, pr);
    } else if (util.eql(what, "comments")) {
        try cmd_issue.printComments(app, api, name, number, null);
    } else if (util.eql(what, "comment")) {
        const idx_s = args.expectPositional("IDX");
        const idx = util.parseU32(idx_s) orelse util.fatal("invalid index", .{});
        try cmd_issue.printComments(app, api, name, number, idx);
    } else if (util.eql(what, "labels")) {
        const pr = api.parse(api_mod.PullRequest, try api.get("/repos/{s}/{s}/pulls/{d}", .{ name.owner, name.name, number }));
        if (pr.labels) |labels| for (labels) |label| {
            style.renderLabel(app.render, label.name orelse "???", label.color orelse "FFFFFF", label.exclusive orelse false);
            std.debug.print("\n", .{});
        };
    } else if (util.eql(what, "assignees")) {
        const pr = api.parse(api_mod.PullRequest, try api.get("/repos/{s}/{s}/pulls/{d}", .{ name.owner, name.name, number }));
        if (pr.assignees) |as| for (as) |u| std.debug.print("{s}\n", .{u.login orelse "?"});
    } else if (util.eql(what, "diff")) {
        const patch = args.takeFlag("patch", 'p');
        args.rejectUnknownFlags();
        const path = if (patch)
            try std.fmt.allocPrint(app.arena, "/repos/{s}/{s}/pulls/{d}.patch", .{ name.owner, name.name, number })
        else
            try std.fmt.allocPrint(app.arena, "/repos/{s}/{s}/pulls/{d}.diff", .{ name.owner, name.name, number });
        const body = try api.get("{s}", .{path});
        std.debug.print("{s}", .{body});
    } else if (util.eql(what, "files")) {
        const File = struct { filename: ?[]const u8 = null, status: ?[]const u8 = null };
        const files = api.parse([]File, try api.get("/repos/{s}/{s}/pulls/{d}/files", .{ name.owner, name.name, number }));
        for (files) |f| std.debug.print("{s}\t{s}\n", .{ f.status orelse "?", f.filename orelse "?" });
    } else if (util.eql(what, "commits")) {
        const oneline = args.takeFlag("oneline", 'o');
        args.rejectUnknownFlags();
        const Commit = struct { sha: ?[]const u8 = null, commit: ?struct { message: ?[]const u8 = null } = null };
        const commits = api.parse([]Commit, try api.get("/repos/{s}/{s}/pulls/{d}/commits", .{ name.owner, name.name, number }));
        for (commits) |c| {
            const sha = c.sha orelse "";
            const msg = if (c.commit) |cm| cm.message orelse "" else "";
            var it = std.mem.splitScalar(u8, msg, '\n');
            const first = it.next() orelse "";
            if (oneline) {
                std.debug.print("{s} {s}\n", .{ sha[0..@min(sha.len, 7)], first });
            } else {
                std.debug.print("{s}\n{s}\n\n", .{ sha, msg });
            }
        }
    } else {
        util.fatal("unknown view command: {s}", .{what});
    }
}

fn printPr(app: *App, pr: api_mod.PullRequest) void {
    const r = app.render;
    const state = pr.state orelse "?";
    const author = if (pr.user) |u| u.login orelse "?" else "?";
    const merged = pr.merged orelse false;
    std.debug.print("{s}{s}{s} #{d} {s}{s}{s} by {s}\n", .{
        r.bold,
        pr.title orelse "?",
        r.reset,
        pr.number orelse 0,
        if (merged) r.magenta else if (util.eql(state, "open")) r.green else r.red,
        if (merged) "merged" else state,
        r.reset,
        author,
    });
    if (pr.base) |b| {
        if (pr.head) |h| {
            std.debug.print("{s} -> {s}\n", .{ h.ref orelse "?", b.ref orelse "?" });
        }
    }
    if (pr.body) |b| {
        if (b.len > 0) {
            std.debug.print("\n", .{});
            style.markdown(r, b);
        }
    }
}

fn status(app: *App, args: *cli.ArgList, remote: ?[]const u8) !void {
    const wait = args.takeFlag("wait", null);
    const maybe = optionalId(args);
    const ctx = try context(app, args, remote, maybe);
    args.rejectUnknownFlags();
    const name = ctx[1];
    const api = ctx[2];
    const number = ctx[3];
    const pr = api.parse(api_mod.PullRequest, try api.get("/repos/{s}/{s}/pulls/{d}", .{ name.owner, name.name, number }));
    const sha = if (pr.head) |h| h.sha orelse util.fatal("no head sha", .{}) else util.fatal("no head", .{});
    while (true) {
        const Status = struct {
            state: ?[]const u8 = null,
            statuses: ?[]struct { context: ?[]const u8 = null, state: ?[]const u8 = null, description: ?[]const u8 = null } = null,
        };
        const st = api.parse(Status, try api.get("/repos/{s}/{s}/commits/{s}/status", .{ name.owner, name.name, sha }));
        std.debug.print("combined: {s}\n", .{st.state orelse "unknown"});
        if (st.statuses) |ss| for (ss) |s| {
            std.debug.print("  {s}: {s} {s}\n", .{ s.context orelse "?", s.state orelse "?", s.description orelse "" });
        };
        const done = if (st.state) |s| util.eql(s, "success") or util.eql(s, "failure") or util.eql(s, "error") else true;
        if (!wait or done) break;
        std.Io.sleep(app.io, .fromSeconds(5), .awake) catch {};
    }
}

fn checkout(app: *App, args: *cli.ArgList, remote: ?[]const u8) !void {
    const branch_name = args.takeOpt("branch-name", null);
    const ssh_opt = args.takeOptMaybe("ssh", 'S');
    _ = ssh_opt;
    const id_s = args.expectPositional("ID");
    args.rejectUnknownFlags();
    const parent = std.mem.startsWith(u8, id_s, "^");
    const num = util.parseI64(util.stripPrefix(id_s, "^")) orelse util.fatal("invalid PR number", .{});
    const info = try git_mod.getCurrent(app, app.host_flag, null, remote);
    const name = git_mod.requireName(info);
    var api = app.apiFor(info.url);
    const pr = api.parse(api_mod.PullRequest, try api.get("/repos/{s}/{s}/pulls/{d}", .{ name.owner, name.name, num }));
    const local = branch_name orelse try std.fmt.allocPrint(app.arena, "pr-{d}", .{num});
    const head_ref = if (pr.head) |h| h.ref orelse "HEAD" else "HEAD";
    _ = parent;
    const fetch_ref = try std.fmt.allocPrint(app.arena, "pull/{d}/head:{s}", .{ num, local });
    const remote_name = info.remote_name orelse "origin";
    try app.git.forward(&.{ "git", "fetch", remote_name, fetch_ref });
    try app.git.forward(&.{ "git", "checkout", local });
    _ = head_ref;
}

fn comment(app: *App, args: *cli.ArgList, remote: ?[]const u8) !void {
    const body_file = args.takeOpt("body-file", null);
    const maybe = optionalId(args);
    var body = args.takePositional();
    const ctx = try context(app, args, remote, maybe);
    if (body_file) |p| body = try util.readFile(app, p);
    var contents = body orelse "";
    if (body == null) try util.editor(app, &contents, "md");
    const payload = try util.jsonStringify(app.arena, .{ .body = contents });
    _ = try ctx[2].post("/repos/{s}/{s}/issues/{d}/comments", .{ ctx[1].owner, ctx[1].name, ctx[3] }, payload);
    std.debug.print("commented on #{d}\n", .{ctx[3]});
}

fn assign(app: *App, args: *cli.ArgList, remote: ?[]const u8, add: bool) !void {
    const pr_flag = if (args.takeOpt("pr", 'p')) |s| git_mod.IssueId.parse(s) else null;
    const users = try args.remainingPositionals();
    const ctx = try context(app, args, remote, pr_flag);
    if (users.len == 0) util.fatal("specify at least one user", .{});
    const issue = ctx[2].parse(api_mod.Issue, try ctx[2].get("/repos/{s}/{s}/issues/{d}", .{ ctx[1].owner, ctx[1].name, ctx[3] }));
    var list: std.ArrayList([]const u8) = .empty;
    if (issue.assignees) |as| for (as) |u| if (u.login) |l| try list.append(app.arena, l);
    if (add) {
        for (users) |u| try list.append(app.arena, u);
    } else {
        var kept: std.ArrayList([]const u8) = .empty;
        outer: for (list.items) |existing| {
            for (users) |u| if (util.eql(existing, u)) continue :outer;
            try kept.append(app.arena, existing);
        }
        list = kept;
    }
    const payload = try util.jsonStringify(app.arena, .{ .assignees = list.items });
    _ = try ctx[2].patch("/repos/{s}/{s}/issues/{d}", .{ ctx[1].owner, ctx[1].name, ctx[3] }, payload);
}

fn closePr(app: *App, args: *cli.ArgList, remote: ?[]const u8) !void {
    const with_msg = args.takeOptMaybe("with-msg", 'w');
    const maybe = optionalId(args);
    const ctx = try context(app, args, remote, maybe);
    if (with_msg) |msg| {
        var contents: []const u8 = if (msg.len == 0) "" else msg;
        if (msg.len == 0) try util.editor(app, &contents, "md");
        if (contents.len > 0) {
            const payload = try util.jsonStringify(app.arena, .{ .body = contents });
            _ = try ctx[2].post("/repos/{s}/{s}/issues/{d}/comments", .{ ctx[1].owner, ctx[1].name, ctx[3] }, payload);
        }
    }
    const payload = try util.jsonStringify(app.arena, .{ .state = "closed" });
    _ = try ctx[2].patch("/repos/{s}/{s}/pulls/{d}", .{ ctx[1].owner, ctx[1].name, ctx[3] }, payload);
    std.debug.print("closed #{d}\n", .{ctx[3]});
}

fn merge(app: *App, args: *cli.ArgList, remote: ?[]const u8) !void {
    const method = args.takeOpt("method", 'M') orelse "merge";
    const delete = args.takeFlag("delete", 'd');
    const title = args.takeOpt("title", 't');
    const message = args.takeOptMaybe("message", 'm');
    const maybe = optionalId(args);
    const ctx = try context(app, args, remote, maybe);
    args.rejectUnknownFlags();
    const do_method = if (util.eql(method, "fast-forward-only")) "fast-forward-only" else method;
    var msg: ?[]const u8 = null;
    if (message) |m| {
        var contents: []const u8 = if (m.len == 0) "" else m;
        if (m.len == 0) try util.editor(app, &contents, "md");
        msg = contents;
    }
    const payload = try util.jsonStringify(app.arena, .{
        .Do = do_method,
        .MergeMessageField = msg,
        .MergeTitleField = title,
        .delete_branch_after_merge = delete,
    });
    _ = try ctx[2].post("/repos/{s}/{s}/pulls/{d}/merge", .{ ctx[1].owner, ctx[1].name, ctx[3] }, payload);
    const merged = ctx[2].parse(api_mod.PullRequest, try ctx[2].get("/repos/{s}/{s}/pulls/{d}", .{ ctx[1].owner, ctx[1].name, ctx[3] }));
    app.say("msg-pr-merge-success", &.{
        loc.num("number", ctx[3]),
        loc.str("title", merged.title orelse ""),
        loc.str("base_branch", if (merged.base) |b| b.ref orelse "" else ""),
    });
}

fn browse(app: *App, args: *cli.ArgList, remote: ?[]const u8) !void {
    const maybe = optionalId(args);
    const ctx = try context(app, args, remote, maybe);
    const pr = ctx[2].parse(api_mod.PullRequest, try ctx[2].get("/repos/{s}/{s}/pulls/{d}", .{ ctx[1].owner, ctx[1].name, ctx[3] }));
    try util.openUrl(app, pr.html_url orelse util.fatal("no html url", .{}));
}

fn edit(app: *App, args: *cli.ArgList, remote: ?[]const u8) !void {
    const maybe = optionalId(args);
    const what = args.expectPositional("FIELD");
    const ctx = try context(app, args, remote, maybe);
    if (util.eql(what, "title") or util.eql(what, "body")) {
        var val = args.takePositional() orelse "";
        if (val.len == 0) try util.editor(app, &val, if (util.eql(what, "body")) "md" else null);
        const payload = if (util.eql(what, "title"))
            try util.jsonStringify(app.arena, .{ .title = val })
        else
            try util.jsonStringify(app.arena, .{ .body = val });
        _ = try ctx[2].patch("/repos/{s}/{s}/pulls/{d}", .{ ctx[1].owner, ctx[1].name, ctx[3] }, payload);
    } else if (util.eql(what, "labels")) {
        const add = try args.takeAll("add", 'a');
        const rm = try args.takeAll("rm", 'r');
        try cmd_issue.editLabels(app, ctx[2], ctx[1], ctx[3], add, rm);
    } else if (util.eql(what, "milestone")) {
        const unset = args.takeFlag("unset", 'u');
        const title = args.takePositional();
        const mid: ?i64 = if (unset) 0 else if (title) |t| try cmd_issue.lookupMilestone(app, ctx[2], ctx[1], t) else util.fatal("specify a milestone or --unset", .{});
        const payload = try util.jsonStringify(app.arena, .{ .milestone = mid });
        _ = try ctx[2].patch("/repos/{s}/{s}/pulls/{d}", .{ ctx[1].owner, ctx[1].name, ctx[3] }, payload);
    } else {
        util.fatal("unknown edit field: {s}", .{what});
    }
    std.debug.print("updated #{d}\n", .{ctx[3]});
}

fn review(app: *App, args: *cli.ArgList, remote: ?[]const u8) !void {
    const maybe = optionalId(args);
    const sub = args.takePositional() orelse "list";
    const ctx = try context(app, args, remote, maybe);
    if (util.eql(sub, "list")) {
        const comments = args.takeFlag("comments", 'c');
        args.rejectUnknownFlags();
        const Review = struct { user: ?api_mod.User = null, state: ?[]const u8 = null, body: ?[]const u8 = null };
        const reviews = ctx[2].parse([]Review, try ctx[2].get("/repos/{s}/{s}/pulls/{d}/reviews", .{ ctx[1].owner, ctx[1].name, ctx[3] }));
        for (reviews) |rv| {
            const who = if (rv.user) |u| u.login orelse "?" else "?";
            std.debug.print("{s} {s}\n", .{ who, rv.state orelse "" });
            if (comments) if (rv.body) |b| if (b.len > 0) style.markdown(app.render, b);
        }
    } else if (util.eql(sub, "request")) {
        const teams = try args.takeAll("team", 't');
        const reviewers = try args.remainingPositionals();
        const payload = try util.jsonStringify(app.arena, .{
            .reviewers = reviewers,
            .team_reviewers = teams,
        });
        _ = try ctx[2].post("/repos/{s}/{s}/pulls/{d}/requested_reviewers", .{ ctx[1].owner, ctx[1].name, ctx[3] }, payload);
        std.debug.print("requested review on #{d}\n", .{ctx[3]});
    } else {
        util.fatal("unknown review command: {s}", .{sub});
    }
}

fn depend(app: *App, args: *cli.ArgList, remote: ?[]const u8, blocking: bool) !void {
    const sub = args.expectPositional("ACTION");
    const pr_flag = if (args.takeOpt("pr", 'p')) |s| git_mod.IssueId.parse(s) else null;
    const ctx = try context(app, args, remote, pr_flag);
    const kind: []const u8 = if (blocking) "blocks" else "dependencies";
    if (util.eql(sub, "list")) {
        const issues = ctx[2].parse([]api_mod.Issue, try ctx[2].get("/repos/{s}/{s}/issues/{d}/{s}", .{ ctx[1].owner, ctx[1].name, ctx[3], kind }));
        for (issues) |issue| std.debug.print("#{d} {s}\n", .{ issue.number orelse 0, issue.title orelse "?" });
        return;
    }
    const targets = try args.remainingPositionals();
    if (util.eql(sub, "add")) {
        for (targets) |t| {
            const target = git_mod.IssueId.parse(t);
            const payload = try util.jsonStringify(app.arena, .{ .index = target.number });
            _ = try ctx[2].post("/repos/{s}/{s}/issues/{d}/{s}", .{ ctx[1].owner, ctx[1].name, ctx[3], kind }, payload);
        }
    } else if (util.eql(sub, "remove")) {
        for (targets) |t| {
            const target = git_mod.IssueId.parse(t);
            try ctx[2].delete("/repos/{s}/{s}/issues/{d}/{s}/{d}", .{ ctx[1].owner, ctx[1].name, ctx[3], kind, target.number });
        }
    } else util.fatal("unknown command: {s}", .{sub});
}
