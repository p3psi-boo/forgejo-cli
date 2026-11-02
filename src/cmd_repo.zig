const std = @import("std");
const App = @import("app.zig").App;
const cli = @import("cli.zig");
const util = @import("util.zig");
const git_mod = @import("git.zig");
const api_mod = @import("api.zig");
const style = @import("style.zig");

pub fn run(app: *App, args: *cli.ArgList) !void {
    const sub = args.takePositional() orelse {
        cli.help("repo");
        return;
    };
    if (util.eql(sub, "create")) {
        try create(app, args, null);
    } else if (util.eql(sub, "fork")) {
        try fork(app, args);
    } else if (util.eql(sub, "migrate")) {
        try migrate(app, args);
    } else if (util.eql(sub, "view")) {
        try view(app, args);
    } else if (util.eql(sub, "readme")) {
        try readme(app, args);
    } else if (util.eql(sub, "clone")) {
        try clone(app, args);
    } else if (util.eql(sub, "star")) {
        try star(app, args, true);
    } else if (util.eql(sub, "unstar")) {
        try star(app, args, false);
    } else if (util.eql(sub, "star-status")) {
        try starStatus(app, args);
    } else if (util.eql(sub, "watch")) {
        try watch(app, args, true);
    } else if (util.eql(sub, "unwatch")) {
        try watch(app, args, false);
    } else if (util.eql(sub, "watch-status")) {
        try watchStatus(app, args);
    } else if (util.eql(sub, "delete")) {
        try deleteRepo(app, args);
    } else if (util.eql(sub, "browse")) {
        try browse(app, args);
    } else if (util.eql(sub, "labels") or util.eql(sub, "label")) {
        try labels(app, args);
    } else if (util.eql(sub, "edit")) {
        try edit(app, args);
    } else if (util.eql(sub, "units") or util.eql(sub, "unit")) {
        try units(app, args);
    } else {
        util.fatal("unknown repo command: {s}", .{sub});
    }
}

fn takeRepo(args: *cli.ArgList) ?git_mod.RepoArg {
    const p = args.takePositional() orelse return null;
    return git_mod.RepoName.parseArg(p);
}

pub fn create(app: *App, args: *cli.ArgList, org: ?[]const u8) !void {
    const description = args.takeOpt("description", 'd');
    const private = args.takeFlag("private", 'P');
    const remote = args.takeOpt("remote", 'r');
    const push = args.takeFlag("push", 'p');
    const ssh_opt = args.takeOptMaybe("ssh", 'S');
    const name = args.expectPositional("NAME");
    args.rejectUnknownFlags();

    const info = try git_mod.getCurrent(app, app.host_flag, null, null);
    var api = app.apiFor(info.url);
    const ssh = if (ssh_opt) |v|
        if (v.len == 0) true else util.parseBool(v) orelse true
    else
        app.keys.usesSsh(git_mod.hostName(info.url));

    if (remote != null or push) {
        const remotes = try app.git.remotes();
        const upstream = remote orelse "origin";
        for (remotes) |r| {
            if (util.eql(r, upstream)) util.fatal("remote {s} already exists", .{upstream});
        }
    }

    const body = try util.jsonStringify(app.arena, .{
        .auto_init = false,
        .default_branch = "main",
        .description = description,
        .name = name,
        .private = private,
        .readme = "",
        .template = false,
    });
    const resp = if (org) |o|
        try api.post("/orgs/{s}/repos", .{o}, body)
    else
        try api.post("/user/repos", .{}, body);
    const repo = api.parse(api_mod.Repository, resp);
    std.debug.print("created {s}\n", .{repo.html_url orelse name});

    if (remote != null or push) {
        const upstream = remote orelse "origin";
        const url = if (ssh) repo.ssh_url else repo.clone_url;
        const u = url orelse util.fatal("repo does not have clone url", .{});
        _ = app.git.capture(&.{ "git", "remote", "add", upstream, u }) catch |err| {
            util.fatal("failed to add remote: {t}", .{err});
        };
        if (push) {
            const branch = try app.git.currentBranch() orelse util.fatal("detached HEAD", .{});
            const spec = try std.fmt.allocPrint(app.arena, "HEAD:refs/heads/{s}", .{branch});
            try app.git.forward(&.{ "git", "push", "-u", upstream, spec });
        }
    }
}

