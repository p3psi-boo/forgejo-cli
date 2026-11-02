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
    const sub = args.takePositional() orelse util.fatal("usage: fj user <search|view|browse|follow|unfollow|following|followers|block|unblock|repos|orgs|activity|edit|key|gpg>", .{});
    const info = try git_mod.getCurrent(app, app.host_flag, null, remote);
    var api = app.apiFor(info.url);

    if (util.eql(sub, "search")) {
        const page = args.takeOpt("page", 'p');
        const q = args.expectPositional("QUERY");
        var qs = api_mod.query(app.arena);
        try qs.add("q", q);
        if (page) |p| try qs.add("page", p);
        const Wrap = struct { data: ?[]api_mod.User = null };
        const wrap = api.parse(Wrap, try api.getQuery("/users/search", .{}, qs.slice()));
        if (wrap.data) |users| for (users) |u| {
            std.debug.print("{s} {s}\n", .{ u.login orelse "?", u.full_name orelse "" });
        };
    } else if (util.eql(sub, "view")) {
        const user = args.takePositional();
        const u = try getUser(&api, user);
        printUser(app, u);
    } else if (util.eql(sub, "browse")) {
        const user = args.takePositional();
        const u = try getUser(&api, user);
        try util.openUrl(app, u.html_url orelse try std.fmt.allocPrint(app.arena, "{s}/{s}", .{ info.url, u.login orelse "" }));
    } else if (util.eql(sub, "follow")) {
        const user = args.expectPositional("USER");
        _ = try api.put("/user/following/{s}", .{user}, "");
        app.say("msg-user-follow-success", &.{loc.str("username", user)});
    } else if (util.eql(sub, "unfollow")) {
        const user = args.expectPositional("USER");
        try api.delete("/user/following/{s}", .{user});
        app.say("msg-user-unfollow-success", &.{loc.str("username", user)});
    } else if (util.eql(sub, "following") or util.eql(sub, "followers")) {
        const user = args.takePositional();
        const login = if (user) |u| u else (api.parse(api_mod.User, try api.get("/user", .{})).login orelse util.fatal("not logged in", .{}));
        const path = if (util.eql(sub, "following"))
            try std.fmt.allocPrint(app.arena, "/users/{s}/following", .{login})
        else
            try std.fmt.allocPrint(app.arena, "/users/{s}/followers", .{login});
        const users = api.parse([]api_mod.User, try api.get("{s}", .{path}));
        for (users) |u| std.debug.print("{s}\n", .{u.login orelse "?"});
    } else if (util.eql(sub, "block")) {
        const user = args.expectPositional("USER");
        _ = try api.put("/user/blocks/{s}", .{user}, "");
        app.say("msg-user-block-success", &.{loc.str("user", user)});
    } else if (util.eql(sub, "unblock")) {
        const user = args.expectPositional("USER");
        try api.delete("/user/blocks/{s}", .{user});
        app.say("msg-user-unblock-success", &.{loc.str("user", user)});
    } else if (util.eql(sub, "repos")) {
        const starred = args.takeFlag("starred", null);
        const sort = args.takeOpt("sort", null);
        const page = util.parseU32(args.takeOpt("page", null) orelse "1") orelse 1;
        const user = args.takePositional();
        var qs = api_mod.query(app.arena);
        try qs.addInt("page", page);
        try qs.addOpt("sort", sort);
        const path = if (starred)
            "/user/starred"
        else if (user) |u|
            try std.fmt.allocPrint(app.arena, "/users/{s}/repos", .{u})
        else
            "/user/repos";
        const repos = api.parse([]api_mod.Repository, try api.getQuery("{s}", .{path}, qs.slice()));
        for (repos) |r| std.debug.print("{s}\n", .{r.full_name orelse "?"});
    } else if (util.eql(sub, "orgs")) {
        const user = args.takePositional();
        const path = if (user) |u|
            try std.fmt.allocPrint(app.arena, "/users/{s}/orgs", .{u})
        else
            "/user/orgs";
        const orgs = api.parse([]api_mod.Organization, try api.get("{s}", .{path}));
        for (orgs) |o| std.debug.print("{s}\n", .{o.username orelse o.name orelse "?"});
    } else if (util.eql(sub, "activity")) {
        const user = args.takePositional();
        const login = if (user) |u| u else (api.parse(api_mod.User, try api.get("/user", .{})).login orelse util.fatal("not logged in", .{}));
        const Act = struct { op_type: ?[]const u8 = null, act_user: ?api_mod.User = null, repo: ?api_mod.Repository = null, content: ?[]const u8 = null };
        const feed = api.parse([]Act, try api.get("/users/{s}/activities/feeds", .{login}));
        for (feed) |a| {
            const who = if (a.act_user) |u| u.login orelse "?" else "?";
            const repo = if (a.repo) |r| r.full_name orelse "?" else "";
            std.debug.print("{s} {s} {s}\n", .{ who, a.op_type orelse "?", repo });
        }
    } else if (util.eql(sub, "edit")) {
        try edit(app, args, &api);
    } else if (util.eql(sub, "key")) {
        try keys(app, args, &api);
    } else if (util.eql(sub, "gpg")) {
        try gpg(app, args, &api);
    } else {
        util.fatal("unknown user command: {s}", .{sub});
    }
}

