# Contributing to Teleport

Thanks for taking the time to look at Teleport. The project is small enough
that one good PR can move the roadmap forward, so contributions of all sizes
are welcome — bug reports, doc fixes, performance work, new features, or just
a thoughtful issue.

This guide covers what you need to get a working dev loop and what we look for
in a pull request.

---

## Ground rules

- Be respectful. We follow the [Code of Conduct](CODE_OF_CONDUCT.md).
- For anything **security-sensitive**, please **do not** open a public issue.
  Read [SECURITY.md](SECURITY.md) for the private disclosure process.
- For larger changes (new dependency, new wire-format field, anything that
  touches the encryption or sync protocol), open an issue *first* so we can
  discuss the design before you spend a weekend on a PR.

---

## Project layout

```
daemon/   Rust background process — file watcher, Noise transport, P2P sync
ui/       SwiftUI menu-bar app that supervises the daemon
docs/     Design notes and the path-to-production roadmap
.github/  CI / release workflows + issue & PR templates
```

The two halves talk over a child-process pipe. The Swift side never touches
the network directly — all sockets live in the Rust daemon, and the daemon
never owns any UI.

---

## Prerequisites

- macOS 14 (Sonoma) or newer — Apple Silicon or Intel
- Xcode Command Line Tools (`xcode-select --install`)
- Rust stable (`rustup install stable`)
- Swift 5.9+ (ships with Xcode 15)

---

## Dev loop

The fastest inner loop while iterating on Swift is:

```bash
make run-ui          # cd ui && swift run
```

To exercise the full bundled experience (menu bar icon, Info.plist, icon
asset, daemon spawned as a child process), use:

```bash
make run             # debug build + open ui/Teleport.app
make app-release     # ad-hoc-signed release build
make install         # replace /Applications/Teleport.app and relaunch
```

To work purely on the daemon without the UI, drive it from two terminals:

```bash
# Terminal A
cd daemon && cargo run -- --folder ~/code/proj host

# Terminal B
cd daemon && cargo run -- --folder ~/code/proj-mirror join 127.0.0.1
```

The daemon reads its passphrase from the `TELEPORT_PASSPHRASE` environment
variable (the UI sets this for you). Never put the passphrase on the command
line in production — it's world-readable via `ps`.

---

## Testing

```bash
cd daemon && cargo test           # Rust unit tests
cd ui && swift build              # type-check the SwiftUI target
```

CI runs both on every push and PR (see `.github/workflows/ci.yml`).

If your change touches the wire protocol, the file watcher, or the crypto
layer, please add a test. Patches without tests for those areas usually get
asked for one before merge.

---

## Pull request checklist

Before opening a PR, please make sure:

- [ ] `cd daemon && cargo build` succeeds with no new warnings
- [ ] `cd daemon && cargo test` passes
- [ ] `cd ui && swift build` succeeds with no new warnings
- [ ] You ran `cargo fmt` (Rust) and matched the existing Swift style
- [ ] You did **not** commit `magic.txt`-style local test files, build
      artifacts, or generated icon assets (the `.gitignore` covers the usual
      ones — please don't `git add -f` past it)
- [ ] No secrets, tokens, or personal paths in the diff
- [ ] If you changed user-visible behavior, the README and/or CHANGELOG are
      updated

Commit messages: short imperative subject (`fix: …`, `feat: …`, `chore: …`),
optional body explaining *why* the change is needed.

---

## Reporting bugs / requesting features

Use the templates under "New issue" on GitHub. For bugs, the most useful
reports include:

- macOS version + chip (Apple Silicon / Intel)
- Teleport version (visible in the menu bar dashboard)
- What you did → what you expected → what actually happened
- A snippet of the daemon log from the dashboard (with the passphrase
  redacted, although the app does this for you)

Thanks again for helping make Teleport better.
