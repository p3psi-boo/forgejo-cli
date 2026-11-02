const std = @import("std");
const args_mod = @import("args");
const build_options = @import("build_options");
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

fn parserConfig() args_mod.Config {
    return .{
        .parsing_mode = .permissive,
        .exit_on_error = false,
        .use_colors = false,
        .show_defaults = false,
        .show_env_vars = false,
        .suggest_closest = true,
        .allow_interspersed = true,
    };
}

const auth_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "login", .help = "Log in to an instance" },
    .{ .name = "logout", .help = "Deletes login info for an instance" },
    .{ .name = "add-token", .help = "Add an application token for an instance", .aliases = &.{"add-key"} },
    .{ .name = "use-ssh", .help = "Enable or disable using SSH by default for certain instances" },
    .{ .name = "list", .help = "List all instances you're currently logged into" },
};

const repo_label_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "view", .help = "Show a repo's labels" },
    .{ .name = "create", .help = "Create a new label" },
    .{ .name = "delete", .help = "Delete a label" },
    .{ .name = "edit", .help = "Edit a label" },
};

const repo_unit_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "issues", .help = "Manage the issues unit" },
    .{ .name = "prs", .help = "Manage the pull requests unit" },
    .{ .name = "actions", .help = "Manage the actions unit" },
    .{ .name = "wiki", .help = "Manage the wiki unit" },
    .{ .name = "packages", .help = "Manage the packages unit" },
    .{ .name = "projects", .help = "Manage the projects unit" },
    .{ .name = "releases", .help = "Manage the releases unit" },
};

const repo_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "create", .help = "Create a new repository" },
    .{ .name = "fork", .help = "Fork a repository onto your account" },
    .{ .name = "migrate", .help = "Migrate or mirror an existing repository" },
    .{ .name = "view", .help = "View a repo's info" },
    .{ .name = "readme", .help = "View a repo's README" },
    .{ .name = "clone", .help = "Clone a repo's code locally" },
    .{ .name = "star", .help = "Add a star to a repo" },
    .{ .name = "unstar", .help = "Take away a star from a repo" },
    .{ .name = "star-status", .help = "Check your current starring status" },
    .{ .name = "watch", .help = "Subscribe to a repo" },
    .{ .name = "unwatch", .help = "Unsubscribe from a repo" },
    .{ .name = "watch-status", .help = "Check your current watch status" },
    .{ .name = "delete", .help = "Delete a repository" },
    .{ .name = "browse", .help = "Open a repository's page in your browser" },
    .{ .name = "labels", .help = "Manage a repo's issue labels", .aliases = &.{"label"}, .subcommands = &repo_label_subs },
    .{ .name = "edit", .help = "Edit a repository's properties" },
    .{ .name = "units", .help = "Manage a repo's units", .aliases = &.{"unit"}, .subcommands = &repo_unit_subs },
};

const issue_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "create", .help = "Create a new issue on a repo" },
    .{ .name = "edit", .help = "Edit an issue" },
    .{ .name = "comment", .help = "Add a comment on an issue" },
    .{ .name = "assign", .help = "Assign users to an issue" },
    .{ .name = "unassign", .help = "Unassign users from an issue" },
    .{ .name = "close", .help = "Close an issue" },
    .{ .name = "search", .help = "Search for an issue in a repo" },
    .{ .name = "view", .help = "View an issue's info" },
    .{ .name = "templates", .help = "List the issue templates in a repo" },
    .{ .name = "browse", .help = "Open an issue in your browser" },
    .{ .name = "depend", .help = "Manage issues this issue depends on" },
    .{ .name = "block", .help = "Manage issues this issue blocks" },
};