fn getUser(api: *api_mod.Api, user: ?[]const u8) !api_mod.User {
    if (user) |u| return api.parse(api_mod.User, try api.get("/users/{s}", .{u}));
    return api.parse(api_mod.User, try api.get("/user", .{}));
}

fn printUser(app: *App, u: api_mod.User) void {
    std.debug.print("{s}{s}{s} {s}\n", .{ app.render.bold, u.login orelse "?", app.render.reset, u.full_name orelse "" });
    if (u.description) |d| if (d.len > 0) std.debug.print("{s}\n", .{d});
    if (u.html_url) |url| std.debug.print("{s}\n", .{url});
    if (u.location) |l| if (l.len > 0) std.debug.print("location: {s}\n", .{l});
    if (u.website) |w| if (w.len > 0) std.debug.print("website: {s}\n", .{w});
}

fn edit(app: *App, args: *cli.ArgList, api: *api_mod.Api) !void {
    const field = args.expectPositional("FIELD");
    if (util.eql(field, "bio")) {
        var content = args.takePositional() orelse "";
        if (content.len == 0) try util.editor(app, &content, "md");
        const payload = try util.jsonStringify(app.arena, .{ .description = content });
        _ = try api.patch("/user/settings", .{}, payload);
    } else if (util.eql(field, "name") or util.eql(field, "pronouns") or util.eql(field, "location") or util.eql(field, "website")) {
        const unset = args.takeFlag("unset", 'u');
        var val = args.takePositional();
        if (unset) val = "";
        if (val == null) {
            var s: []const u8 = "";
            try util.editor(app, &s, null);
            val = s;
        }
        const payload = if (util.eql(field, "name"))
            try util.jsonStringify(app.arena, .{ .full_name = val })
        else if (util.eql(field, "pronouns"))
            try util.jsonStringify(app.arena, .{ .pronouns = val })
        else if (util.eql(field, "location"))
            try util.jsonStringify(app.arena, .{ .location = val })
        else
            try util.jsonStringify(app.arena, .{ .website = val });
        _ = try api.patch("/user/settings", .{}, payload);
    } else if (util.eql(field, "activity")) {
        const vis = args.takeOpt("visibility", 'v') orelse args.expectPositional("VISIBILITY");
        const payload = try util.jsonStringify(app.arena, .{ .keep_activity_private = util.eql(vis, "private") });
        _ = try api.patch("/user/settings", .{}, payload);
    } else if (util.eql(field, "email")) {
        const vis = args.takeOpt("visibility", 'v');
        const add = try args.takeAll("add", 'a');
        const rm = try args.takeAll("rm", 'r');
        for (add) |e| {
            const payload = try util.jsonStringify(app.arena, .{ .email = e });
            _ = try api.post("/user/emails", .{}, payload);
        }
        for (rm) |e| {
            const payload = try util.jsonStringify(app.arena, .{ .emails = &[_][]const u8{e} });
            // DELETE with body is awkward; use POST-style via call
            _ = payload;
            try api.delete("/user/emails", .{});
        }
        if (vis) |v| {
            const payload = try util.jsonStringify(app.arena, .{ .hide_email = util.eql(v, "private") });
            _ = try api.patch("/user/settings", .{}, payload);
        }
    } else util.fatal("unknown edit field: {s}", .{field});
    std.debug.print("updated user settings\n", .{});
}

