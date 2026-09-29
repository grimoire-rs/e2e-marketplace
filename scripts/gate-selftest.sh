#!/bin/sh
# Self-test of marketplace-gate.sh and pr-body.sh against crafted repositories
# and reports. No network, no grim. Run from anywhere:
#
#   sh scripts/gate-selftest.sh
#
# Exit 0 when every case behaves, 1 otherwise.
set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
gate=$here/marketplace-gate.sh
prbody=$here/pr-body.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
failures=0

ok() { printf 'ok    %s\n' "$1"; }
bad() {
    printf 'FAIL  %s\n' "$1"
    failures=$((failures + 1))
}

# expect <want: pass|fail> <label> <repo> [manifest]
# Regenerates the crafted report for <repo> and runs the gate inside it.
expect() {
    want=$1 label=$2 repo=$3 manifest=${4:-marketplace.toml}
    mdir=$(dirname "$manifest")
    [ "$mdir" = . ] && rel="" || rel=$mdir/
    cat >"$work/export.json" <<EOF
{
  "items": [
    {
      "plugin": "team",
      "client": "claude",
      "path": "$repo/${rel}claude/team"
    }
  ],
  "files": [
    {
      "client": "claude",
      "path": "$repo/${rel}.claude-plugin/marketplace.json",
      "action": "written",
      "plugins": [
        "team"
      ]
    },
    {
      "client": "copilot",
      "path": "$repo/${rel}.github/plugin/marketplace.json",
      "action": "written",
      "plugins": [
        "team"
      ]
    }
  ]
}
EOF
    # `fail` means exit 1 (a violation), not exit 2 (bad input): a gate that
    # merely crashes must not pass as a rejection.
    rc=0
    (cd "$repo" && MAX_FILE_BYTES=${MAX_FILE_BYTES:-100} sh "$gate" "$manifest" "$work/export.json") >/dev/null 2>"$work/err" || rc=$?
    case $rc in 0) got=pass ;; 1) got=fail ;; *) got="exit-$rc" ;; esac
    if [ "$got" = "$want" ]; then ok "$label"; else
        bad "$label (wanted $want, got $got)"
        sed 's/^/        /' "$work/err"
    fi
}

# A committed baseline: manifest, lock, both marketplace files, one tree.
mkrepo() {
    r=$work/$1
    rel=${2:-}
    mkdir -p "$r/${rel}.claude-plugin" "$r/${rel}.github/plugin" "$r/${rel}claude/team" "$r/.github/workflows"
    (
        cd "$r"
        git init -q -b main .
        git config user.email t@example.invalid
        git config user.name t
        printf 'x' >"${rel}marketplace.toml"
        printf 'x' >"${rel}marketplace.lock"
        printf '{}' >"${rel}.claude-plugin/marketplace.json"
        printf '{}' >"${rel}.github/plugin/marketplace.json"
        printf 'a' >"${rel}claude/team/a.txt"
        printf 'ci' >.github/workflows/ci.yml
        printf 'readme' >README.md
        git add -A
        git commit -q -m base
    )
    printf '%s' "$r"
}

# 1. allowed set: every kind of change the export may produce -> pass
r=$(mkrepo allowed)
printf 'y' >"$r/marketplace.lock"
printf '{"a":1}' >"$r/.claude-plugin/marketplace.json"
printf 'b' >"$r/claude/team/b.txt"
mkdir -p "$r/claude/other" "$r/copilot/team"
printf 'c' >"$r/claude/other/c.txt"
printf 'd' >"$r/copilot/team/d.txt"
rm "$r/claude/team/a.txt"
expect pass "allowed set: lock, marketplace file, tree add/edit/remove" "$r"

# 2. nothing changed -> pass
r=$(mkrepo clean)
expect pass "clean tree" "$r"

# 3. out-of-list paths -> fail
r=$(mkrepo outside1)
printf 'evil' >"$r/evil.txt"
expect fail "untracked path outside the list" "$r"
r=$(mkrepo outside2)
printf 'evil' >"$r/.github/workflows/ci.yml"
expect fail "workflow file edited" "$r"
r=$(mkrepo outside3)
printf 'evil' >"$r/README.md"
printf 'y' >"$r/marketplace.lock"
expect fail "allowed change mixed with a README edit" "$r"
r=$(mkrepo outside4)
printf 'evil' >"$r/claudex.txt"
expect fail "prefix look-alike (claudex.txt vs claude/)" "$r"
r=$(mkrepo outside5)
printf 'evil' >"$r/marketplace.toml"
expect fail "manifest edited by the run" "$r"
r=$(mkrepo outside6)
mkdir -p "$r/qoder/team"
printf 'q' >"$r/qoder/team/q.txt"
expect fail "client dir the report does not name" "$r"

# 4. LFS-attributed path -> fail
r=$(mkrepo lfs)
printf 'claude/** filter=lfs diff=lfs merge=lfs -text\n' >"$r/.git/info/attributes"
printf 'e' >"$r/claude/team/model.bin"
expect fail "path with filter=lfs (info/attributes)" "$r"
r=$(mkrepo lfs2)
printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' >"$r/claude/.gitattributes"
printf 'e' >"$r/claude/team/model.bin"
expect fail "path with filter=lfs (.gitattributes in the tree)" "$r"

