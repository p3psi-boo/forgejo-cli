const std = @import("std");
const build_options = @import("build_options");
const App = @import("app.zig").App;
const cli = @import("cli.zig");
const util = @import("util.zig");
const git_mod = @import("git.zig");
const api_mod = @import("api.zig");
const style = @import("style.zig");
const cmd_issue = @import("cmd_issue.zig");

pub fn whoami(app: *App, args: *cli.ArgList) !void {
    const remote = args.takeOpt("remote", 'r');
    args.rejectUnknownFlags();
    const info = try git_mod.getCurrent(app, app.host_flag, null, remote);
    var api = app.apiFor(info.url);
    const me = api.parse(api_mod.User, try api.get("/user", .{}));
    std.debug.print("currently signed into {s}@{s}\n", .{ me.login orelse "?", git_mod.hostName(info.url) });
}

pub fn version(app: *App, args: *cli.ArgList) !void {
    const verbose = args.takeFlag("verbose", 'v');
    const check = args.takeFlag("check", null);
    args.rejectUnknownFlags();
    std.debug.print("fj v{s}\n", .{build_options.version});
    if (verbose) {
        std.debug.print("user agent: {s}\n", .{api_mod.user_agent});
        std.debug.print("build type: {s}\n", .{build_options.build_type});
        std.debug.print("    target: {s}\n", .{@tagName(@import("builtin").cpu.arch) ++ "-" ++ @tagName(@import("builtin").os.tag)});
    }
    if (check) {
        var api = api_mod.Api.init(app, "https://codeberg.org", null);
        const rel = api.parse(api_mod.Release, try api.get("/repos/forgejo-contrib/forgejo-cli/releases/latest", .{}));
        const latest_tag = rel.tag_name orelse "?";
        std.debug.print("latest: {s}\n", .{latest_tag});
    }
}

pub fn completion(app: *App, args: *cli.ArgList) !void {
    _ = app;
    const bin = args.takeOpt("bin-name", null) orelse "fj";
    const shell = args.expectPositional("SHELL");
    args.rejectUnknownFlags();
    if (util.eql(shell, "bash")) {
        std.debug.print(
            \\_{s}() {{
            \\  local cur prev
            \\  COMPREPLY=()
            \\  cur="${{COMP_WORDS[COMP_CWORD]}}"
            \\  local cmds="repo issue pr milestone wiki actions whoami auth release tag user org version completion"
            \\  if [[ $COMP_CWORD -eq 1 ]]; then
            \\    COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
            \\  fi
            \\}}
            \\complete -F _{s} {s}
            \\
        , .{ bin, bin, bin });
    } else if (util.eql(shell, "zsh")) {
        std.debug.print(
            \\#compdef {s}
            \\_arguments "1:command:(repo issue pr milestone wiki actions whoami auth release tag user org version completion)"
            \\
        , .{bin});
    } else if (util.eql(shell, "fish")) {
        std.debug.print(
            \\complete -c {s} -f
            \\complete -c {s} -n "__fish_use_subcommand" -a "repo issue pr milestone wiki actions whoami auth release tag user org version completion"
            \\
        , .{ bin, bin });
    } else if (util.eql(shell, "elvish") or util.eql(shell, "powershell") or util.eql(shell, "nushell")) {
        std.debug.print("# completions for {s} ({s})\n", .{ bin, shell });
    } else {
        util.fatal("unknown shell: {s} (bash|zsh|fish|elvish|powershell|nushell)", .{shell});
    }
}

