## `fj`, a CLI client for Forgejo

... akin to `gh`, `glab`, or `tea`!

You can...

- Open, edit, comment on, close issues
- Create and merge pull requests
  - Easily create AGit pull requests, no need to fork!
- Create, star, watch, and edit repositories
- Manage organizations and teams
- Publish new releases

all from the command line.

`fj` doesn't try to replace your usage of `git`, it's meant to work alongside it.
It handles all the Forgejo-specific things that `git` doesn't.

### Building

`fj` is written in [Zig](https://ziglang.org/) 0.17. From a source checkout:

```sh
zig build
./zig-out/bin/fj --help
```

A release build:

```sh
zig build -Doptimize=ReleaseSafe
```

Run unit tests with `zig build test`.

Existing `~/.local/share/forgejo-cli/keys.json` logins (application tokens and OAuth) remain compatible.

### Licensing

This project is licensed under either
[Apache License Version 2.0](LICENSE-APACHE) or [MIT License](LICENSE-MIT)
at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the Apache-2.0 license, shall be
dual licensed as above, without any additional terms or conditions.