fn fork(app: *App, args: *cli.ArgList) !void {
    const new_name = args.takeOpt("name", null);
    const remote = args.takeOpt("remote", 'R');
    const repo = git_mod.RepoName.parseArg(args.expectPositional("REPO"));
    args.rejectUnknownFlags();
    const info = try git_mod.getCurrent(app, app.host_flag, repo, remote);
    var api = app.apiFor(info.url);
    const body = try util.jsonStringify(app.arena, .{ .name = new_name });
    const resp = try api.post("/repos/{s}/{s}/forks", .{ repo.owner, repo.name }, body);
    const created = api.parse(api_mod.Repository, resp);
    std.debug.print("forked {s}/{s} -> {s}\n", .{ repo.owner, repo.name, created.full_name orelse "?" });
}

fn migrate(app: *App, args: *cli.ArgList) !void {
    const mirror = args.takeFlag("mirror", 'm');
    const private = args.takeFlag("private", 'p');
    const clone_addr = args.expectPositional("CLONE-URL");
    const name_s = args.expectPositional("[OWNER]/NAME");
    args.rejectUnknownFlags();
    const info = try git_mod.getCurrent(app, app.host_flag, null, null);
    var api = app.apiFor(info.url);
    var owner: []const u8 = "";
    var repo_name: []const u8 = name_s;
    if (util.rsplitOnce(name_s, '/')) |p| {
        owner = p[0];
        repo_name = p[1];
    }
    const me = api.parse(api_mod.User, try api.get("/user", .{}));
    if (owner.len == 0) owner = me.login orelse util.fatal("not logged in", .{});
    const body = try util.jsonStringify(app.arena, .{
        .clone_addr = clone_addr,
        .repo_name = repo_name,
        .repo_owner = owner,
        .mirror = mirror,
        .private = private,
        .service = "git",
    });
    const resp = try api.post("/repos/migrate", .{}, body);
    const repo = api.parse(api_mod.Repository, resp);
    std.debug.print("migrated {s}\n", .{repo.html_url orelse repo_name});
}

fn view(app: *App, args: *cli.ArgList) !void {
    const remote = args.takeOpt("remote", 'R');
    const repo_arg = takeRepo(args);
    args.rejectUnknownFlags();
    const info = try git_mod.getCurrent(app, app.host_flag, repo_arg, remote);
    const name = git_mod.requireName(info);
    var api = app.apiFor(info.url);
    const repo = api.parse(api_mod.Repository, try api.get("/repos/{s}/{s}", .{ name.owner, name.name }));
    const r = app.render;
    std.debug.print("{s}{s}{s}\n", .{ r.bold, repo.full_name orelse "?", r.reset });
    if (repo.description) |d| if (d.len > 0) std.debug.print("{s}\n", .{d});
    if (repo.html_url) |u| std.debug.print("{s}\n", .{u});
    std.debug.print("private: {s}  archived: {s}  stars: {d}  forks: {d}\n", .{
        if (repo.private orelse false) "yes" else "no",
        if (repo.archived orelse false) "yes" else "no",
        repo.stars_count orelse 0,
        repo.forks_count orelse 0,
    });
    if (repo.default_branch) |b| std.debug.print("default branch: {s}\n", .{b});
}

fn readme(app: *App, args: *cli.ArgList) !void {
    const remote = args.takeOpt("remote", 'R');
    const repo_arg = takeRepo(args);
    args.rejectUnknownFlags();
    const info = try git_mod.getCurrent(app, app.host_flag, repo_arg, remote);
    const name = git_mod.requireName(info);
    var api = app.apiFor(info.url);
    const listing = api.parse([]api_mod.Contents, try api.get("/repos/{s}/{s}/contents", .{ name.owner, name.name }));
    const names = [_][]const u8{ "README.md", "README.MD", "README", "readme.md", "Readme.md" };
    for (listing) |entry| {
        const n = entry.name orelse continue;
        for (names) |want| {
            if (std.ascii.eqlIgnoreCase(n, want)) {
                const file = api.parse(api_mod.Contents, try api.get("/repos/{s}/{s}/contents/{s}", .{ name.owner, name.name, n }));
                const raw = file.content orelse util.fatal("empty README", .{});
                const decoded = decodeBase64(app, util.trim(raw)) catch util.fatal("failed to decode README", .{});
                std.debug.print("{s}", .{decoded});
                return;
            }
        }
    }
    util.fatal("no README found", .{});
}

