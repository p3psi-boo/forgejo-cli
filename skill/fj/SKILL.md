---
name: fj
description: Use the fj CLI to work with Forgejo or Codeberg from a coding agent. Covers auth, issues, pull requests (including AGit), repos, Actions runs/jobs/steps/logs, releases, orgs, and how to recover when an instance lacks a newer API.
---

# fj — Forgejo CLI for coding agents

`fj` is the Forgejo equivalent of `gh`. Use it for Forgejo-specific work (Codeberg, self-hosted Forgejo, code.forgejo.org). Do not use `gh` against a Forgejo remote.

`fj` does not replace `git`. Use `git` for commits, branches, remotes, and push/fetch. Use `fj` for issues, PRs, Actions, releases, orgs, and auth.

Print this skill at any time with `fj skill`. Install a copy Cursor can auto-load with `fj skill write`.

## Before anything else

```bash
fj version
fj auth list
fj whoami
```

If there is no login for the instance:

```bash
fj auth login
# or, if OAuth is unavailable on that host:
fj auth add-token
```

Create the token on `$HOST/user/settings/applications` with repo + issue + PR scopes. Prefer `fj auth login` when the host has an OAuth client id.

## How fj picks the repo

| Goal | Flag |
|---|---|
| Current git checkout | (none) |
| Another repo on the current host | `-r owner/name` |
| Explicit host | `-H codeberg.org` or `-H https://git.example.com` |
| Specific git remote | `-R origin` |
| Run from another directory | `-C /path/to/repo` |

If a command cannot infer the repo, pass `-r`. Do not guess the host from a GitHub URL.

## Everyday agent workflows

### Inspect

```bash
fj repo view
fj issue search --state open
fj issue view 12
fj pr search --state open
fj pr view 34
fj pr status
fj pr view 34 diff
fj actions tasks
```

### Change

```bash
fj issue create --title "..." --body "..."
fj issue comment 12 --body "..."
fj issue close 12
fj pr comment 34 --body "..."
fj pr merge 34
```

### Open a PR

```bash
git checkout -b topic
git commit ...
git push -u origin topic
fj pr create --title "..." --body "..."
```

On Forgejo, AGit avoids a fork:

```bash
fj pr create --agit --title "..." --body "..."
```

`--web` opens the browser instead of creating from the CLI. Do not combine `--web` and `--agit`.

## Actions (CI)

```bash
fj actions tasks                          # list runs; prints #number and [id]
fj actions view <RUN>                     # run + jobs + steps
fj actions view <RUN> --job <ID> --logs   # one job, with logs
fj actions view <RUN> --job <ID> --logs --step N
fj actions jobs <RUN>
fj actions logs --job <ID>
fj actions logs --run <RUN> --out run.zip
fj actions dispatch workflow.yml main
```

`<RUN>` is a run id, or a run number prefixed with `#` (`#12`). A bare number is tried as an id first, then as a run number.

When the instance is too old, `fj` exits with an error instead of an empty list:

- run details / job list → Forgejo v15+
- step details → `GET /repos/{owner}/{repo}/actions/jobs/{id}`
- logs → Forgejo v16+

If you see those errors, tell the user the instance does not support that API. Do not scrape the web UI unless they ask.

## Other surfaces

```bash
fj release list
fj release view v1.0.0
fj milestone list
fj wiki list
fj org list
fj user view
```

Destructive commands (`repo delete`, secret/variable delete, merge) need an explicit user request.

## Help and discovery

```bash
fj --help
fj <command> --help
fj skill                 # this document
fj skill write           # write .cursor/skills/fj/SKILL.md
fj completion bash       # also used as a clap smoke test
```

Prefer `fj` plus `--help` over inventing flags. If a flag is unclear, run the help for that subcommand.