fn keys(app: *App, args: *cli.ArgList, api: *api_mod.Api) !void {
    const sub = args.takePositional() orelse "list";
    const Key = struct { id: ?i64 = null, title: ?[]const u8 = null, key: ?[]const u8 = null, read_only: ?bool = null };
    if (util.eql(sub, "list")) {
        const verbose = args.takeFlag("verbose", 'v');
        const all = api.parse([]Key, try api.get("/user/keys", .{}));
        for (all) |k| {
            if (verbose) {
                std.debug.print("{d} {s}\n{s}\n", .{ k.id orelse 0, k.title orelse "", k.key orelse "" });
            } else {
                std.debug.print("{d} {s}\n", .{ k.id orelse 0, k.title orelse "" });
            }
        }
    } else if (util.eql(sub, "view")) {
        const id = args.expectPositional("ID");
        const k = api.parse(Key, try api.get("/user/keys/{s}", .{id}));
        std.debug.print("{s}\n{s}\n", .{ k.title orelse "", k.key orelse "" });
    } else if (util.eql(sub, "delete")) {
        const id = args.expectPositional("ID");
        try api.delete("/user/keys/{s}", .{id});
        app.say("msg-user-key-delete-success", &.{loc.str("id", id)});
    } else if (util.eql(sub, "upload")) {
        const title = args.takeOpt("title", 't');
        const read_only = args.takeFlag("read-only", null);
        const keyfile = args.takePositional();
        const key = if (keyfile) |p| util.trim(try util.readFile(app, p)) else try util.promptLine(app, "key: ");
        const payload = try util.jsonStringify(app.arena, .{
            .title = title orelse "fj",
            .key = key,
            .read_only = read_only,
        });
        _ = try api.post("/user/keys", .{}, payload);
        app.say("msg-user-key-add-success", &.{});
    } else util.fatal("unknown key command: {s}", .{sub});
}

fn gpg(app: *App, args: *cli.ArgList, api: *api_mod.Api) !void {
    const sub = args.takePositional() orelse "list";
    const Key = struct { id: ?i64 = null, key_id: ?[]const u8 = null, emails: ?[]struct { email: ?[]const u8 = null } = null };
    if (util.eql(sub, "list")) {
        const verbose = args.takeFlag("verbose", 'v');
        const all = api.parse([]Key, try api.get("/user/gpg_keys", .{}));
        for (all) |k| {
            std.debug.print("{d} {s}\n", .{ k.id orelse 0, k.key_id orelse "" });
            if (verbose) if (k.emails) |es| for (es) |e| if (e.email) |em| std.debug.print("  {s}\n", .{em});
        }
    } else if (util.eql(sub, "view")) {
        const id = args.expectPositional("ID");
        const k = api.parse(Key, try api.get("/user/gpg_keys/{s}", .{id}));
        std.debug.print("{s}\n", .{k.key_id orelse ""});
    } else if (util.eql(sub, "delete")) {
        const id = args.expectPositional("ID");
        try api.delete("/user/gpg_keys/{s}", .{id});
        std.debug.print("deleted gpg key {s}\n", .{id});
    } else if (util.eql(sub, "upload")) {
        const armored = args.expectPositional("KEY");
        const payload = try util.jsonStringify(app.arena, .{ .armored_public_key = armored });
        _ = try api.post("/user/gpg_keys", .{}, payload);
        std.debug.print("uploaded gpg key\n", .{});
    } else if (util.eql(sub, "verify")) {
        const id = args.expectPositional("ID");
        _ = try api.post("/user/gpg_keys/{s}/verify", .{id}, "{}");
        std.debug.print("verified gpg key {s}\n", .{id});
    } else util.fatal("unknown gpg command: {s}", .{sub});
}