pub fn milestone(app: *App, args: *cli.ArgList) !void {
    const remote = args.takeOpt("remote", 'R');
    const repo_flag = if (args.takeOpt("repo", 'r')) |s| git_mod.RepoName.parseArg(s) else null;
    const sub = args.takePositional() orelse util.fatal("usage: fj milestone <search|create|view|edit|delete>", .{});
    const info = try git_mod.getCurrent(app, app.host_flag, repo_flag, remote);
    const name = git_mod.requireName(info);
    var api = app.apiFor(info.url);
    if (util.eql(sub, "search")) {
        const state = args.takeOpt("state", null) orelse "open";
        const title = args.takeOpt("title", null);
        args.rejectUnknownFlags();
        var qs = api_mod.query(app.arena);
        try qs.add("state", state);
        try qs.addOpt("name", title);
        const all = api.parse([]api_mod.Milestone, try api.getQuery("/repos/{s}/{s}/milestones", .{ name.owner, name.name }, qs.slice()));
        for (all) |m| std.debug.print("{s} ({s}) open={d} closed={d}\n", .{
            m.title orelse "?",
            m.state orelse "?",
            m.open_issues orelse 0,
            m.closed_issues orelse 0,
        });
    } else if (util.eql(sub, "create")) {
        const description = args.takeOptMaybe("description", null);
        const state = args.takeOpt("state", null) orelse "open";
        const title = args.expectPositional("TITLE");
        args.rejectUnknownFlags();
        var desc: ?[]const u8 = null;
        if (description) |d| {
            var contents: []const u8 = if (d.len == 0) "" else d;
            if (d.len == 0) try util.editor(app, &contents, "md");
            desc = contents;
        }
        const payload = try util.jsonStringify(app.arena, .{ .title = title, .description = desc, .state = state });
        const created = api.parse(api_mod.Milestone, try api.post("/repos/{s}/{s}/milestones", .{ name.owner, name.name }, payload));
        std.debug.print("created milestone {s}\n", .{created.title orelse title});
    } else if (util.eql(sub, "view")) {
        const title = args.expectPositional("TITLE");
        args.rejectUnknownFlags();
        const id = try cmd_issue.lookupMilestone(app, &api, name, title);
        const m = api.parse(api_mod.Milestone, try api.get("/repos/{s}/{s}/milestones/{d}", .{ name.owner, name.name, id }));
        std.debug.print("{s}{s}{s} ({s})\n", .{ app.render.bold, m.title orelse "?", app.render.reset, m.state orelse "?" });
        if (m.description) |d| if (d.len > 0) style.markdown(app.render, d);
    } else if (util.eql(sub, "edit")) {
        const description = args.takeOpt("description", null);
        const state = args.takeOpt("state", null);
        const new_title = args.takeOpt("new-title", null);
        const title = args.expectPositional("TITLE");
        args.rejectUnknownFlags();
        const id = try cmd_issue.lookupMilestone(app, &api, name, title);
        const payload = try util.jsonStringify(app.arena, .{
            .title = new_title,
            .description = description,
            .state = state,
        });
        _ = try api.patch("/repos/{s}/{s}/milestones/{d}", .{ name.owner, name.name, id }, payload);
        std.debug.print("updated milestone {s}\n", .{title});
    } else if (util.eql(sub, "delete")) {
        const title = args.expectPositional("TITLE");
        args.rejectUnknownFlags();
        const id = try cmd_issue.lookupMilestone(app, &api, name, title);
        try api.delete("/repos/{s}/{s}/milestones/{d}", .{ name.owner, name.name, id });
        std.debug.print("deleted milestone {s}\n", .{title});
    } else {
        util.fatal("unknown milestone command: {s}", .{sub});
    }
}

