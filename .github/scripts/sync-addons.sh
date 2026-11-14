#!/usr/bin/env bash
# Add-on sync bot.
#
# Keeps the add-on directories in this repository in sync with their source
# repositories (see addons.yaml). A release in a source repository is a
# version bump in its config.yaml on the default branch. Whenever the bot
# detects a new version, it replaces the add-on's metadata files with the
# configured set from the source repository and opens a pull request
# containing the new changelog.
#
# Usage:
#   sync-addons.sh [addon]    sync all add-ons, or only the named one
#
# Environment:
#   GH_TOKEN     GitHub token for pull requests (optional in dry runs)
#   DRY_RUN=1    apply the file changes, but skip branch, push and PR
#   FORCE=1      sync even when the versions already match
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

ONLY_ADDON=${1:-}
case "${DRY_RUN:-0}" in 1|true) DRY_RUN=1;; *) DRY_RUN=0;; esac
case "${FORCE:-0}" in 1|true) FORCE=1;; *) FORCE=0;; esac

git rev-parse --is-inside-work-tree > /dev/null 2>&1 \
    || { echo "::error::Not a git repository: $ROOT" >&2; exit 1; }

[ -f addons.yaml ] || { echo "::error::addons.yaml not found" >&2; exit 1; }

# One "name<TAB>source<TAB>comma-separated-files" line per add-on.
entries=$(python3 - addons.yaml <<'PY'
"""Print the add-on sync entries defined in addons.yaml."""
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as file:
    data = yaml.safe_load(file) or {}

default_files = [
    "config.yaml", "icon.png", "logo.png", "logo.svg",
    "CHANGELOG.md", "README.md", "DOCS.md",
]
for name, config in (data.get("addons") or {}).items():
    files = config.get("files") or default_files
    print(f"{name}\t{config['source']}\t{','.join(files)}")
PY
)
[ -n "$entries" ] || { echo "::error::No add-ons defined in addons.yaml" >&2; exit 1; }

sync_addon() {
    local addon=$1 source=$2 files_csv=$3
    local files=(${files_csv//,/ })
    local checkout commit_sha new_version old_version

    echo "::group::$addon"
    checkout=$(mktemp -d)
    git clone -q --depth 1 "https://github.com/$source.git" "$checkout/source"

    # The version in the source repository's config.yaml is the single
    # source of truth for releases (see the repository README).
    new_version=$(sed -n 's/^version:[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' "$checkout/source/config.yaml")
    old_version=$(sed -n 's/^version:[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' "$addon/config.yaml" 2> /dev/null || true)
    if [ -z "$new_version" ]; then
        echo "::error::$addon: no version found in $source/config.yaml"
        rm -rf "$checkout"
        return 1
    fi

    if [ "$new_version" = "$old_version" ] && [ "$FORCE" = 0 ]; then
        echo "$addon is up to date at version $old_version."
        rm -rf "$checkout"
        echo "::endgroup::"
        return 0
    fi
    echo "$addon: $old_version -> $new_version (source: $source)"

    # The add-on directory is fully managed by this bot: replace it with
    # the configured metadata files from the source repository. The store
    # never contains build files; users install the published GHCR image.
    rm -rf "$addon"
    mkdir -p "$addon"
    local file
    for file in "${files[@]}"; do
        if [ -e "$checkout/source/$file" ]; then
            mkdir -p "$addon/$(dirname "$file")"
            cp -a "$checkout/source/$file" "$addon/$file"
        elif [ "$file" = config.yaml ]; then
            echo "::error::$addon: config.yaml is missing in $source"
            rm -rf "$checkout"
            return 1
        else
            echo "Warning: $source does not contain $file, skipping it."
        fi
    done
    commit_sha=$(git -C "$checkout/source" rev-parse HEAD)
    rm -rf "$checkout"

    # Changelog section of the new version, for the pull request body.
    local changelog
    changelog=$(python3 - "$addon/CHANGELOG.md" "$new_version" <<'PY'
"""Print the changelog section of the given version."""
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
version = re.escape(sys.argv[2])
match = re.search(rf"(?ms)^## {version}[^\n]*\n(.*?)(?=^## |\Z)", text)
print(match.group(1).strip() if match
      else "No changelog entry found for this version.")
PY
    )

    if [ "$DRY_RUN" = 1 ]; then
        echo "Dry run: would commit and open a pull request for $addon $new_version."
        echo "::endgroup::"
        return 0
    fi

    # One branch per add-on, always recreated from the default branch.
    # An open pull request on the branch is updated by the force push.
    local branch="sync/$addon"
    local base
    base=$(git rev-parse --abbrev-ref origin/HEAD 2> /dev/null || true)
    base=${base#origin/}
    [ -n "$base" ] || base=main
    git checkout -q -B "$branch" "origin/$base"

    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git add -A "$addon"
    if git diff --cached --quiet; then
        echo "No file changes for $addon, skipping."
        git checkout -q --detach "origin/$base"
        echo "::endgroup::"
        return 0
    fi
    git commit -qm "Sync $addon from $source at version $new_version"

    # Built with printf so changelog content is never interpreted by the
    # shell (it may contain markdown such as backticks).
    local body
    body=$(mktemp)
    {
        printf 'Syncs `%s` from [%s](https://github.com/%s) at version **%s**.\n\n' \
            "$addon" "$source" "$source" "$new_version"
        printf 'Source commit: https://github.com/%s/commit/%s\n\n' "$source" "$commit_sha"
        printf '## Changelog\n\n%s\n' "$changelog"
    } > "$body"

    git push -q --force origin "$branch"
    if [ -z "$(gh pr list --head "$branch" --state open --json number --jq '.[].number' 2> /dev/null)" ]; then
        gh pr create --title "Sync $addon to $new_version" --body-file "$body" --head "$branch"
        echo "Opened a pull request for $addon $new_version."
    else
        echo "Updated the existing pull request for $addon (branch $branch)."
    fi
    rm -f "$body"
    git checkout -q --detach "origin/$base"
    echo "::endgroup::"
}

status=0
while IFS=$'\t' read -r addon source files; do
    [ -n "$ONLY_ADDON" ] && [ "$addon" != "$ONLY_ADDON" ] && continue
    sync_addon "$addon" "$source" "$files" || status=1
done <<< "$entries"
exit $status