const pr_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "search", .help = "Search a repository's pull requests" },
    .{ .name = "create", .help = "Create a new pull request" },
    .{ .name = "view", .help = "View the contents of a pull request" },
    .{ .name = "status", .help = "View the mergability and CI status of a pull request" },
    .{ .name = "checkout", .help = "Checkout a pull request in a new branch" },
    .{ .name = "comment", .help = "Add a comment on a pull request" },
    .{ .name = "assign", .help = "Assign users to a pull request" },
    .{ .name = "unassign", .help = "Unassign users from a pull request" },
    .{ .name = "edit", .help = "Edit the contents of a pull request" },
    .{ .name = "close", .help = "Close a pull request, without merging" },
    .{ .name = "merge", .help = "Merge a pull request" },
    .{ .name = "browse", .help = "Open a pull request in your browser" },
    .{ .name = "review", .help = "Manage reviews on a pull request" },
    .{ .name = "depend", .help = "Manage issues this pull request depends on" },
    .{ .name = "block", .help = "Manage issues this pull request blocks" },
};

const milestone_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "search", .help = "Search for milestones" },
    .{ .name = "create", .help = "Create a new milestone" },
    .{ .name = "view", .help = "View a milestone" },
    .{ .name = "edit", .help = "Edit a milestone" },
    .{ .name = "delete", .help = "Delete a milestone" },
};

const wiki_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "contents", .help = "List wiki pages" },
    .{ .name = "view", .help = "View a wiki page" },
    .{ .name = "clone", .help = "Clone a repo's wiki" },
    .{ .name = "browse", .help = "Open a wiki page in your browser" },
};

const actions_var_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "list", .help = "List variables" },
    .{ .name = "create", .help = "Create a new variable" },
    .{ .name = "delete", .help = "Delete a variable" },
};

const actions_secret_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "list", .help = "List secrets" },
    .{ .name = "create", .help = "Create a new actions secret" },
    .{ .name = "delete", .help = "Delete an actions secret" },
};

const actions_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "tasks", .help = "List the tasks on a repo" },
    .{ .name = "variables", .help = "List and manage variables", .subcommands = &actions_var_subs },
    .{ .name = "dispatch", .help = "Dispatch a workflow" },
    .{ .name = "secrets", .help = "List and manage secrets", .subcommands = &actions_secret_subs },
    .{ .name = "view", .help = "View details of a workflow run" },
    .{ .name = "jobs", .help = "List jobs of a workflow run" },
    .{ .name = "logs", .help = "Show or download workflow logs" },
};

const release_asset_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "create", .help = "Create a new attachment on a release" },
    .{ .name = "delete", .help = "Remove an attachment from a release" },
    .{ .name = "download", .help = "Download an attached file" },
};

const release_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "create", .help = "Create a new release" },
    .{ .name = "edit", .help = "Edit a release's info" },
    .{ .name = "delete", .help = "Delete a release" },
    .{ .name = "list", .help = "List all the releases on a repo" },
    .{ .name = "view", .help = "View a release's info" },
    .{ .name = "browse", .help = "Open a release in your browser" },
    .{ .name = "asset", .help = "Commands on a release's attached files", .subcommands = &release_asset_subs },
};

const tag_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "create", .help = "Create a new tag" },
    .{ .name = "delete", .help = "Delete a tag" },
    .{ .name = "list", .help = "List all the tags on a repo" },
    .{ .name = "view", .help = "View a tag's info" },
};

const user_edit_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "bio", .help = "Set your bio" },
    .{ .name = "name", .help = "Set your full name" },
    .{ .name = "pronouns", .help = "Set your pronouns" },
    .{ .name = "location", .help = "Set your location" },
    .{ .name = "activity", .help = "Set your activity visibility" },
    .{ .name = "email", .help = "Manage the email addresses associated with your account" },
    .{ .name = "website", .help = "Set your linked website" },
};

const user_key_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "list", .help = "List your SSH keys" },
    .{ .name = "view", .help = "View an SSH key" },
    .{ .name = "delete", .help = "Delete an SSH key" },
    .{ .name = "upload", .help = "Upload an SSH key" },
};

