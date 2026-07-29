#!/usr/bin/env bash
#
# Publishes a built dist package into a version branch of another git repository.
#
# The target branch is derived from the release tag as "<major>.<minor>"
# (e.g. "6.4.6-p2607131241" -> branch "6.4"). If that branch does not exist
# yet in the target repo, it is created from the tip of the next-lower
# existing version branch. If the release tag already exists in the target
# repo, the script aborts with an error.
#
# The version published to the target repo (commit message and tag) has its
# "-p<digits>" build suffix stripped (e.g. "6.4.6-p2607131241" -> "6.4.6").
# "-rc..." suffixes are release-candidate markers and are kept as-is.
#
# Usage:
#   publish-dist-release.sh --tag <version> --dist <path> --target-repo <url> [--commit-message <msg>]

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: publish-dist-release.sh --tag <version> --dist <path> --target-repo <url> [--commit-message <msg>]

Required:
  --tag <version>          Full release tag, e.g. 6.4.6-p2607131241
  --dist <path>            Path to the already-built dist directory
  --target-repo <url>      Git URL of the target repository (auth already embedded)

Optional:
  --commit-message <msg>   Overrides the default commit message ("Release <tag>")
  -h, --help               Show this help text
EOF
}

TAG=""
DIST_PATH=""
TARGET_REPO=""
COMMIT_MESSAGE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)
            TAG="$2"; shift 2 ;;
        --dist)
            DIST_PATH="$2"; shift 2 ;;
        --target-repo)
            TARGET_REPO="$2"; shift 2 ;;
        --commit-message)
            COMMIT_MESSAGE="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            usage >&2
            exit 1 ;;
    esac
done

if [[ -z "$TAG" || -z "$DIST_PATH" || -z "$TARGET_REPO" ]]; then
    echo "Error: --tag, --dist and --target-repo are required." >&2
    usage >&2
    exit 1
fi

if [[ ! -d "$DIST_PATH" ]]; then
    echo "Error: dist path '$DIST_PATH' does not exist or is not a directory." >&2
    exit 1
fi

if [[ -z "$(ls -A "$DIST_PATH")" ]]; then
    echo "Error: dist path '$DIST_PATH' is empty." >&2
    exit 1
fi

DIST_PATH="$(cd "$DIST_PATH" && pwd)"

if [[ ! "$TAG" =~ ^v?([0-9]+)\.([0-9]+)\.[0-9A-Za-z.+-]+$ ]]; then
    echo "Error: tag '$TAG' does not match the expected version format (e.g. 6.4.6-p2607131241)." >&2
    exit 1
fi

MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
TARGET_BRANCH="$MAJOR.$MINOR"

# Strip the "-p<digits>" build suffix for the published version; "-rc..." is kept as-is.
PUBLISH_VERSION="${TAG#v}"
if [[ "$PUBLISH_VERSION" =~ ^(.+)-p[0-9]+$ ]]; then
    PUBLISH_VERSION="${BASH_REMATCH[1]}"
fi

COMMIT_MESSAGE="${COMMIT_MESSAGE:-Release $PUBLISH_VERSION}"

echo "Release tag:      $TAG"
echo "Published version: $PUBLISH_VERSION"
echo "Target branch:    $TARGET_BRANCH"

# Fail fast if this version has already been published, before touching anything.
if [[ -n "$(git ls-remote --tags "$TARGET_REPO" "refs/tags/$PUBLISH_VERSION")" ]]; then
    echo "Error: version '$PUBLISH_VERSION' already exists in the target repository." >&2
    exit 1
fi

WORKDIR="$(mktemp -d)"
cleanup() {
    git config --global --unset-all safe.directory "$WORKDIR" >/dev/null 2>&1 || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

# Containers commonly run git as a UID that doesn't own $WORKDIR, which git
# refuses to touch as a safety measure ("dubious ownership") unless allow-listed.
git config --global --add safe.directory "$WORKDIR"

echo "Cloning target repository..."
git clone --no-tags --quiet "$TARGET_REPO" "$WORKDIR"

cd "$WORKDIR"

# Collect existing "major.minor" branches from the target repo.
mapfile -t EXISTING_BRANCHES < <(
    git branch -r --format='%(refname:short)' \
        | sed 's#^origin/##' \
        | grep -E '^[0-9]+\.[0-9]+$' || true
)

TARGET_BRANCH_EXISTS="false"
for b in "${EXISTING_BRANCHES[@]:-}"; do
    [[ "$b" == "$TARGET_BRANCH" ]] && TARGET_BRANCH_EXISTS="true"
done

if [[ "$TARGET_BRANCH_EXISTS" == "true" ]]; then
    echo "Branch '$TARGET_BRANCH' already exists, checking it out..."
    git checkout -B "$TARGET_BRANCH" "origin/$TARGET_BRANCH"
else
    BASE_BRANCH=""
    BASE_MAJOR=-1
    BASE_MINOR=-1
    for b in "${EXISTING_BRANCHES[@]:-}"; do
        [[ -z "$b" ]] && continue
        b_major="${b%%.*}"
        b_minor="${b#*.}"
        is_lower="false"
        if (( b_major < MAJOR )); then
            is_lower="true"
        elif (( b_major == MAJOR && b_minor < MINOR )); then
            is_lower="true"
        fi
        if [[ "$is_lower" == "true" ]]; then
            if (( b_major > BASE_MAJOR || (b_major == BASE_MAJOR && b_minor > BASE_MINOR) )); then
                BASE_BRANCH="$b"
                BASE_MAJOR="$b_major"
                BASE_MINOR="$b_minor"
            fi
        fi
    done

    if [[ -n "$BASE_BRANCH" ]]; then
        echo "Branch '$TARGET_BRANCH' does not exist, branching from '$BASE_BRANCH'..."
        git checkout -b "$TARGET_BRANCH" "origin/$BASE_BRANCH"
    else
        echo "Branch '$TARGET_BRANCH' does not exist and no lower version branch was found, starting fresh..."
        git checkout --orphan "$TARGET_BRANCH"
        git rm -rf --quiet . >/dev/null 2>&1 || true
    fi
fi

# Replace the branch content with the dist package, keeping .git intact.
find . -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
cp -a "$DIST_PATH"/. .

git add -A

if git diff --cached --quiet; then
    echo "Error: dist content for '$PUBLISH_VERSION' is identical to the current state of '$TARGET_BRANCH', nothing to publish." >&2
    exit 1
fi

git commit --quiet -m "$COMMIT_MESSAGE"
git tag "$PUBLISH_VERSION"

echo "Pushing branch '$TARGET_BRANCH' and tag '$PUBLISH_VERSION'..."
git push origin "$TARGET_BRANCH"
git push origin "$PUBLISH_VERSION"

echo "Done: published '$PUBLISH_VERSION' to branch '$TARGET_BRANCH'."
