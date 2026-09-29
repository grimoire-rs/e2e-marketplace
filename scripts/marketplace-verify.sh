#!/bin/sh
# Verification of a committed marketplace: regenerate it in place and require
# that git sees no difference.
#
#   marketplace-verify.sh [<manifest>]        (default ./marketplace.toml)
#
# Steps, in the checkout (nothing is copied):
#   1. No git submodule (mode 160000 entry) may sit at, beneath or above an
#      owned path: git reports neither changes inside a gitlink nor the
#      untracked files under it, so step 2 could not see a regenerated tree
#      there. Then `grim export marketplace --marketplace <manifest> --format json`
#      regenerates the marketplace files and trees where they live, from the
#      committed `<stem>.lock`. A curator edit to the manifest that the lock
#      does not cover shows up as a difference in step 2 (or fails here).
#   2. `git status` over the lock, every marketplace file and every client
#      directory the table defines (selected or not) must print nothing:
#      an edited, deleted, added or ignored owned file, a dropped client's
#      leftovers and a re-resolved lock all show up.
#   3. A client the report does not select must have no tracked marketplace
#      file and no tracked `<client>/` entry (a foreign or dropped tree would
#      otherwise pass step 2 untouched).
#   4. `claude plugin validate` (no --strict) over the Claude marketplace file
#      and every `claude/<plugin>` tree.
#
# Needs grim and claude on PATH, plus git, awk, tr, mktemp. POSIX sh.
set -eu

die() {
    printf 'verify: %s\n' "$*" >&2
    exit 1
}

manifest=${1:-./marketplace.toml}
[ -f "$manifest" ] || die "manifest not found: $manifest"
abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }
mdir=$(abs_dir "$(dirname "$manifest")") || die "manifest directory not found"
manifest=$mdir/$(basename "$manifest")
top=$(abs_dir "$(git -C "$mdir" rev-parse --show-toplevel)") || die "not inside a git repository"
cd "$top"
case $mdir in
    "$top") rel="" ;;
    "$top"/*) rel=${mdir#"$top"/}/ ;;
    *) die "manifest is outside the repository" ;;
esac
lock="$rel$(basename "$manifest" | sed 's/\.[^.]*$//').lock"

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/marketplace-verify.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

# The table: client, marketplace file. The tree directory is the client name.
table_file() {
    case $1 in
        claude) echo .claude-plugin/marketplace.json ;;
        copilot) echo .github/plugin/marketplace.json ;;
        codex) echo .agents/plugins/marketplace.json ;;
        qoder) echo .qoder-plugin/marketplace.json ;;
        cursor) echo .cursor-plugin/marketplace.json ;;
    esac
}
table_clients="claude copilot codex qoder cursor"

# The owned paths: the lock, every marketplace file, every client directory.
set -- "$lock"
for c in $table_clients; do
    set -- "$@" "$rel$(table_file "$c")" "$rel$c/"
done
printf '%s\n' "$@" >"$work/owned"

echo "verify: 1/4 no submodule on an owned path, regenerating in place"
git ls-files -s -z | tr '\0' '\n' | awk -F'\t' '
    NR == FNR { o = $0; sub(/\/$/, "", o); own[++n] = o; next }
    $1 ~ /^160000 / {
        p = $2
        for (i = 1; i <= n; i++)
            if (p == own[i] || index(own[i] "/", p "/") == 1 || index(p "/", own[i] "/") == 1) {
                print p; break
            }
    }
' "$work/owned" - >"$work/gitlinks"
if [ -s "$work/gitlinks" ]; then
    sed 's/^/verify:   /' <"$work/gitlinks" >&2
    die "a git submodule overlaps an owned path (paths above)"
fi
grim export marketplace --marketplace "$manifest" --format json >"$work/verify.json" ||
    die "grim export marketplace failed"

awk '
    /^[ \t]*"files"[ \t]*:[ \t]*\[/ { f = 1; next }
    f && /^[ \t]*"client"[ \t]*:[ \t]*"/ {
        v = $0; sub(/^[ \t]*"client"[ \t]*:[ \t]*"/, "", v); sub(/".*$/, "", v); print v
    }
' "$work/verify.json" | sort -u >"$work/selected"
[ -s "$work/selected" ] || die "the export report names no client (fail closed)"
while IFS= read -r c; do
    case $c in
        '' | *[!a-z]*) die "malformed client in the report: $c" ;;
    esac
    case " $table_clients " in
        *" $c "*) ;;
        *) die "the report names a client outside the table: $c" ;;
    esac
done <"$work/selected"

echo "verify: 2/4 git status over the owned paths"
git status --porcelain=v1 -z --untracked-files=all --ignored=matching -- "$@" >"$work/status"
if [ -s "$work/status" ]; then
    tr '\0' '\n' <"$work/status" | sed 's/^/verify:   /' >&2
    die "the committed marketplace differs from a fresh export (paths above)"
fi

echo "verify: 3/4 unselected clients carry no tracked content"
for c in $table_clients; do
    grep -qx "$c" "$work/selected" && continue
    git ls-files -z -- "$rel$(table_file "$c")" "$rel$c/" >"$work/tracked"
    if [ -s "$work/tracked" ]; then
        tr '\0' '\n' <"$work/tracked" | sed 's/^/verify:   /' >&2
        die "client '$c' is not selected but has tracked content (paths above)"
    fi
done

echo "verify: 4/4 claude plugin validate"
if grep -qx claude "$work/selected"; then
    claude plugin validate "$rel.claude-plugin/marketplace.json" ||
        die "claude plugin validate failed on the marketplace file"
    for d in "$rel"claude/*/; do
        [ -d "$d" ] || continue
        claude plugin validate "${d%/}" || die "claude plugin validate failed on ${d%/}"
    done
else
    echo "verify: claude is not selected, nothing to validate"
fi
echo "verify: ok"
