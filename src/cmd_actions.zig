const std = @import("std");
const App = @import("app.zig").App;
const cli = @import("cli.zig");
const util = @import("util.zig");
const git_mod = @import("git.zig");
const api_mod = @import("api.zig");

pub fn run(app: *App, args: *cli.ArgList) !void {
    const remote = args.takeOpt("remote", 'R');
    const repo_flag = if (args.takeOpt("repo", 'r')) |s| git_mod.RepoName.parseArg(s) else null;
    const sub = args.takePositional() orelse util.fatal("usage: fj actions <tasks|variables|secrets|dispatch|view|jobs|logs>", .{});
    const info = try git_mod.getCurrent(app, app.host_flag, repo_flag, remote);
    const name = git_mod.requireName(info);
    var api = app.apiFor(info.url);

    if (util.eql(sub, "tasks")) {
        const page = util.parseU32(args.takeOpt("page", 'p') orelse "1") orelse 1;
        args.rejectUnknownFlags();
        var qs = api_mod.query(app.arena);
        try qs.addInt("page", page);
        const Task = struct { id: ?i64 = null, name: ?[]const u8 = null, status: ?[]const u8 = null };
        const Wrap = struct { workflow_runs: ?[]Task = null, tasks: ?[]Task = null };
        const body = try api.getQuery("/repos/{s}/{s}/actions/tasks", .{ name.owner, name.name }, qs.slice());
        const parsed = api.parse(Wrap, body);
        const tasks = parsed.workflow_runs orelse parsed.tasks orelse &.{};
        for (tasks) |t| std.debug.print("{d}\t{s}\t{s}\n", .{ t.id orelse 0, t.status orelse "?", t.name orelse "?" });
    } else if (util.eql(sub, "variables")) {
        try variables(app, args, &api, name);
    } else if (util.eql(sub, "secrets")) {
        try secrets(app, args, &api, name);
    } else if (util.eql(sub, "dispatch")) {
        const inputs = try args.takeAll("inputs", 'I');
        const wname = args.expectPositional("NAME");
        const ref = args.expectPositional("REF");
        args.rejectUnknownFlags();
        var obj: std.json.ObjectMap = .empty;
        for (inputs) |kv| {
            const pair = util.splitOnce(kv, '=') orelse util.fatal("inputs must be key=value", .{});
            try obj.put(app.arena, pair[0], .{ .string = pair[1] });
        }
        const payload = try util.jsonStringify(app.arena, .{
            .ref = ref,
            .inputs = std.json.Value{ .object = obj },
        });
        _ = try api.post("/repos/{s}/{s}/actions/workflows/{s}/dispatches", .{ name.owner, name.name, wname }, payload);
        std.debug.print("dispatched workflow {s} on {s}\n", .{ wname, ref });
    } else if (util.eql(sub, "view")) {
        const job = args.takeOpt("job", 'j');
        const logs = args.takeFlag("logs", null);
        const run_arg = args.expectPositional("RUN");
        args.rejectUnknownFlags();
        const id = parseRun(run_arg);
        const Run = struct {
            id: ?i64 = null,
            title: ?[]const u8 = null,
            status: ?[]const u8 = null,
            event: ?[]const u8 = null,
            html_url: ?[]const u8 = null,
        };
        const r = api.parse(Run, try api.get("/repos/{s}/{s}/actions/runs/{s}", .{ name.owner, name.name, id }));
        std.debug.print("{s}{s}{s} ({s})\n", .{ app.render.bold, r.title orelse id, app.render.reset, r.status orelse "?" });
        if (r.html_url) |u| std.debug.print("{s}\n", .{u});
        if (logs) {
            const path = if (job) |j|
                try std.fmt.allocPrint(app.arena, "/repos/{s}/{s}/actions/jobs/{s}/logs", .{ name.owner, name.name, j })
            else
                try std.fmt.allocPrint(app.arena, "/repos/{s}/{s}/actions/runs/{s}/jobs", .{ name.owner, name.name, id });
            const body = api.get("{s}", .{path}) catch return;
            std.debug.print("{s}\n", .{body});
        }
    } else if (util.eql(sub, "jobs")) {
        const run_arg = args.expectPositional("RUN");
        args.rejectUnknownFlags();
        const Job = struct { id: ?i64 = null, name: ?[]const u8 = null, status: ?[]const u8 = null, conclusion: ?[]const u8 = null };
        const Wrap = struct { jobs: ?[]Job = null };
        const wrap = api.parse(Wrap, try api.get("/repos/{s}/{s}/actions/runs/{s}/jobs", .{ name.owner, name.name, parseRun(run_arg) }));
        if (wrap.jobs) |jobs| for (jobs) |j| {
            std.debug.print("{d}\t{s}\t{s}\t{s}\n", .{ j.id orelse 0, j.status orelse "?", j.conclusion orelse "", j.name orelse "?" });
        };
    } else if (util.eql(sub, "logs")) {
        const job = args.takeOpt("job", 'j');
        const run_opt = args.takeOpt("run", null);
        const out = args.takeOpt("out", 'o');
        args.rejectUnknownFlags();
        if (job) |j| {
            const body = try api.get("/repos/{s}/{s}/actions/jobs/{s}/logs", .{ name.owner, name.name, j });
            if (out) |p| {
                try util.writeFileMode(app, p, body, .default_file);
            } else {
                std.debug.print("{s}", .{body});
            }
        } else if (run_opt) |r| {
            const body = try api.get("/repos/{s}/{s}/actions/runs/{s}/logs", .{ name.owner, name.name, parseRun(r) });
            const dest = out orelse "logs.zip";
            try util.writeFileMode(app, dest, body, .default_file);
            std.debug.print("wrote {s}\n", .{dest});
        } else {
            util.fatal("specify --job or --run", .{});
        }
    } else {
        util.fatal("unknown actions command: {s}", .{sub});
    }
}