fn decodeBase64(app: *App, s: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    // strip whitespace/newlines
    var compact: std.ArrayList(u8) = .empty;
    for (s) |c| if (c != '\n' and c != '\r' and c != ' ') try compact.append(app.arena, c);
    const size = try decoder.calcSizeForSlice(compact.items);
    const out = try app.arena.alloc(u8, size);
    try decoder.decode(out, compact.items);
    return out;
}

fn clone(app: *App, args: *cli.ArgList) !void {
    const ssh_opt = args.takeOptMaybe("ssh", 'S');
    const identity = args.takeOpt("identity-file", 'I');
    const repo = git_mod.RepoName.parseArg(args.expectPositional("REPO"));
    const path = args.takePositional();
    args.rejectUnknownFlags();
    const info = try git_mod.getCurrent(app, app.host_flag, repo, null);
    var api = app.apiFor(info.url);
    const remote = api.parse(api_mod.Repository, try api.get("/repos/{s}/{s}", .{ repo.owner, repo.name }));
    const ssh = if (ssh_opt) |v|
        if (v.len == 0) true else util.parseBool(v) orelse true
    else
        app.keys.usesSsh(git_mod.hostName(info.url));
    const url = (if (ssh) remote.ssh_url else remote.clone_url) orelse util.fatal("missing clone url", .{});
    const dest = path orelse repo.name;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(app.arena, &.{ "git", "clone" });
    if (identity) |id| {
        const cfg = try std.fmt.allocPrint(app.arena, "core.sshCommand=ssh -i {s}", .{id});
        try argv.appendSlice(app.arena, &.{ "-c", cfg });
    }
    try argv.appendSlice(app.arena, &.{ url, dest });
    try app.git.forward(argv.items);
    if (remote.fork orelse false) {
        if (remote.parent) |p| {
            if (p.html_url) |_| {
                // add upstream if we can
            }
        }
    }
}

fn star(app: *App, args: *cli.ArgList, add: bool) !void {
    const remote = args.takeOpt("remote", 'R');
    const repo_arg = takeRepo(args);
    args.rejectUnknownFlags();
    const info = try git_mod.getCurrent(app, app.host_flag, repo_arg, remote);
    const name = git_mod.requireName(info);
    var api = app.apiFor(info.url);
    if (add) {
        _ = try api.put("/user/starred/{s}/{s}", .{ name.owner, name.name }, "");
        std.debug.print("starred {s}/{s}\n", .{ name.owner, name.name });
    } else {
        try api.delete("/user/starred/{s}/{s}", .{ name.owner, name.name });
        std.debug.print("unstarred {s}/{s}\n", .{ name.owner, name.name });
    }
}

fn starStatus(app: *App, args: *cli.ArgList) !void {
    const list = args.takeFlag("list", null);
    const remote = args.takeOpt("remote", 'R');
    const repo_arg = takeRepo(args);
    args.rejectUnknownFlags();
    var api = app.apiFor((try git_mod.getCurrent(app, app.host_flag, repo_arg, remote)).url);
    if (list) {
        const repos = api.parse([]api_mod.Repository, try api.get("/user/starred", .{}));
        for (repos) |repo| std.debug.print("{s}\n", .{repo.full_name orelse "?"});
        return;
    }
    const info = try git_mod.getCurrent(app, app.host_flag, repo_arg, remote);
    const name = git_mod.requireName(info);
    _ = api.get("/user/starred/{s}/{s}", .{ name.owner, name.name }) catch {
        std.debug.print("not starred\n", .{});
        return;
    };
    std.debug.print("starred\n", .{});
}

