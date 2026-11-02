const std = @import("std");
const App = @import("app.zig").App;
const cli = @import("cli.zig");
const util = @import("util.zig");
const git_mod = @import("git.zig");
const api_mod = @import("api.zig");
const style = @import("style.zig");
const loc = @import("loc.zig");
const cmd_repo = @import("cmd_repo.zig");

pub fn run(app: *App, args: *cli.ArgList) !void {
    const remote = args.takeOpt("remote", 'R');
    const sub = args.takePositional() orelse util.fatal("usage: fj org <list|view|create|edit|activity|members|visibility|team|label|repo>", .{});
    const info = try git_mod.getCurrent(app, app.host_flag, null, remote);
    var api = app.apiFor(info.url);

    if (util.eql(sub, "list")) {
        const page = util.parseU32(args.takeOpt("page", 'p') orelse "1") orelse 1;
        const only_member = args.takeFlag("only-member-of", 'o');
        args.rejectUnknownFlags();
        const orgs = if (only_member)
            api.parse([]api_mod.Organization, try api.get("/user/orgs", .{}))
        else blk: {
            var qs = api_mod.query(app.arena);
            try qs.addInt("page", page);
            break :blk api.parse([]api_mod.Organization, try api.getQuery("/orgs", .{}, qs.slice()));
        };
        if (orgs.len == 0) app.say("msg-org-list-no_results", &.{});
        for (orgs) |o| {
            std.debug.print("{s} {s}{s}{s}\n", .{ app.render.bullet, app.render.bold, o.username orelse o.name orelse "?", app.render.reset });
        }
    } else if (util.eql(sub, "view")) {
        const oname = args.expectPositional("NAME");
        const org = api.parse(api_mod.Organization, try api.get("/orgs/{s}", .{oname}));
        printOrg(app, org);
    } else if (util.eql(sub, "create")) {
        const full_name = args.takeOpt("full-name", 'f');
        const description = args.takeOpt("description", 'd');
        const email = args.takeOpt("email", 'e');
        const location = args.takeOpt("location", 'l');
        const website = args.takeOpt("website", 'w');
        const visibility = args.takeOpt("visibility", 'v');
        const oname = args.expectPositional("NAME");
        validateOrgName(oname);
        const payload = try util.jsonStringify(app.arena, .{
            .username = oname,
            .full_name = full_name,
            .description = description,
            .email = email,
            .location = location,
            .website = website,
            .visibility = visibility,
        });
        const org = api.parse(api_mod.Organization, try api.post("/orgs", .{}, payload));
        app.say("msg-org-create-success", &.{
            loc.str("name", org.username orelse oname),
            loc.opt("full_name", full_name),
            loc.str("visibility", visibility orelse "public"),
        });
    } else if (util.eql(sub, "edit")) {
        const full_name = args.takeOpt("full-name", 'f');
        const description = args.takeOpt("description", 'd');
        const email = args.takeOpt("email", 'e');
        const location = args.takeOpt("location", 'l');
        const website = args.takeOpt("website", 'w');
        const visibility = args.takeOpt("visibility", 'v');
        const oname = args.expectPositional("NAME");
        const payload = try util.jsonStringify(app.arena, .{
            .full_name = full_name,
            .description = description,
            .email = email,
            .location = location,
            .website = website,
            .visibility = visibility,
        });
        _ = try api.patch("/orgs/{s}", .{oname}, payload);
        std.debug.print("updated organization {s}\n", .{oname});
    } else if (util.eql(sub, "activity")) {
        const oname = args.expectPositional("NAME");
        const Act = struct { op_type: ?[]const u8 = null, act_user: ?api_mod.User = null, repo: ?api_mod.Repository = null };
        const feed = api.parse([]Act, try api.get("/orgs/{s}/activities/feeds", .{oname}));
        for (feed) |a| {
            const who = if (a.act_user) |u| u.login orelse "?" else "?";
            const repo = if (a.repo) |r| r.full_name orelse "?" else "";
            std.debug.print("{s} {s} {s}\n", .{ who, a.op_type orelse "?", repo });
        }
    } else if (util.eql(sub, "members")) {
        const page = util.parseU32(args.takeOpt("page", 'p') orelse "1") orelse 1;
        const oname = args.expectPositional("ORG");
        var qs = api_mod.query(app.arena);
        try qs.addInt("page", page);
        const users = api.parse([]api_mod.User, try api.getQuery("/orgs/{s}/members", .{oname}, qs.slice()));
        for (users) |u| std.debug.print("{s} {s}\n", .{ app.render.bullet, u.login orelse "?" });
    } else if (util.eql(sub, "visibility")) {
        const set = args.takeOpt("set", 's');
        const oname = args.expectPositional("ORG");
        const me = api.parse(api_mod.User, try api.get("/user", .{}));
        const login = me.login orelse util.fatal("not logged in", .{});
        if (set) |v| {
            if (util.eql(v, "public")) {
                _ = try api.put("/orgs/{s}/public_members/{s}", .{ oname, login }, "");
            } else {
                try api.delete("/orgs/{s}/public_members/{s}", .{ oname, login });
            }
            if (util.eql(v, "public")) {
                app.say("msg-org-visibility-set_public", &.{loc.str("org_name", oname)});
            } else {
                app.say("msg-org-visibility-set_private", &.{loc.str("org_name", oname)});
            }
        } else {
            _ = api.get("/orgs/{s}/public_members/{s}", .{ oname, login }) catch {
                app.say("msg-org-visibility-private", &.{loc.str("org_name", oname)});
                return;
            };
            app.say("msg-org-visibility-public", &.{loc.str("org_name", oname)});
        }
    } else if (util.eql(sub, "team")) {
        try team(app, args, &api);
    } else if (util.eql(sub, "label")) {
        try label(app, args, &api);
    } else if (util.eql(sub, "repo")) {
        try orgRepo(app, args, &api);
    } else {
        util.fatal("unknown org command: {s}", .{sub});
    }
}

