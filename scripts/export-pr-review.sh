#!/usr/bin/env sh
set -eu

usage() {
    cat <<'USAGE'
Usage: scripts/export-pr-review.sh [options]

Build a single-file PR review bundle for a strong model.

Options:
  -o, --output PATH       Write bundle to PATH
      --repo PATH         Export from another git checkout
      --base REV          Base revision (default: merge-base with origin/main)
      --head REV          Head revision (default: HEAD)
      --pr NUMBER_OR_URL  Include PR metadata from GitHub when gh is available
      --path PATH         Add an extra context path from the head revision
      --no-status         Skip local working tree status
      --no-diff           Skip full unified diff
  -h, --help              Show this help

The bundle includes PR metadata when available, commit list, diffstat,
changed-file list, optional full diff, and the head-revision contents of
changed files plus a small set of architecture/security context files.

Examples:
  scripts/export-pr-review.sh --pr 885
  scripts/export-pr-review.sh --base 00733b3 --head 9a2c97c \
    --output nullclaw-pr-review-artak-dg1-dg2.md
USAGE
}

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

repo_arg=""
output_arg=""
base_arg=""
head_arg="HEAD"
pr_arg=""
include_diff=1
include_status=1

tmp_changed=$(mktemp "${TMPDIR:-/tmp}/nullclaw-pr-review-changed.XXXXXX")
tmp_context=$(mktemp "${TMPDIR:-/tmp}/nullclaw-pr-review-context.XXXXXX")
tmp_manifest=$(mktemp "${TMPDIR:-/tmp}/nullclaw-pr-review-manifest.XXXXXX")
tmp_output=$(mktemp "${TMPDIR:-/tmp}/nullclaw-pr-review-output.XXXXXX")

cleanup() {
    rm -f "$tmp_changed" "$tmp_context" "$tmp_manifest" "$tmp_output"
}
trap cleanup EXIT HUP INT TERM

while [ "$#" -gt 0 ]; do
    case "$1" in
        -o|--output)
            [ "$#" -ge 2 ] || die "missing value for $1"
            output_arg=$2
            shift 2
            ;;
        --repo)
            [ "$#" -ge 2 ] || die "missing value for --repo"
            repo_arg=$2
            shift 2
            ;;
        --base)
            [ "$#" -ge 2 ] || die "missing value for --base"
            base_arg=$2
            shift 2
            ;;
        --head)
            [ "$#" -ge 2 ] || die "missing value for --head"
            head_arg=$2
            shift 2
            ;;
        --pr)
            [ "$#" -ge 2 ] || die "missing value for --pr"
            pr_arg=$2
            shift 2
            ;;
        --path)
            [ "$#" -ge 2 ] || die "missing value for --path"
            printf '%s\n' "$2" >> "$tmp_context"
            shift 2
            ;;
        --no-diff)
            include_diff=0
            shift
            ;;
        --no-status)
            include_status=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

if [ -n "$repo_arg" ]; then
    repo_root=$(cd "$repo_arg" && pwd -P)
else
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git checkout"
fi

git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git checkout: $repo_root"
git -C "$repo_root" rev-parse --verify "$head_arg^{commit}" >/dev/null 2>&1 || die "unknown head revision: $head_arg"

head_rev=$(git -C "$repo_root" rev-parse "$head_arg")
head_short=$(git -C "$repo_root" rev-parse --short "$head_rev")

if [ -z "$base_arg" ]; then
    if git -C "$repo_root" rev-parse --verify origin/main >/dev/null 2>&1; then
        base_arg=$(git -C "$repo_root" merge-base "$head_rev" origin/main)
    elif git -C "$repo_root" rev-parse --verify main >/dev/null 2>&1; then
        base_arg=$(git -C "$repo_root" merge-base "$head_rev" main)
    else
        base_arg="$head_rev^"
    fi
fi

git -C "$repo_root" rev-parse --verify "$base_arg^{commit}" >/dev/null 2>&1 || die "unknown base revision: $base_arg"
base_rev=$(git -C "$repo_root" rev-parse "$base_arg")
base_short=$(git -C "$repo_root" rev-parse --short "$base_rev")

