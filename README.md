# e2e-marketplace

A plugin marketplace that [`grim`](https://grimoire.rs) generates and keeps
current, and the working reference for the hosting-a-marketplace guide
on grimoire.rs. Everything a curator
copies is here: the manifest, the generated output, the workflows that
regenerate and verify it, and the scripts they call.

It registers itself as **`grimoire-e2e`** and offers two plugins built from
public registries:

| Plugin | Built from |
|---|---|
| `grim-essentials` | `ghcr.io/grimoire-rs/bundles/grim-essentials:0` |
| `hex` | `ghcr.io/michael-herwig/arcana/hex:0` |

## Layout

Nothing under the generated paths is edited by hand. `grim export marketplace`
owns them, and the `verify` check fails any pull request that differs from a
fresh export.

| Path | Owner | What |
|---|---|---|
| `marketplace.toml` | curator | The plugins and the `[marketplace]` table |
| `marketplace.lock` | grim | Pinned digests, written by `grim update --marketplace` |
| `.claude-plugin/marketplace.json`, `claude/<plugin>/` | grim | Claude Code |
| `.github/plugin/marketplace.json`, `copilot/<plugin>/` | grim | Copilot CLI and VS Code |
| `.agents/plugins/marketplace.json`, `codex/<plugin>/` | grim | Codex |
| `.qoder-plugin/marketplace.json`, `qoder/<plugin>/` | grim | Qoder |
| `.github/workflows/marketplace.yml` | curator | Regenerate, deliver, keepalive |
| `.github/workflows/verify.yml` | curator | Required check on every pull request |
| `.github/workflows/gate-selftest.yml` | curator | Exercises the policy gate |
| `scripts/marketplace-gate.sh` | curator | Policy gate (POSIX sh, no jq) |
| `scripts/marketplace-verify.sh` | curator | The verification steps (POSIX sh) |
| `scripts/pr-body.sh` | curator | Pull-request body from the JSON reports (needs jq) |
| `scripts/gate-selftest.sh` | curator | Crafted-repository cases for the gate and the body |
| `ocx.toml` | curator | Pins the grim build the workflows run |
| `.github/CODEOWNERS` | curator | Review on everything a verifier trusts |

`.gitignore` holds `.grim-export*`, grim's staging and recovery leftovers.

## Add it in your tool

None of these needs grim. Your tool reads only its own marketplace file.

```sh
claude plugin marketplace add grimoire-rs/e2e-marketplace
claude plugin install grim-essentials@grimoire-e2e

copilot plugin marketplace add grimoire-rs/e2e-marketplace
copilot plugin install grim-essentials@grimoire-e2e

codex plugin marketplace add grimoire-rs/e2e-marketplace
codex plugin add grim-essentials@grimoire-e2e

qoder plugins marketplace add grimoire-rs/e2e-marketplace
qoder plugins install grim-essentials@grimoire-e2e
```

Append `#<tag>` to the address (Codex: `--ref <tag>`) to pin a release. Qoder
documents no way to pin.

## How it stays current

`marketplace.yml` runs daily, on a push to the default branch that touches
`marketplace.toml`, and on demand. One run:

1. installs grim from `ocx.toml`;
2. runs `grim update --marketplace` and `grim export marketplace`, both with
   `--format json`, into `$RUNNER_TEMP` (never the checkout);
3. runs `scripts/marketplace-gate.sh` before anything is staged;
4. stops when `git status` is empty;
5. commits as the bot and, with the `GITHUB_TOKEN` fallback, runs
   `scripts/marketplace-verify.sh` on the committed tree;
6. pushes the fixed branch `grim/marketplace` with `--force-with-lease` and
   opens or rewrites the one pull request (`MODE: push` pushes the default
   branch instead, for a marketplace of trusted registries only).

**Merging publishes.** Clients that follow this repository refresh within
minutes.

The policy gate fails the run, before any commit, on a changed path outside the
allow-list (the lock, every marketplace file the report names, and
`<client>/` for every reported client), a symlink, a path whose `filter`
attribute is `lfs`, or a file over `MAX_FILE_BYTES` (10 MiB).

`verify.yml` runs on `pull_request` (never `pull_request_target`) with no
`paths:` filter. It regenerates the marketplace in the checkout and requires
`git status` to show nothing over the lock, every marketplace file and every
client directory; it fails when a client the export does not select has tracked
content; then it runs `claude plugin validate` (no `--strict`) on the Claude
marketplace file and every `claude/<plugin>`. The normal change is one pull
request that edits `marketplace.toml` and commits the output of
`grim update --marketplace` and `grim export marketplace`, so `verify` is green.
A pull request that edits only `marketplace.toml` fails until the bot pull
request lands, which is the fallback flow. The daily schedule refreshes pins.

### Settings

- Protect the default branch, require the `verify` check, require code-owner
  review, dismiss stale approvals, keep the bot off any bypass list.
- **App token (preferred).** Repository variable `APP_ID` and secret
  `APP_PRIVATE_KEY` of a GitHub App with Contents and Pull requests write, never
  Workflows. Put them in an Environment named `marketplace` restricted to the
  default branch. The workflow scopes the token to this repository.
- **Fallback.** Enable "Allow GitHub Actions to create and approve pull
  requests". Pull requests opened with `GITHUB_TOKEN` start no `pull_request`
  run, so the required check stays pending: close and reopen the bot pull
  request (a human event) to run it. The regenerate job has already verified
  the tree before it pushed.
- **Private registry (optional).** The `regenerate` job logs in with variables
  `MARKETPLACE_REGISTRY` and `MARKETPLACE_REGISTRY_USER` and the secret
  `MARKETPLACE_REGISTRY_PASSWORD`, all held in the `marketplace` Environment
  (restricted to the default branch). `verify.yml` never reads them: it runs
  pull-request code, and a secret it read would be readable by anyone who can
  open a pull request from a branch. This repository reads public packages
  only, so `verify.yml` has no login. To verify a marketplace with private
  members, add a login step that uses a **separate pull-only read credential**
  and accept that anyone with write access can read it. Never reuse the
  `regenerate` credential there.
- **Keepalive.** A public repository's scheduled workflows are disabled after 60
  days without activity. The `keepalive` job calls the enable endpoint with only
  `actions: write`; whether that resets the timer is unverified, so if the
  schedule stops, re-enable `marketplace` in the Actions tab.

### Trust residual

Under `pull_request` the workflows, `scripts/` and the tool pins (`ocx.toml`,
`ocx.lock`) come from the pull request head, so a pull request can replace the
verifier. `CODEOWNERS` with required code-owner review on `.github/`,
`scripts/`, `ocx.toml` and `ocx.lock` is the mitigation. `CODEOWNERS` also covers
`marketplace.toml` and `marketplace.lock`: verification proves the output
renders the committed inputs, not where the pins came from, so the lock diff is
the review surface. A compromised upstream
artifact is out of scope: review shrinks the exposure window and is not a control
against it.

## Pinning a dev build

`ocx.toml` binds `grim` to a dev build published at `dev.ocx.sh/grimoire/cli`.
The tag in this commit is a placeholder (`0.15.0-dev_PENDING`). Set the
published tag, lock it, and commit both files in one change:

```sh
# ocx.toml: grim = "dev.ocx.sh/grimoire/cli:<version>-dev_<UTC timestamp>"
ocx lock
```

Until `ocx.lock` exists, `setup-ocx` has nothing to pull and the workflows fail
at the install step.

## The one step that differs from the documented workflow

The hosting guide installs grim from a release archive and checks a literal
`sha256`. This repository consumes a dev build, so it installs through
`ocx-sh/setup-ocx` in project mode, which pulls the version `ocx.lock` pins.
Everything else in `marketplace.yml` and `verify.yml` is the documented
workflow.

## Verified

Run 2026-09-29 on Linux with grim built from the branch that adds `grim export
marketplace` (`grim --version` 0.14.3), Claude Code 2.1.284, Copilot CLI 1.0.88
and Codex 0.153.4. Each tool ran against throwaway configuration directories, so
no real configuration was touched. The repository address is replaced by the
local directory, because the remote repository does not exist yet.

| Check | Command | Outcome |
|---|---|---|
| Claude add | `CLAUDE_CONFIG_DIR=$tmp claude plugin marketplace add <dir>` | added `grimoire-e2e` |
| Claude install | `claude plugin install grim-essentials@grimoire-e2e`, same for `hex` | both installed and enabled |
| Claude validate | `claude plugin validate .claude-plugin/marketplace.json`, `claude plugin validate claude/hex` | pass, one warning each (no `author`) |
| Claude pin | `npm install -g --prefix $tmp @anthropic-ai/claude-code@2.1.284`, then `plugin validate` with an empty `HOME` | installs in 2 s, validates headless, no login |
| Copilot add | `COPILOT_HOME=$tmp copilot plugin marketplace add <dir>` | added; `browse grimoire-e2e` lists both plugins |
| Copilot install | `copilot plugin install grim-essentials@grimoire-e2e` | installed 3 skills |
| Codex add | `CODEX_HOME=$tmp codex plugin marketplace add <dir>` | added; `codex plugin list` lists both plugins |
| Codex install | `codex plugin add grim-essentials@grimoire-e2e` | installed and enabled |
| Qoder | `qoder` CLI is not installed on the test machine | rests on the grim research probe, not run here |
| Gate | `sh scripts/gate-selftest.sh` | 25 cases pass: allowed set passes; an out-of-list path, an LFS path, an oversize file and each symlink form fail |
| Verify, clean | `scripts/marketplace-verify.sh` in a fresh clone, fresh `GRIM_HOME` | passes |
| Verify, tampered | same, after committing a hand edit, a stray file, a deleted file, an unselected client's marketplace file or tree, or a manifest-only plugin addition | each fails with the differing path; a renamed marketplace fails in the export |
| Regenerate | the `regenerate` job's `run:` blocks in a fresh clone, a local bare `origin` and a recording `gh` | unchanged tree stops before commit; a curator edit commits, verifies, pushes the bot branch and opens one pull request |

Not run: the workflows on GitHub, the App token path, `git push` to a real
remote, and Qoder.
