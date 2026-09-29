#!/bin/sh
# Build the pull-request body from grim's JSON reports and print it.
#
#   pr-body.sh <update.json> <export.json>
#
# Every value that reaches the body comes from tool output that a registry
# publisher influences, so nothing is copied as-is: plugin names must match
# the plugin-name grammar (`[a-z0-9]+([.-][a-z0-9]+)*`, at most 64 characters),
# pins must be an OCI reference ending in `@sha256:<64 hex>`, digests, versions,
# kinds, clients and actions must match a closed shape. A row with any other
# value is dropped and counted, never rendered. The result is capped at 60000
# characters. The caller passes it with `gh pr create|edit --body-file`.
#
# Needs jq. POSIX sh.
set -eu

[ "$#" -eq 2 ] || {
    echo "usage: pr-body.sh <update.json> <export.json>" >&2
    exit 2
}
[ -f "$1" ] && [ -f "$2" ] || {
    echo "pr-body: report not found" >&2
    exit 2
}

jq -r -n --slurpfile upd "$1" --slurpfile exp "$2" '
def name_ok: type == "string" and length <= 64 and test("\\A[a-z0-9]+([.-][a-z0-9]+)*\\z");
def word_ok: type == "string" and test("\\A[a-z][a-z-]{0,15}\\z");
def digest_ok: type == "string" and test("\\Asha256:[0-9a-f]{64}\\z");
def opt_digest_ok: . == null or digest_ok;
def ver_ok: type == "string" and length <= 128 and test("\\A[0-9A-Za-z][0-9A-Za-z.+-]*\\z");
def pin_ok: type == "string" and length <= 512 and test("\\A[a-z0-9][a-z0-9._:/-]*@sha256:[0-9a-f]{64}\\z");
def short: if . == null then "-" else "`" + .[7:19] + "`" end;

($upd[0].items // []) as $u
| ($exp[0].items // []) as $e
| [$u[] | select(.action != "unchanged")] as $ur
| [$e[] | select(.action != "unchanged")] as $er
| [$ur[] | select((.plugin | name_ok) and (.name | name_ok) and (.kind | word_ok)
                  and (.action | word_ok) and (.old | opt_digest_ok) and (.new | opt_digest_ok))] as $uok
| [$er[] | select((.plugin | name_ok) and (.client | word_ok) and (.action | word_ok)
                  and (.version == null or (.version | ver_ok))
                  and ([.members[]? | .pinned | pin_ok] | all))] as $eok
| (($ur | length) - ($uok | length)) as $ud
| (($er | length) - ($eok | length)) as $ed
| ([ "## Marketplace regeneration",
     "",
     "`grim update --marketplace` and `grim export marketplace` regenerated the marketplace from `marketplace.toml`.",
     "**Merging publishes**: clients that follow this repository pick the change up on their next refresh.",
     "",
     "### Pin changes",
     "",
     (if ($uok | length) == 0 then "None."
      else "| Plugin | Kind | Artifact | Action | Old | New |\n|---|---|---|---|---|---|\n"
           + ([$uok[] | "| `\(.plugin)` | \(.kind) | `\(.name)` | \(.action) | \(.old | short) | \(.new | short) |"] | join("\n"))
      end),
     "",
     "### Plugin trees",
     "",
     (if ($eok | length) == 0 then "None."
      else "| Plugin | Client | Version | Action |\n|---|---|---|---|\n"
           + ([$eok[] | "| `\(.plugin)` | \(.client) | \(if .version == null then "-" else "`" + .version + "`" end) | \(.action) |"] | join("\n"))
      end),
     (if $ud + $ed > 0 then "\n\(($ud + $ed)) row(s) failed validation and are not shown; check the workflow log." else empty end),
     ""
   ] | join("\n")) as $body
| if ($body | length) > 60000
  then $body[0:59900] + "\n\n_Truncated: the report exceeds the pull-request body limit._\n"
  else $body end
'