fn printOrg(app: *App, org: api_mod.Organization) void {
    const name = org.username orelse org.name orelse "?";
    std.debug.print("{s}{s}{s} {s} {s} {s}\n", .{
        app.render.bold,
        org.full_name orelse name,
        app.render.reset,
        app.render.dash,
        name,
        org.visibility orelse "",
    });
    if (org.website) |w| if (w.len > 0) std.debug.print("{s}\n", .{w});
    if (org.description) |d| {
        if (d.len > 0) {
            std.debug.print("\n", .{});
            style.markdown(app.render, d);
        }
    }
}

fn validateOrgName(name: []const u8) void {
    if (name.len == 0) util.fatal("invalid organization name", .{});
    if (!std.ascii.isAlphanumeric(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) {
        util.fatal("organization name must start and end with alphanumeric characters", .{});
    }
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) {
            util.fatal("organization name contains invalid character", .{});
        }
    }
}

fn team(app: *App, args: *cli.ArgList, api: *api_mod.Api) !void {
    const sub = args.expectPositional("ACTION");
    if (util.eql(sub, "list")) {
        const org = args.expectPositional("ORG");
        const teams = api.parse([]api_mod.Team, try api.get("/orgs/{s}/teams", .{org}));
        for (teams) |t| std.debug.print("{s} {s}\n", .{ app.render.bullet, t.name orelse "?" });
    } else if (util.eql(sub, "view")) {
        const list_perm = args.takeFlag("list-permissions", 'p');
        const org = args.expectPositional("ORG");
        const tname = args.expectPositional("NAME");
        const t = try findTeam(api, org, tname);
        std.debug.print("{s}{s}{s} {s}\n", .{ app.render.bold, t.name orelse tname, app.render.reset, t.permission orelse "" });
        if (t.description) |d| if (d.len > 0) std.debug.print("{s}\n", .{d});
        _ = list_perm;
    } else if (util.eql(sub, "create")) {
        const description = args.takeOpt("description", 'd');
        const org = args.expectPositional("ORG");
        const tname = args.expectPositional("NAME");
        const payload = try util.jsonStringify(app.arena, .{
            .name = tname,
            .description = description,
            .permission = "read",
        });
        const t = api.parse(api_mod.Team, try api.post("/orgs/{s}/teams", .{org}, payload));
        app.say("msg-org-team-create-success", &.{
            loc.str("name", t.name orelse tname),
            loc.str("org", org),
            loc.flag("admin", false),
        });
    } else if (util.eql(sub, "edit")) {
        const new_name = args.takeOpt("new-name", 'n');
        const description = args.takeOpt("description", 'd');
        const org = args.expectPositional("ORG");
        const tname = args.expectPositional("NAME");
        const t = try findTeam(api, org, tname);
        const payload = try util.jsonStringify(app.arena, .{
            .name = new_name,
            .description = description,
        });
        _ = try api.patch("/teams/{d}", .{t.id orelse 0}, payload);
        std.debug.print("updated team {s}\n", .{tname});
    } else if (util.eql(sub, "delete")) {
        const org = args.expectPositional("ORG");
        const tname = args.expectPositional("NAME");
        const t = try findTeam(api, org, tname);
        try api.delete("/teams/{d}", .{t.id orelse 0});
        std.debug.print("deleted team {s}\n", .{tname});
    } else if (util.eql(sub, "repo")) {
        const action = args.expectPositional("ACTION");
        const org = args.expectPositional("ORG");
        const tname = args.expectPositional("TEAM");
        const t = try findTeam(api, org, tname);
        if (util.eql(action, "list")) {
            const repos = api.parse([]api_mod.Repository, try api.get("/teams/{d}/repos", .{t.id orelse 0}));
            for (repos) |r| std.debug.print("{s}\n", .{r.full_name orelse "?"});
        } else if (util.eql(action, "add")) {
            const repo = args.expectPositional("REPO");
            _ = try api.put("/teams/{d}/repos/{s}/{s}", .{ t.id orelse 0, org, repo }, "");
        } else if (util.eql(action, "rm")) {
            const repo = args.expectPositional("REPO");
            try api.delete("/teams/{d}/repos/{s}/{s}", .{ t.id orelse 0, org, repo });
        } else util.fatal("unknown team repo command: {s}", .{action});
    } else if (util.eql(sub, "member")) {
        const action = args.expectPositional("ACTION");
        const org = args.expectPositional("ORG");
        const tname = args.expectPositional("TEAM");
        const t = try findTeam(api, org, tname);
        if (util.eql(action, "list")) {
            const users = api.parse([]api_mod.User, try api.get("/teams/{d}/members", .{t.id orelse 0}));
            for (users) |u| std.debug.print("{s}\n", .{u.login orelse "?"});
        } else if (util.eql(action, "add")) {
            const user = args.expectPositional("USER");
            _ = try api.put("/teams/{d}/members/{s}", .{ t.id orelse 0, user }, "");
        } else if (util.eql(action, "rm")) {
            const user = args.expectPositional("USER");
            try api.delete("/teams/{d}/members/{s}", .{ t.id orelse 0, user });
        } else util.fatal("unknown team member command: {s}", .{action});
    } else util.fatal("unknown team command: {s}", .{sub});
}