const user_gpg_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "list", .help = "List your GPG keys" },
    .{ .name = "view", .help = "View a GPG key" },
    .{ .name = "upload", .help = "Upload a GPG key" },
    .{ .name = "verify", .help = "Verifies a GPG key" },
    .{ .name = "delete", .help = "Delete a GPG key" },
};

const user_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "search", .help = "Search for a user by username" },
    .{ .name = "view", .help = "View a user's profile page" },
    .{ .name = "browse", .help = "Open a user's profile page in your browser" },
    .{ .name = "follow", .help = "Follow a user" },
    .{ .name = "unfollow", .help = "Unfollow a user" },
    .{ .name = "following", .help = "List everyone a user follows" },
    .{ .name = "followers", .help = "List a user's followers" },
    .{ .name = "block", .help = "Block a user" },
    .{ .name = "unblock", .help = "Unblock a user" },
    .{ .name = "repos", .help = "List a user's repositories" },
    .{ .name = "orgs", .help = "List the organizations a user is a member of" },
    .{ .name = "activity", .help = "List a user's recent activity" },
    .{ .name = "edit", .help = "Edit your user settings", .subcommands = &user_edit_subs },
    .{ .name = "key", .help = "Manage SSH keys", .subcommands = &user_key_subs },
    .{ .name = "gpg", .help = "Manage GPG keys", .subcommands = &user_gpg_subs },
};

const org_label_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "list", .help = "List all the issue labels an organization uses" },
    .{ .name = "add", .help = "Add a new issue label to an organization" },
    .{ .name = "edit", .help = "Edit an issue label an organization uses" },
    .{ .name = "rm", .help = "Remove an issue label from an organization" },
};

const org_repo_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "list", .help = "List all the repos owned by this organization" },
    .{ .name = "create", .help = "Create a new repository in this organization" },
};

const org_team_repo_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "list", .help = "List all the repos this team can access" },
    .{ .name = "add", .help = "Add access to an existing repo to a team" },
    .{ .name = "rm", .help = "Remove access to a repo from a team" },
};

const org_team_member_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "list", .help = "List all the members of a team" },
    .{ .name = "add", .help = "Add someone to a team" },
    .{ .name = "rm", .help = "Remove someone from a team" },
};

const org_team_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "list", .help = "View all the teams in an organization" },
    .{ .name = "view", .help = "View info about a single team" },
    .{ .name = "create", .help = "Create a new team" },
    .{ .name = "edit", .help = "Edit a team's information and permissions" },
    .{ .name = "delete", .help = "Delete a team from an organization" },
    .{ .name = "repo", .help = "Manage repos a team can access", .subcommands = &org_team_repo_subs },
    .{ .name = "member", .help = "Manage team members", .subcommands = &org_team_member_subs },
};

const org_subs = [_]args_mod.SubcommandSpec{
    .{ .name = "list", .help = "List all organizations" },
    .{ .name = "view", .help = "View info about an organization" },
    .{ .name = "create", .help = "Create a new organization" },
    .{ .name = "edit", .help = "Edit an organization's information" },
    .{ .name = "activity", .help = "View the activity in an organization" },
    .{ .name = "members", .help = "List the members of an organization" },
    .{ .name = "visibility", .help = "View and change the visibility of your membership in an organization" },
    .{ .name = "label", .help = "Manage organization issue labels", .subcommands = &org_label_subs },
    .{ .name = "repo", .help = "Manage organization repositories", .subcommands = &org_repo_subs },
    .{ .name = "team", .help = "Manage organization teams", .subcommands = &org_team_subs },
};