if [ -n "$output_arg" ]; then
    case "$output_arg" in
        /*) output_path=$output_arg ;;
        *) output_path=$(pwd -P)/$output_arg ;;
    esac
else
    output_path=$repo_root/nullclaw-pr-review-$head_short.md
fi

mkdir -p "$(dirname "$output_path")"

is_text_blob() {
    path=$1

    case "$path" in
        *.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.pdf|*.db|*.db-journal|*.a|*.o|*.wasm)
            return 1
            ;;
        *)
            blob_exists "$path"
            ;;
    esac
}

blob_exists() {
    path=$1
    git -C "$repo_root" cat-file -e "$head_rev:$path" 2>/dev/null
}

add_context_if_exists() {
    path=$1
    if blob_exists "$path"; then
        printf '%s\n' "$path" >> "$tmp_context"
    fi
}

git -C "$repo_root" diff --name-only --diff-filter=ACMRT "$base_rev" "$head_rev" > "$tmp_changed"

add_context_if_exists AGENTS.md
add_context_if_exists README.md
add_context_if_exists build.zig
add_context_if_exists src/root.zig
add_context_if_exists src/config.zig
add_context_if_exists src/config_types.zig
add_context_if_exists src/session.zig
add_context_if_exists src/agent/root.zig
add_context_if_exists src/agent/compaction.zig
add_context_if_exists src/providers/root.zig
add_context_if_exists src/providers/scrub.zig
add_context_if_exists src/providers/helpers.zig
add_context_if_exists src/memory/root.zig
add_context_if_exists src/memory/lifecycle/hygiene.zig
add_context_if_exists src/memory/vector/math.zig
add_context_if_exists src/tools/root.zig
add_context_if_exists docs/en/commands.md
add_context_if_exists docs/en/security.md

cat "$tmp_changed" "$tmp_context" |
    awk 'NF && !seen[$0]++ { print }' |
    while IFS= read -r path; do
        if blob_exists "$path" && is_text_blob "$path"; then
            printf '%s\n' "$path"
        fi
    done > "$tmp_manifest"

file_count=$(wc -l < "$tmp_manifest" | tr -d ' ')
changed_count=$(wc -l < "$tmp_changed" | tr -d ' ')
generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
branch_name=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')

{
    printf '# nullclaw PR Review Bundle\n\n'
    printf 'Generated: %s\n' "$generated_at"
    printf 'Repository: %s\n' "$repo_root"
    printf 'Current branch: %s\n' "$branch_name"
    printf 'Base: %s (%s)\n' "$base_arg" "$base_short"
    printf 'Head: %s (%s)\n' "$head_arg" "$head_short"
    printf 'Changed files in range: %s\n' "$changed_count"
    printf 'Included text files: %s\n\n' "$file_count"

    if [ -n "$pr_arg" ] && command -v gh >/dev/null 2>&1; then
        printf '## GitHub PR Metadata\n\n'
        if gh pr view "$pr_arg" --repo nullclaw/nullclaw --json url,title,isDraft,baseRefName,headRefName,body 2>/dev/null; then
            printf '\n\n'
        else
            printf 'Unable to load PR metadata with gh for `%s`.\n\n' "$pr_arg"
        fi
    fi

    if [ "$include_status" -eq 1 ]; then
        printf '## Local Git Status\n\n'
        printf '```text\n'
        git -C "$repo_root" status --short --branch || true
        printf '```\n\n'
    fi

    printf '## Commit List\n\n'
    printf '```text\n'
    git -C "$repo_root" log --oneline --decorate "$base_rev..$head_rev" || true
    printf '```\n\n'

    printf '## Diffstat\n\n'
    printf '```text\n'
    git -C "$repo_root" diff --stat "$base_rev" "$head_rev" || true
    printf '```\n\n'

    printf '## Changed Files\n\n'
    if [ "$changed_count" -eq 0 ]; then
        printf 'No changed files in this range.\n'
    else
        while IFS= read -r path; do
            printf -- '- `%s`\n' "$path"
        done < "$tmp_changed"
    fi
    printf '\n'

    if [ "$include_diff" -eq 1 ]; then
        printf '## Full Unified Diff\n\n'
        printf '```diff\n'
        git -C "$repo_root" diff --find-renames "$base_rev" "$head_rev" || true
        printf '```\n\n'
    fi

    printf '## Included File Index\n\n'
    while IFS= read -r path; do
        bytes=$(git -C "$repo_root" cat-file -s "$head_rev:$path" 2>/dev/null || printf '0')
        printf -- '- `%s` (%s bytes)\n' "$path" "$bytes"
    done < "$tmp_manifest"
    printf '\n'

    printf '## Included File Contents\n\n'
    while IFS= read -r path; do
        printf '<<<BEGIN_FILE: %s>>>\n' "$path"
        git -C "$repo_root" show "$head_rev:$path"
        printf '\n<<<END_FILE: %s>>>\n\n' "$path"
    done < "$tmp_manifest"
} > "$tmp_output"

mv "$tmp_output" "$output_path"
printf 'Wrote PR review bundle for %s..%s with %s changed files and %s included files to %s\n' \
    "$base_short" "$head_short" "$changed_count" "$file_count" "$output_path"