fn findTeam(api: *api_mod.Api, org: []const u8, name: []const u8) !api_mod.Team {
    const teams = api.parse([]api_mod.Team, try api.get("/orgs/{s}/teams", .{org}));
    for (teams) |t| if (t.name) |n| if (util.eql(n, name)) return t;
    util.fatal("team not found: {s}", .{name});
}

fn label(app: *App, args: *cli.ArgList, api: *api_mod.Api) !void {
    const sub = args.expectPositional("ACTION");
    if (util.eql(sub, "list")) {
        const org = args.expectPositional("ORG");
        const labels = api.parse([]api_mod.Label, try api.get("/orgs/{s}/labels", .{org}));
        for (labels) |l| {
            style.renderLabel(app.render, l.name orelse "???", l.color orelse "FFFFFF", l.exclusive orelse false);
            std.debug.print("\n", .{});
        }
    } else if (util.eql(sub, "add")) {
        const exclusive = args.takeFlag("exclusive", 'e');
        const description = args.takeOpt("description", 'd');
        const org = args.expectPositional("ORG");
        const lname = args.expectPositional("NAME");
        const color = args.expectPositional("COLOR");
        const payload = try util.jsonStringify(app.arena, .{
            .name = lname,
            .color = util.stripPrefix(color, "#"),
            .description = description,
            .exclusive = exclusive,
        });
        _ = try api.post("/orgs/{s}/labels", .{org}, payload);
        app.say("msg-org-label-add-success", &.{loc.str("label", lname)});
    } else if (util.eql(sub, "edit")) {
        const new_name = args.takeOpt("new-name", 'n');
        const color = args.takeOpt("color", 'c');
        const description = args.takeOpt("description", 'd');
        const org = args.expectPositional("ORG");
        const lname = args.expectPositional("NAME");
        const labels = api.parse([]api_mod.Label, try api.get("/orgs/{s}/labels", .{org}));
        var id: i64 = 0;
        for (labels) |l| {
            if (l.name) |n| {
                if (util.eql(n, lname)) id = l.id orelse 0;
            }
        }
        if (id == 0) util.fatal("label not found", .{});
        const payload = try util.jsonStringify(app.arena, .{
            .name = new_name,
            .color = if (color) |c| util.stripPrefix(c, "#") else null,
            .description = description,
        });
        _ = try api.patch("/orgs/{s}/labels/{d}", .{ org, id }, payload);
        app.say("msg-org-label-edit-success", &.{
            loc.str("old_label", lname),
            loc.str("label", new_name orelse lname),
        });
    } else if (util.eql(sub, "rm")) {
        const org = args.expectPositional("ORG");
        const lname = args.expectPositional("LABEL");
        const labels = api.parse([]api_mod.Label, try api.get("/orgs/{s}/labels", .{org}));
        var id: i64 = 0;
        for (labels) |l| {
            if (l.name) |n| {
                if (util.eql(n, lname)) id = l.id orelse 0;
            }
        }
        if (id == 0) util.fatal("label not found", .{});
        try api.delete("/orgs/{s}/labels/{d}", .{ org, id });
        app.say("msg-org-label-remove-success", &.{loc.str("label", lname)});
    } else util.fatal("unknown org label command: {s}", .{sub});
}

fn orgRepo(app: *App, args: *cli.ArgList, api: *api_mod.Api) !void {
    _ = api;
    const sub = args.expectPositional("ACTION");
    if (util.eql(sub, "list")) {
        const page = util.parseU32(args.takeOpt("page", 'p') orelse "1") orelse 1;
        const org = args.expectPositional("ORG");
        var qs = api_mod.query(app.arena);
        try qs.addInt("page", page);
        var a = app.apiFor((try git_mod.getCurrent(app, app.host_flag, null, null)).url);
        const repos = a.parse([]api_mod.Repository, try a.getQuery("/orgs/{s}/repos", .{org}, qs.slice()));
        for (repos) |r| std.debug.print("{s} {s}\n", .{ app.render.bullet, r.full_name orelse "?" });
    } else if (util.eql(sub, "create")) {
        const org = args.expectPositional("ORG");
        try cmd_repo.create(app, args, org);
    } else util.fatal("unknown org repo command: {s}", .{sub});
}