fn watch(app: *App, args: *cli.ArgList, add: bool) !void {
    const remote = args.takeOpt("remote", 'R');
    const repo_arg = takeRepo(args);
    args.rejectUnknownFlags();
    const info = try git_mod.getCurrent(app, app.host_flag, repo_arg, remote);
    const name = git_mod.requireName(info);
    var api = app.apiFor(info.url);
    if (add) {
        _ = try api.put("/repos/{s}/{s}/subscription", .{ name.owner, name.name }, "");
        std.debug.print("watching {s}/{s}\n", .{ name.owner, name.name });
    } else {
        try api.delete("/repos/{s}/{s}/subscription", .{ name.owner, name.name });
        std.debug.print("unwatched {s}/{s}\n", .{ name.owner, name.name });
    }
}

fn watchStatus(app: *App, args: *cli.ArgList) !void {
    const list = args.takeFlag("list", null);
    const remote = args.takeOpt("remote", 'R');
    const repo_arg = takeRepo(args);
    args.rejectUnknownFlags();
    var api = app.apiFor((try git_mod.getCurrent(app, app.host_flag, repo_arg, remote)).url);
    if (list) {
        const repos = api.parse([]api_mod.Repository, try api.get("/user/subscriptions", .{}));
        for (repos) |repo| std.debug.print("{s}\n", .{repo.full_name orelse "?"});
        return;
    }
    const info = try git_mod.getCurrent(app, app.host_flag, repo_arg, remote);
    const name = git_mod.requireName(info);
    _ = api.get("/repos/{s}/{s}/subscription", .{ name.owner, name.name }) catch {
        std.debug.print("not watching\n", .{});
        return;
    };
    std.debug.print("watching\n", .{});
}

fn deleteRepo(app: *App, args: *cli.ArgList) !void {
    const repo = git_mod.RepoName.parseArg(args.expectPositional("REPO"));
    args.rejectUnknownFlags();
    const info = try git_mod.getCurrent(app, app.host_flag, repo, null);
    if (!try util.promptBool(app, try std.fmt.allocPrint(app.arena, "delete {s}/{s}?", .{ repo.owner, repo.name }), false)) {
        std.debug.print("cancelled\n", .{});
        return;
    }
    var api = app.apiFor(info.url);
    try api.delete("/repos/{s}/{s}", .{ repo.owner, repo.name });
    std.debug.print("deleted {s}/{s}\n", .{ repo.owner, repo.name });
}

fn browse(app: *App, args: *cli.ArgList) !void {
    const remote = args.takeOpt("remote", 'R');
    const repo_arg = takeRepo(args);
    args.rejectUnknownFlags();
    const info = try git_mod.getCurrent(app, app.host_flag, repo_arg, remote);
    const name = git_mod.requireName(info);
    const url = try std.fmt.allocPrint(app.arena, "{s}/{s}/{s}", .{ info.url, name.owner, name.name });
    try util.openUrl(app, url);
}

fn labels(app: *App, args: *cli.ArgList) !void {
    const remote = args.takeOpt("remote", 'R');
    const sub = args.takePositional() orelse "view";
    const info = try git_mod.getCurrent(app, app.host_flag, null, remote);
    const name = git_mod.requireName(info);
    var api = app.apiFor(info.url);
    if (util.eql(sub, "view")) {
        const archived = args.takeFlag("archived", 'a');
        args.rejectUnknownFlags();
        const all = api.parse([]api_mod.Label, try api.get("/repos/{s}/{s}/labels", .{ name.owner, name.name }));
        for (all) |label| {
            if ((label.is_archived orelse false) and !archived) continue;
            style.renderLabel(app.render, label.name orelse "???", label.color orelse "FFFFFF", label.exclusive orelse false);
            std.debug.print(" {d}\n", .{label.id orelse 0});
            if (label.description) |d| if (d.len > 0) std.debug.print("  {s}\n", .{d});
        }
    } else if (util.eql(sub, "create")) {
        const color = args.takeOpt("color", null);
        const description = args.takeOpt("description", 'd');
        const exclusive = args.takeFlag("exclusive", 'e');
        const archived = args.takeFlag("archived", 'a');
        const lname = args.expectPositional("NAME");
        const col = color orelse args.expectPositional("COLOR");
        args.rejectUnknownFlags();
        const body = try util.jsonStringify(app.arena, .{
            .name = lname,
            .color = util.stripPrefix(col, "#"),
            .description = description,
            .exclusive = exclusive,
            .is_archived = archived,
        });
        const created = api.parse(api_mod.Label, try api.post("/repos/{s}/{s}/labels", .{ name.owner, name.name }, body));
        std.debug.print("created label {s}\n", .{created.name orelse lname});
    } else if (util.eql(sub, "delete")) {
        const id = args.expectPositional("ID");
        args.rejectUnknownFlags();
        try api.delete("/repos/{s}/{s}/labels/{s}", .{ name.owner, name.name, id });
        std.debug.print("deleted label {s}\n", .{id});
    } else if (util.eql(sub, "edit")) {
        const new_name = args.takeOpt("name", 'n');
        const color = args.takeOpt("color", 'c');
        const description = args.takeOpt("description", 'd');
        const exclusive = args.takeBool("exclusive", 'e');
        const archived = args.takeBool("archived", 'a');
        const id = args.expectPositional("ID");
        args.rejectUnknownFlags();
        const body = try util.jsonStringify(app.arena, .{
            .name = new_name,
            .color = if (color) |c| util.stripPrefix(c, "#") else null,
            .description = description,
            .exclusive = exclusive,
            .is_archived = archived,
        });
        _ = try api.patch("/repos/{s}/{s}/labels/{s}", .{ name.owner, name.name, id }, body);
        std.debug.print("updated label {s}\n", .{id});
    } else {
        util.fatal("unknown labels command: {s}", .{sub});
    }
}