fn parseRun(s: []const u8) []const u8 {
    return util.stripPrefix(s, "#");
}

fn variables(app: *App, args: *cli.ArgList, api: *api_mod.Api, name: git_mod.RepoName) !void {
    const sub = args.takePositional() orelse "list";
    if (util.eql(sub, "list")) {
        const verbose = args.takeFlag("verbose", 'v');
        args.rejectUnknownFlags();
        const Var = struct { name: ?[]const u8 = null, data: ?[]const u8 = null, owner_id: ?i64 = null, repo_id: ?i64 = null };
        const Wrap = struct { variables: ?[]Var = null };
        const wrap = api.parse(Wrap, try api.get("/repos/{s}/{s}/actions/variables", .{ name.owner, name.name }));
        const list = wrap.variables orelse &.{};
        for (list) |v| {
            if (verbose) {
                std.debug.print("{s}\towner={d} repo={d}\n{s}\n", .{ v.name orelse "?", v.owner_id orelse 0, v.repo_id orelse 0, v.data orelse "" });
            } else {
                std.debug.print("{s}\n", .{v.name orelse "?"});
            }
        }
    } else if (util.eql(sub, "create")) {
        const force = args.takeFlag("force", 'f');
        const vname = args.expectPositional("NAME");
        var data = args.takePositional() orelse "";
        if (data.len == 0) try util.editor(app, &data, null);
        const payload = try util.jsonStringify(app.arena, .{ .value = data });
        if (force) {
            _ = api.patch("/repos/{s}/{s}/actions/variables/{s}", .{ name.owner, name.name, vname }, payload) catch {
                _ = try api.post("/repos/{s}/{s}/actions/variables/{s}", .{ name.owner, name.name, vname }, payload);
            };
        } else {
            _ = try api.post("/repos/{s}/{s}/actions/variables/{s}", .{ name.owner, name.name, vname }, payload);
        }
        std.debug.print("saved variable {s}\n", .{vname});
    } else if (util.eql(sub, "delete")) {
        const vname = args.expectPositional("NAME");
        args.rejectUnknownFlags();
        try api.delete("/repos/{s}/{s}/actions/variables/{s}", .{ name.owner, name.name, vname });
        std.debug.print("Variable {s} deleted.\n", .{vname});
    } else util.fatal("unknown variables command: {s}", .{sub});
}

fn secrets(app: *App, args: *cli.ArgList, api: *api_mod.Api, name: git_mod.RepoName) !void {
    const sub = args.takePositional() orelse "list";
    if (util.eql(sub, "list")) {
        args.rejectUnknownFlags();
        const Secret = struct { name: ?[]const u8 = null };
        const Wrap = struct { secrets: ?[]Secret = null };
        const wrap = api.parse(Wrap, try api.get("/repos/{s}/{s}/actions/secrets", .{ name.owner, name.name }));
        if (wrap.secrets) |list| for (list) |s| std.debug.print("{s}\n", .{s.name orelse "?"});
    } else if (util.eql(sub, "create")) {
        const sname = args.expectPositional("NAME");
        const data = args.expectPositional("DATA");
        const payload = try util.jsonStringify(app.arena, .{ .data = data });
        _ = try api.put("/repos/{s}/{s}/actions/secrets/{s}", .{ name.owner, name.name, sname }, payload);
        std.debug.print("saved secret {s}\n", .{sname});
    } else if (util.eql(sub, "delete")) {
        const sname = args.expectPositional("NAME");
        try api.delete("/repos/{s}/{s}/actions/secrets/{s}", .{ name.owner, name.name, sname });
        std.debug.print("deleted secret {s}\n", .{sname});
    } else util.fatal("unknown secrets command: {s}", .{sub});
}