pub fn buildParser(allocator: std.mem.Allocator, bin_name: []const u8) !args_mod.ArgumentParser {
    args_mod.initConfig(parserConfig());
    var parser = try args_mod.ArgumentParser.init(allocator, .{
        .name = bin_name,
        .version = build_options.version,
        .description = "CLI tool for Forgejo",
        .add_help = true,
        .add_version = false,
        .config = parserConfig(),
    });
    errdefer parser.deinit();

    try parser.addOption("host", .{
        .short = 'H',
        .help = "Forgejo host URL",
        .metavar = "HOST",
    });
    try parser.addOption("cwd", .{
        .short = 'C',
        .help = "Sets the working directory to <CWD>",
        .metavar = "DIR",
    });
    try parser.addOption("style", .{
        .help = "Output style",
        .choices = &.{ "fancy", "minimal" },
        .metavar = "STYLE",
    });

    try parser.addSubcommand(.{ .name = "repo", .help = "Manage repositories", .subcommands = &repo_subs });
    try parser.addSubcommand(.{ .name = "issue", .help = "Manage issues", .subcommands = &issue_subs });
    try parser.addSubcommand(.{ .name = "pr", .help = "Manage pull requests", .subcommands = &pr_subs });
    try parser.addSubcommand(.{ .name = "milestone", .help = "Manage milestones", .subcommands = &milestone_subs });
    try parser.addSubcommand(.{ .name = "wiki", .help = "Wiki pages", .subcommands = &wiki_subs });
    try parser.addSubcommand(.{ .name = "actions", .help = "Forgejo Actions", .subcommands = &actions_subs });
    try parser.addSubcommand(.{ .name = "whoami", .help = "Show the authenticated user" });
    try parser.addSubcommand(.{ .name = "auth", .help = "Authentication", .subcommands = &auth_subs });
    try parser.addSubcommand(.{ .name = "release", .help = "Manage releases", .subcommands = &release_subs });
    try parser.addSubcommand(.{ .name = "tag", .help = "Manage tags", .subcommands = &tag_subs });
    try parser.addSubcommand(.{ .name = "user", .help = "Users", .subcommands = &user_subs });
    try parser.addSubcommand(.{ .name = "org", .help = "Organizations", .subcommands = &org_subs });
    try parser.addSubcommand(.{ .name = "version", .help = "Show version" });
    try parser.addSubcommand(.{ .name = "completion", .help = "Generate shell completions" });
    return parser;
}

fn printSpecHelp(allocator: std.mem.Allocator, spec: args_mod.CommandSpec) void {
    const text = args_mod.help.generateHelpWithConfig(allocator, spec, false, parserConfig()) catch {
        std.debug.print("failed to generate help\n", .{});
        return;
    };
    defer allocator.free(text);
    std.debug.print("{s}", .{text});
}

fn findSub(subs: []const args_mod.SubcommandSpec, name: []const u8) ?args_mod.SubcommandSpec {
    for (subs) |sub| {
        if (sub.matches(name)) return sub;
    }
    return null;
}

pub fn printTopHelp(allocator: std.mem.Allocator) void {
    var parser = buildParser(allocator, "fj") catch {
        std.debug.print("failed to build help\n", .{});
        return;
    };
    defer parser.deinit();
    parser.printHelp() catch {};
}

pub fn help(allocator: std.mem.Allocator, topic: []const u8) void {
    var parser = buildParser(allocator, "fj") catch {
        std.debug.print("failed to build help\n", .{});
        return;
    };
    defer parser.deinit();
    const spec = parser.buildSpec();
    if (findSub(spec.subcommands, topic)) |sub| {
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "fj {s}", .{sub.name}) catch sub.name;
        printSpecHelp(allocator, .{
            .name = name,
            .description = sub.help,
            .args = sub.args,
            .subcommands = sub.subcommands,
            .add_help = true,
            .add_version = false,
        });
        return;
    }
    printTopHelp(allocator);
}

pub fn completionScript(allocator: std.mem.Allocator, shell_name: []const u8, bin_name: []const u8) ![]const u8 {
    var parser = try buildParser(allocator, bin_name);
    defer parser.deinit();
    const shell = args_mod.Shell.fromString(shell_name) orelse
        return error.UnknownShell;
    return parser.generateCompletion(shell);
}

test "parser help mentions subcommands" {
    var parser = try buildParser(std.testing.allocator, "fj");
    defer parser.deinit();
    const text = try parser.getHelp();
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "repo") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auth") != null);
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