pub fn wiki(app: *App, args: *cli.ArgList) !void {
    const remote = args.takeOpt("remote", 'R');
    const repo_flag = if (args.takeOpt("repo", 'r')) |s| git_mod.RepoName.parseArg(s) else null;
    const sub = args.takePositional() orelse util.fatal("usage: fj wiki <contents|view|clone|browse>", .{});
    const info = try git_mod.getCurrent(app, app.host_flag, repo_flag, remote);
    const name = git_mod.requireName(info);
    var api = app.apiFor(info.url);
    if (util.eql(sub, "contents")) {
        args.rejectUnknownFlags();
        const pages = api.parse([]api_mod.WikiPage, try api.get("/repos/{s}/{s}/wiki/pages", .{ name.owner, name.name }));
        for (pages) |p| std.debug.print("{s} {s}\n", .{ app.render.bullet, p.title orelse "?" });
    } else if (util.eql(sub, "view")) {
        const page = args.expectPositional("PAGE");
        args.rejectUnknownFlags();
        const p = api.parse(api_mod.WikiPage, try api.get("/repos/{s}/{s}/wiki/page/{s}", .{ name.owner, name.name, page }));
        std.debug.print("{s}{s}{s}\n\n", .{ app.render.bold, p.title orelse page, app.render.reset });
        if (p.content_base64) |b64| {
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(b64) catch 0;
            const out = try app.arena.alloc(u8, size);
            decoder.decode(out, b64) catch {};
            style.markdown(app.render, out);
        }
    } else if (util.eql(sub, "clone")) {
        const path = args.takeOpt("path", 'p');
        const ssh_opt = args.takeOptMaybe("ssh", 'S');
        args.rejectUnknownFlags();
        const repo = api.parse(api_mod.Repository, try api.get("/repos/{s}/{s}", .{ name.owner, name.name }));
        const ssh = if (ssh_opt) |v| (if (v.len == 0) true else util.parseBool(v) orelse true) else app.keys.usesSsh(git_mod.hostName(info.url));
        var clone_url = (if (ssh) repo.ssh_url else repo.clone_url) orelse util.fatal("missing clone url", .{});
        clone_url = try std.fmt.allocPrint(app.arena, "{s}.wiki.git", .{util.stripSuffix(util.stripSuffix(clone_url, ".git"), "/")});
        const dest = path orelse try std.fmt.allocPrint(app.arena, "{s}.wiki", .{name.name});
        try app.git.forward(&.{ "git", "clone", clone_url, dest });
    } else if (util.eql(sub, "browse")) {
        const page = args.expectPositional("PAGE");
        args.rejectUnknownFlags();
        const url = try std.fmt.allocPrint(app.arena, "{s}/{s}/{s}/wiki/{s}", .{ info.url, name.owner, name.name, page });
        try util.openUrl(app, url);
    } else {
        util.fatal("unknown wiki command: {s}", .{sub});
    }
}

pub fn tag(app: *App, args: *cli.ArgList) !void {
    const remote = args.takeOpt("remote", 'R');
    const repo_flag = if (args.takeOpt("repo", 'r')) |s| git_mod.RepoName.parseArg(s) else null;
    const sub = args.takePositional() orelse util.fatal("usage: fj tag <create|delete|list|view>", .{});
    const info = try git_mod.getCurrent(app, app.host_flag, repo_flag, remote);
    const name = git_mod.requireName(info);
    var api = app.apiFor(info.url);
    if (util.eql(sub, "create")) {
        const body = args.takeOptMaybe("body", 'b');
        const branch = args.takeOpt("branch", 'B');
        const tname = args.expectPositional("NAME");
        var message: ?[]const u8 = null;
        if (body) |b| {
            var contents: []const u8 = if (b.len == 0) "" else b;
            if (b.len == 0) try util.editor(app, &contents, "md");
            message = contents;
        }
        const payload = try util.jsonStringify(app.arena, .{
            .tag_name = tname,
            .message = message,
            .target = branch,
        });
        _ = try api.post("/repos/{s}/{s}/tags", .{ name.owner, name.name }, payload);
        std.debug.print("created tag {s}\n", .{tname});
    } else if (util.eql(sub, "delete")) {
        const tname = args.expectPositional("NAME");
        args.rejectUnknownFlags();
        try api.delete("/repos/{s}/{s}/tags/{s}", .{ name.owner, name.name, tname });
        std.debug.print("deleted tag {s}\n", .{tname});
    } else if (util.eql(sub, "list")) {
        const page = util.parseU32(args.takeOpt("page", 'p') orelse "1") orelse 1;
        args.rejectUnknownFlags();
        var qs = api_mod.query(app.arena);
        try qs.addInt("page", page);
        try qs.addInt("limit", 20);
        const tags = api.parse([]api_mod.Tag, try api.getQuery("/repos/{s}/{s}/tags", .{ name.owner, name.name }, qs.slice()));
        for (tags) |t| if (t.name) |n| std.debug.print("{s}\n", .{n});
    } else if (util.eql(sub, "view")) {
        const tname = args.expectPositional("NAME");
        args.rejectUnknownFlags();
        const t = api.parse(api_mod.Tag, try api.get("/repos/{s}/{s}/tags/{s}", .{ name.owner, name.name, tname }));
        std.debug.print("{s}{s}{s}\n{s}\n", .{ app.render.bold, t.name orelse tname, app.render.reset, t.id orelse "" });
        if (t.message) |m| {
            std.debug.print("\n", .{});
            style.markdown(app.render, m);
        }
    } else {
        util.fatal("unknown tag command: {s}", .{sub});
    }
}
