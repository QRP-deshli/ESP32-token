#!/usr/bin/env bash
# Files every issue in this folder on GitHub using the GitHub CLI (https://cli.github.com; run `gh auth login` first).
#
#   ./create-issues.sh                  # the repository of the current directory
#   ./create-issues.sh owner/repo       # a specific repository
#   ./create-issues.sh --dry-run        # only list what would be created
#
# Each NN-*.md file has a small front matter: title: "..." and labels: a,b,c. Run it ONCE (it does not check for duplicates).
set -u
cd "$(dirname "$0")" || exit 1

dry=0; repo=""
for a in "$@"; do
    case "$a" in
        --dry-run|-n) dry=1 ;;
        *) repo="$a" ;;
    esac
done

if [ "$dry" = 0 ] && ! command -v gh >/dev/null 2>&1; then
    echo "The GitHub CLI 'gh' is not installed: https://cli.github.com" >&2
    exit 1
fi

gh_repo() { if [ -n "$repo" ]; then gh "$@" --repo "$repo"; else gh "$@"; fi; }

for f in [0-9][0-9]-*.md; do
    title="$(sed -n 's/^title: *"\(.*\)" *$/\1/p' "$f" | head -n1)"
    labels="$(sed -n 's/^labels: *//p' "$f" | head -n1)"
    if [ -z "$title" ]; then echo "skipping $f: no title" >&2; continue; fi
    if [ "$dry" = 1 ]; then
        echo "[dry run] $f -> \"$title\" [$labels]"
        continue
    fi
    # create the labels first (harmless if they exist)
    old_ifs="$IFS"; IFS=','
    for l in $labels; do gh_repo label create "$l" --force >/dev/null 2>&1 || true; done
    IFS="$old_ifs"
    body="$(mktemp)"
    awk '/^---$/ && n < 2 { n++; next } n >= 2 { print }' "$f" > "$body"
    gh_repo issue create --title "$title" --label "$labels" --body-file "$body"
    rm -f "$body"
done