# 5. oversize -> fail
r=$(mkrepo big)
head -c 200 /dev/zero >"$r/claude/team/big.bin"
expect fail "file over MAX_FILE_BYTES" "$r"
r=$(mkrepo big2)
head -c 100 /dev/zero >"$r/claude/team/edge.bin"
expect pass "file exactly at MAX_FILE_BYTES" "$r"

# 6. symlink -> fail
r=$(mkrepo link)
# a small target: only the symlink rule can reject it, not the size cap
ln -s a.txt "$r/claude/team/link"
expect fail "symlink inside an allowed dir" "$r"
r=$(mkrepo link2)
rm "$r/claude/team/a.txt"
ln -s nowhere "$r/claude/team/a.txt"
expect fail "tracked file replaced by a symlink" "$r"
r=$(mkrepo link3)
rm -r "$r/claude"
ln -s /etc "$r/claude"
expect fail "client dir replaced by a symlink" "$r"

# 7. a path with a newline -> fail
r=$(mkrepo newline)
nl='
'
printf 'n' >"$r/claude/team/a${nl}?? marketplace.lock"
expect fail "newline in a changed path" "$r"

# 8. manifest in a subdirectory: the allow-list moves with it
r=$(mkrepo sub tests/)
printf 'y' >"$r/tests/marketplace.lock"
printf 'b' >"$r/tests/claude/team/b.txt"
expect pass "subdir manifest: lock and tree under tests/" "$r" tests/marketplace.toml
r=$(mkrepo sub2 tests/)
mkdir -p "$r/claude"
printf 'b' >"$r/claude/b.txt"
expect fail "subdir manifest: root claude/ is outside the list" "$r" tests/marketplace.toml

# 9. a report with no files[] fails closed (exit 2)
r=$(mkrepo empty)
printf '{"items": [], "files": []}\n' >"$work/empty.json"
rc=0
(cd "$r" && sh "$gate" marketplace.toml "$work/empty.json") >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then ok "empty files[] fails closed (exit 2)"; else bad "empty files[] must exit 2, got $rc"; fi

# 10. pr-body: hostile names, pins, oversize
digest=sha256:$(printf '%064d' 1)
cat >"$work/upd.json" <<EOF
{"items": [
 {"plugin": "team", "kind": "skill", "name": "plan", "old": null, "new": "$digest", "action": "updated"},
 {"plugin": "<img src=x onerror=1>", "kind": "skill", "name": "plan", "old": null, "new": "$digest", "action": "updated"},
 {"plugin": "team", "kind": "skill", "name": "ok\n", "old": null, "new": "$digest", "action": "updated"},
 {"plugin": "team", "kind": "skill", "name": "x", "old": "sha256:zz", "new": "$digest", "action": "updated"}
]}
EOF
cat >"$work/exp.json" <<EOF
{"items": [
 {"plugin": "team", "client": "claude", "version": "1.0.0+abc", "action": "written",
  "members": [{"pinned": "ghcr.io/o/plan@$digest"}]},
 {"plugin": "team", "client": "copilot", "version": "1.0.0", "action": "written",
  "members": [{"pinned": "ghcr.io/o/plan@sha256:short"}]},
 {"plugin": "team", "client": "codex", "version": "1.0.0", "action": "written",
  "members": [{"pinned": "x @evil@$digest"}]}
]}
EOF
body=$(sh "$prbody" "$work/upd.json" "$work/exp.json")
case $body in *'<img'*) bad "pr-body: hostile plugin name rendered" ;; *) ok "pr-body: hostile plugin name dropped" ;; esac
# shellcheck disable=SC2016 # literal backticks: the body renders names as code
case $body in *'`plan`'*) ok "pr-body: valid row kept" ;; *) bad "pr-body: valid row missing" ;; esac
case $body in *'5 row(s) failed validation'*) ok "pr-body: drops are counted" ;; *) bad "pr-body: drops not counted" ;; esac
case $body in *evil*) bad "pr-body: bad pin rendered" ;; *) ok "pr-body: malformed pins dropped" ;; esac
case $body in *sha256:zz*) bad "pr-body: bad digest rendered" ;; *) ok "pr-body: malformed digest dropped" ;; esac
# cap
awk -v d="$digest" 'BEGIN { printf "{\"items\": ["; for (i = 0; i < 2000; i++) printf "%s{\"plugin\":\"team\",\"kind\":\"skill\",\"name\":\"a%d\",\"old\":null,\"new\":\"%s\",\"action\":\"updated\"}", (i ? "," : ""), i, d; print "]}" }' >"$work/many.json"
n=$(sh "$prbody" "$work/many.json" "$work/exp.json" | wc -c)
if [ "$n" -le 60000 ]; then ok "pr-body: capped at 60000 ($n bytes)"; else bad "pr-body: $n bytes exceeds the cap"; fi

if [ "$failures" -ne 0 ]; then
    printf '%d case(s) failed\n' "$failures" >&2
    exit 1
fi
echo "all cases ok"