fn edit(app: *App, args: *cli.ArgList) !void {
    const archived = args.takeBool("archived", 'a');
    const default_branch = args.takeOpt("default-branch", null);
    const description = args.takeOpt("description", 'd');
    const name_new = args.takeOpt("name", null);
    const private = args.takeBool("private", 'p');
    const website = args.takeOpt("website", 'w');
    const remote = args.takeOpt("remote", 'R');
    const repo_arg = takeRepo(args);
    args.rejectUnknownFlags();
    const info = try git_mod.getCurrent(app, app.host_flag, repo_arg, remote);
    const name = git_mod.requireName(info);
    var api = app.apiFor(info.url);
    const body = try util.jsonStringify(app.arena, .{
        .archived = archived,
        .default_branch = default_branch,
        .description = description,
        .name = name_new,
        .private = private,
        .website = website,
    });
    _ = try api.patch("/repos/{s}/{s}", .{ name.owner, name.name }, body);
    std.debug.print("updated {s}/{s}\n", .{ name.owner, name.name });
}

fn units(app: *App, args: *cli.ArgList) !void {
    const remote = args.takeOpt("remote", 'R');
    const sub = args.expectPositional("UNIT");
    const enable = args.takeBool("enable", 'e');
    args.rejectUnknownFlags();
    const info = try git_mod.getCurrent(app, app.host_flag, null, remote);
    const name = git_mod.requireName(info);
    var api = app.apiFor(info.url);
    const on = enable orelse true;
    var body: []const u8 = "{}";
    if (util.eql(sub, "issues") or util.eql(sub, "issue")) {
        body = try util.jsonStringify(app.arena, .{ .has_issues = on });
    } else if (util.eql(sub, "prs") or util.eql(sub, "pr") or util.eql(sub, "pulls")) {
        body = try util.jsonStringify(app.arena, .{ .has_pull_requests = on });
    } else if (util.eql(sub, "wiki")) {
        body = try util.jsonStringify(app.arena, .{ .has_wiki = on });
    } else if (util.eql(sub, "actions")) {
        body = try util.jsonStringify(app.arena, .{ .has_actions = on });
    } else if (util.eql(sub, "packages")) {
        body = try util.jsonStringify(app.arena, .{ .has_packages = on });
    } else if (util.eql(sub, "projects")) {
        body = try util.jsonStringify(app.arena, .{ .has_projects = on });
    } else if (util.eql(sub, "releases")) {
        body = try util.jsonStringify(app.arena, .{ .has_releases = on });
    } else {
        util.fatal("unknown unit: {s}", .{sub});
    }
    _ = try api.patch("/repos/{s}/{s}", .{ name.owner, name.name }, body);
    std.debug.print("{s} {s} for {s}/{s}\n", .{ if (on) "enabled" else "disabled", sub, name.owner, name.name });
}
