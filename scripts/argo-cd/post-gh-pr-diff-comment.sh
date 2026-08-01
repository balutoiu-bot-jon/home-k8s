#!/usr/bin/env bash
set -euo pipefail

if [[ -z ${1:-} ]]; then
    echo "Usage: $0 <PR_NUMBER>"
    exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOW_APP_DIFF_BIN="${SHOW_APP_DIFF_BIN:-${DIR}/show-app-diff.sh}"

function argocd_app_diff_markdown() {
    local diff_file="$1"
    echo ""
    echo "<details>"
    echo "<summary>:open_file_folder: Show Output</summary>"
    echo ""
    echo '```diff'
    cat "$diff_file"
    echo ""
    echo '```'
    echo ""
    echo "</details>"
}

function get_modified_argo_app_files() {
    local changed_file section cluster app_component app_name app_file
    while IFS= read -r -d '' changed_file; do
        IFS='/' read -r _ section cluster app_component _ <<<"$changed_file"
        case "$cluster" in
            k3s-ceplea | k3s-buc) ;;
            *)
                echo "unsupported cluster path in changed Argo CD data: $changed_file" >&2
                return 2
                ;;
        esac
        case "$section" in
            apps)
                app_name="${app_component%.yaml}"
                if [[ "$app_component" != "${app_name}.yaml" ]]; then
                    echo "invalid Argo CD Application path: $changed_file" >&2
                    return 2
                fi
                ;;
            helm_values | extras)
                app_name="$app_component"
                ;;
            *)
                echo "unsupported Argo CD data path: $changed_file" >&2
                return 2
                ;;
        esac
        if [[ ! "$app_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
            echo "invalid Argo CD Application path identity: $changed_file" >&2
            return 2
        fi
        app_file="argo-cd/apps/${cluster}/${app_name}.yaml"
        if [[ -f "$app_file" ]]; then
            printf '%s\n' "$app_file"
        elif git cat-file -e "${BASE_SHA}:${app_file}" 2>/dev/null; then
            echo "deleted Application manifests cannot be live-diffed safely: $app_file" >&2
            return 2
        fi
    done < <(git diff --name-only -z --diff-filter=ACMRD "$BASE_SHA" "$HEAD_SHA" -- \
        'argo-cd/apps/**' 'argo-cd/helm_values/**' 'argo-cd/extras/**')
}

export KUBECTL_EXTERNAL_DIFF="diff -u"

PR_NUMBER="$1"
DIFF_COMMENT_FILE="/tmp/gh-diff-comment.md"
DIFF_DIR="/tmp/argo-diffs"

: "${BASE_SHA:?BASE_SHA must identify the immutable pull request base commit}"
: "${HEAD_SHA:?HEAD_SHA must identify the immutable pull request head commit}"
: "${HOME_K8S_REVISION:?HOME_K8S_REVISION must identify the immutable candidate revision}"
RESOLVED_HEAD_SHA="$(git rev-parse "${HEAD_SHA}^{commit}")"
if [[ "$(git rev-parse HEAD)" != "$RESOLVED_HEAD_SHA" ]] || [[ "$HOME_K8S_REVISION" != "$RESOLVED_HEAD_SHA" ]]; then
    echo "candidate checkout, HEAD_SHA, and HOME_K8S_REVISION must resolve to the same commit" >&2
    exit 2
fi
git rev-parse "${BASE_SHA}^{commit}" >/dev/null

trap 'rm -rf "$DIFF_DIR" "$DIFF_COMMENT_FILE"' EXIT

APP_FILE_TEXT="$(get_modified_argo_app_files | sort -u)"
if [[ -z "$APP_FILE_TEXT" ]]; then
    echo "No changes to Argo CD application files were found in this pull request."
    exit 0
fi
mapfile -t APP_FILES <<<"$APP_FILE_TEXT"

echo "⏳ Generating Argo CD app diffs for:"
printf ' - %s\n' "${APP_FILES[@]}"
echo ""

for APP_FILE in "${APP_FILES[@]}"; do
    echo "🚀 Processing Argo CD app file: $APP_FILE"
    rm -rf "$DIFF_DIR"
    mkdir -p "$DIFF_DIR"
    CLUSTER_NAME="$(cut -d '/' -f 3 <<<"$APP_FILE")"
    export ARGOCD_CONTEXT="$CLUSTER_NAME"

    set +e
    "$SHOW_APP_DIFF_BIN" "$APP_FILE" > "$DIFF_DIR/argo-app.diff" 2>&1
    STATUS=$?
    set -e
    if [[ $STATUS -ne 0 && $STATUS -ne 20 ]]; then
        cat "$DIFF_DIR/argo-app.diff" >&2
        exit "$STATUS"
    fi
    if ! grep -q '[^[:space:]]' "$DIFF_DIR/argo-app.diff"; then
        echo "Argo CD produced no diff output for changed Application $APP_FILE" >&2
        exit 2
    fi
    if grep -Ev '^[[:space:]]*[+-]' "$DIFF_DIR/argo-app.diff" |
        grep -Eiq '^[[:space:]]*fata(l)?([[:space:]:\[]|$)|(^|[[:space:]])level[=:][[:space:]]*"?fatal([",:[:space:]]|$)|source-position cannot be less than 1 or more than number of sources'; then
        cat "$DIFF_DIR/argo-app.diff" >&2
        echo "Argo CD emitted fatal output despite a successful exit status" >&2
        exit 2
    fi

    if [[ $(wc -c < "$DIFF_DIR/argo-app.diff") -gt 65000 ]]; then
        split -b 65000 --additional-suffix=.diff "$DIFF_DIR/argo-app.diff" "$DIFF_DIR/argo-app-diff-part-"
        rm "$DIFF_DIR/argo-app.diff"
    fi

    PART_FILES=("$DIFF_DIR"/*.diff)
    TOTAL_PARTS=${#PART_FILES[@]}
    PART_COUNT=1
    for PART_FILE in "${PART_FILES[@]}"; do
        echo "## Argo CD App Diff" > "$DIFF_COMMENT_FILE"
        echo "### (${PART_COUNT}/${TOTAL_PARTS}) \`${APP_FILE}\`" >> "$DIFF_COMMENT_FILE"
        argocd_app_diff_markdown "$PART_FILE" >> "$DIFF_COMMENT_FILE"
        gh pr comment "$PR_NUMBER" -F "$DIFF_COMMENT_FILE"
        ((PART_COUNT += 1))
    done
done
