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
#   BASE_BRANCH  destination default branch (auto-detected if omitted)
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

read_version() {
    python3 - "$1" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as file:
    # Keep the exact version string, whether quoted or unquoted.
    config = yaml.load(file, Loader=yaml.BaseLoader) or {}
version = config.get("version")
if not isinstance(version, str) or not version.strip():
    sys.exit(f"No valid version found in {sys.argv[1]}")
print(version)
PY
}

if [ "$DRY_RUN" = 0 ]; then
    if [ -z "${BASE_BRANCH:-}" ]; then
        if base_ref=$(git symbolic-ref --quiet refs/remotes/origin/HEAD); then
            BASE_BRANCH=${base_ref#refs/remotes/origin/}
        else
            remote_head=$(git ls-remote --symref origin HEAD)
            BASE_BRANCH=$(sed -n $'s|^ref: refs/heads/\\(.*\\)\tHEAD$|\\1|p' <<< "$remote_head")
        fi
    fi
    base_ref="refs/remotes/origin/${BASE_BRANCH:-}"
    if ! git show-ref --verify --quiet "$base_ref"; then
        echo "::error::Destination default branch is not available locally: $base_ref" >&2
        exit 1
    fi
    if [ -n "$(git status --porcelain)" ]; then
        echo "::error::Start the sync with a clean working tree." >&2
        exit 1
    fi
    git checkout -q --detach "$base_ref"
fi

# Invoke this subshell directly, not as a condition: Bash disables errexit
# inside functions called from an if test or the left side of an OR-list.
sync_addon() (
    local addon=$1 source=$2 files_csv=$3
    local -a files
    IFS=, read -r -a files <<< "$files_csv"
    local checkout commit_sha new_version old_version

    echo "::group::$addon"
    checkout=$(mktemp -d)
    trap 'rm -rf "$checkout"; echo "::endgroup::"' EXIT
    git clone -q --depth 1 "https://github.com/$source.git" "$checkout/source"

    # The version in the source repository's config.yaml is the single
    # source of truth for releases (see the repository README).
    new_version=$(read_version "$checkout/source/config.yaml")
    old_version=
    if [ -f "$addon/config.yaml" ]; then
        old_version=$(read_version "$addon/config.yaml")
    fi

    if [ "$new_version" = "$old_version" ] && [ "$FORCE" = 0 ]; then
        echo "$addon is up to date at version $old_version."
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
            return 1
        else
            echo "Warning: $source does not contain $file, skipping it."
        fi
    done
    commit_sha=$(git -C "$checkout/source" rev-parse HEAD)

    # Changelog section of the new version, for the pull request body.
    local changelog
    changelog=$(python3 - "$addon/CHANGELOG.md" "$new_version" <<'PY'
"""Print the changelog section of the given version."""
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8") if path.is_file() else ""
version = re.escape(sys.argv[2])
match = re.search(
    rf"(?ms)^##[ \t]+(?:\[v?{version}\]|v?{version})(?=[ \t]|\r?$)[^\n]*\n"
    r"(.*?)(?=^##[ \t]|\Z)",
    text,
)
print(match.group(1).strip() if match
      else "No changelog entry found for this version.")
PY
    )

    if [ "$DRY_RUN" = 1 ]; then
        echo "Dry run: would commit and open a pull request for $addon $new_version."
        return 0
    fi

    # Commit from the destination default branch and push to a dedicated
    # bot branch. No local branch or origin/HEAD is required.
    local branch="sync/$addon"
    git add -A "$addon"
    if git diff --cached --quiet; then
        echo "No file changes for $addon, skipping."
        return 0
    fi
    git -c user.name="github-actions[bot]" \
        -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
        commit -qm "Sync $addon from $source at version $new_version"

    # Built with printf so changelog content is never interpreted by the
    # shell (it may contain markdown such as backticks).
    local body="$checkout/pr-body.md"
    {
        printf 'Syncs `%s` from [%s](https://github.com/%s) at version **%s**.\n\n' \
            "$addon" "$source" "$source" "$new_version"
        printf 'Source commit: https://github.com/%s/commit/%s\n\n' "$source" "$commit_sha"
        printf '## Changelog\n\n%s\n' "$changelog"
    } > "$body"

    local pr_number
    pr_number=$(gh pr list --base "$BASE_BRANCH" --head "$branch" --state open \
        --json number --jq '.[].number')
    git push -q --force origin "HEAD:refs/heads/$branch"
    if [ -z "$pr_number" ]; then
        if ! gh pr create --base "$BASE_BRANCH" --head "$branch" \
            --title "Sync $addon to $new_version" --body-file "$body"; then
            echo "::error::Could not create the pull request. Check the GitHub error above and the Actions settings in README.md." >&2
            return 1
        fi
        echo "Opened a pull request for $addon $new_version."
    else
        gh pr edit "$pr_number" --title "Sync $addon to $new_version" --body-file "$body"
        echo "Updated pull request #$pr_number for $addon $new_version."
    fi
    git checkout -q --detach "$base_ref"
)

matched=0
while IFS=$'\t' read -r addon source files; do
    [ -n "$ONLY_ADDON" ] && [ "$addon" != "$ONLY_ADDON" ] && continue
    matched=1
    sync_addon "$addon" "$source" "$files"
done <<< "$entries"
if [ "$matched" = 0 ]; then
    echo "::error::Unknown add-on: $ONLY_ADDON" >&2
    exit 1
fi
