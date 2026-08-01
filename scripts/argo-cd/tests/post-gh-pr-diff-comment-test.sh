#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export BASE_SHA=origin/main
export HEAD_SHA
HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
export HOME_K8S_REVISION="$HEAD_SHA"

mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "pr diff --name-only 467" ]]; then
    echo "argo-cd/apps/k3s-ceplea/backup-cronjobs.yaml"
    exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "comment" ]]; then
    touch "$GH_COMMENT_MARKER"
    exit 0
fi
echo "unexpected gh arguments: $*" >&2
exit 64
MOCK_GH
chmod +x "$TMP_DIR/bin/gh"

cat > "$TMP_DIR/fail-diff" <<'FAIL_DIFF'
#!/usr/bin/env bash
echo "source-position cannot be less than 1 or more than number of sources in the app" >&2
exit 2
FAIL_DIFF
chmod +x "$TMP_DIR/fail-diff"

set +e
OUTPUT=$(
    cd "$REPO_ROOT"
    PATH="$TMP_DIR/bin:$PATH" \
        GH_COMMENT_MARKER="$TMP_DIR/commented" \
        SHOW_APP_DIFF_BIN="$TMP_DIR/fail-diff" \
        ./scripts/argo-cd/post-gh-pr-diff-comment.sh 467 2>&1
)
STATUS=$?
set -e

if [[ $STATUS -ne 2 ]]; then
    echo "expected diff helper exit status 2, got $STATUS" >&2
    echo "$OUTPUT" >&2
    exit 1
fi
if [[ "$OUTPUT" != *"source-position cannot be less than 1"* ]]; then
    echo "expected Argo CD failure in output" >&2
    echo "$OUTPUT" >&2
    exit 1
fi
if [[ -e "$TMP_DIR/commented" ]]; then
    echo "diff failure must not post a success comment" >&2
    exit 1
fi

cat > "$TMP_DIR/fatal-green" <<'FATAL_GREEN'
#!/usr/bin/env bash
echo 'FATA[0000] source-position cannot be less than 1 or more than number of sources in the app'
exit 0
FATAL_GREEN
chmod +x "$TMP_DIR/fatal-green"
set +e
(
    cd "$REPO_ROOT"
    PATH="$TMP_DIR/bin:$PATH" \
        GH_COMMENT_MARKER="$TMP_DIR/commented" \
        SHOW_APP_DIFF_BIN="$TMP_DIR/fatal-green" \
        ./scripts/argo-cd/post-gh-pr-diff-comment.sh 467 >/dev/null 2>&1
)
STATUS=$?
set -e
if [[ $STATUS -eq 0 || -e "$TMP_DIR/commented" ]]; then
    echo "fatal output must fail even when the helper exits zero" >&2
    exit 1
fi

cat > "$TMP_DIR/empty-diff" <<'EMPTY_DIFF'
#!/usr/bin/env bash
exit 20
EMPTY_DIFF
chmod +x "$TMP_DIR/empty-diff"
set +e
(
    cd "$REPO_ROOT"
    PATH="$TMP_DIR/bin:$PATH" \
        GH_COMMENT_MARKER="$TMP_DIR/commented" \
        SHOW_APP_DIFF_BIN="$TMP_DIR/empty-diff" \
        ./scripts/argo-cd/post-gh-pr-diff-comment.sh 467 >/dev/null 2>&1
)
STATUS=$?
set -e
if [[ $STATUS -eq 0 || -e "$TMP_DIR/commented" ]]; then
    echo "diff status 20 with empty output must fail" >&2
    exit 1
fi

cat > "$TMP_DIR/empty-success" <<'EMPTY_SUCCESS'
#!/usr/bin/env bash
exit 0
EMPTY_SUCCESS
cat > "$TMP_DIR/whitespace-success" <<'WHITESPACE_SUCCESS'
#!/usr/bin/env bash
printf '  \n\t\n'
exit 0
WHITESPACE_SUCCESS
cat > "$TMP_DIR/level-fatal-success" <<'LEVEL_FATAL_SUCCESS'
#!/usr/bin/env bash
echo 'time="now" level=fatal msg="render failed"'
exit 0
LEVEL_FATAL_SUCCESS
cat > "$TMP_DIR/uppercase-fatal-success" <<'UPPERCASE_FATAL_SUCCESS'
#!/usr/bin/env bash
echo 'FATAL: render failed'
exit 0
UPPERCASE_FATAL_SUCCESS
cat > "$TMP_DIR/lowercase-fatal-success" <<'LOWERCASE_FATAL_SUCCESS'
#!/usr/bin/env bash
echo 'fatal: render failed'
exit 0
LOWERCASE_FATAL_SUCCESS
chmod +x "$TMP_DIR/empty-success" "$TMP_DIR/whitespace-success" "$TMP_DIR/level-fatal-success" \
    "$TMP_DIR/uppercase-fatal-success" "$TMP_DIR/lowercase-fatal-success"
for helper in empty-success whitespace-success level-fatal-success uppercase-fatal-success lowercase-fatal-success; do
    rm -f "$TMP_DIR/commented"
    set +e
    (
        cd "$REPO_ROOT"
        PATH="$TMP_DIR/bin:$PATH" \
            GH_COMMENT_MARKER="$TMP_DIR/commented" \
            SHOW_APP_DIFF_BIN="$TMP_DIR/$helper" \
            ./scripts/argo-cd/post-gh-pr-diff-comment.sh 467 >/dev/null 2>&1
    )
    STATUS=$?
    set -e
    if [[ $STATUS -eq 0 || -e "$TMP_DIR/commented" ]]; then
        echo "$helper output must be rejected without a comment" >&2
        exit 1
    fi
done

cat > "$TMP_DIR/diff-found" <<'DIFF_FOUND'
#!/usr/bin/env bash
echo '+ expected manifest change'
exit 20
DIFF_FOUND
chmod +x "$TMP_DIR/diff-found"

(
    cd "$REPO_ROOT"
    PATH="$TMP_DIR/bin:$PATH" \
        GH_COMMENT_MARKER="$TMP_DIR/commented" \
        SHOW_APP_DIFF_BIN="$TMP_DIR/diff-found" \
        ./scripts/argo-cd/post-gh-pr-diff-comment.sh 467 >/dev/null
)
if [[ ! -e "$TMP_DIR/commented" ]]; then
    echo "diff exit status 20 must post the rendered diff comment" >&2
    exit 1
fi

rm -f "$TMP_DIR/commented"
cat > "$TMP_DIR/benign-fatal-diff" <<'BENIGN_FATAL_DIFF'
#!/usr/bin/env bash
echo '+  value: fatal'
exit 20
BENIGN_FATAL_DIFF
chmod +x "$TMP_DIR/benign-fatal-diff"
(
    cd "$REPO_ROOT"
    PATH="$TMP_DIR/bin:$PATH" \
        GH_COMMENT_MARKER="$TMP_DIR/commented" \
        SHOW_APP_DIFF_BIN="$TMP_DIR/benign-fatal-diff" \
        ./scripts/argo-cd/post-gh-pr-diff-comment.sh 467 >/dev/null
)
if [[ ! -e "$TMP_DIR/commented" ]]; then
    echo "a legitimate manifest value containing fatal must remain commentable" >&2
    exit 1
fi

cat > "$TMP_DIR/deletion-diff" <<'DELETION_DIFF'
#!/usr/bin/env bash
touch "$SHOW_HELPER_MARKER"
echo '+ deletion inspected'
exit 20
DELETION_DIFF
chmod +x "$TMP_DIR/deletion-diff"
DELETE_REPO="$TMP_DIR/delete-repo"
mkdir -p "$DELETE_REPO/argo-cd/apps/k3s-ceplea" \
    "$DELETE_REPO/argo-cd/helm_values/k3s-ceplea/backup-cronjobs"
git -C "$DELETE_REPO" init -q
git -C "$DELETE_REPO" config user.name test
git -C "$DELETE_REPO" config user.email test@example.invalid
printf '%s\n' 'metadata:' '  name: backup-cronjobs' > "$DELETE_REPO/argo-cd/apps/k3s-ceplea/backup-cronjobs.yaml"
printf '%s\n' 'value: old' > "$DELETE_REPO/argo-cd/helm_values/k3s-ceplea/backup-cronjobs/values.yaml"
git -C "$DELETE_REPO" add .
git -C "$DELETE_REPO" commit -qm base
DELETE_BASE_SHA="$(git -C "$DELETE_REPO" rev-parse HEAD)"
rm "$DELETE_REPO/argo-cd/helm_values/k3s-ceplea/backup-cronjobs/values.yaml"
git -C "$DELETE_REPO" add -u
git -C "$DELETE_REPO" commit -qm delete-values
DELETE_HEAD_SHA="$(git -C "$DELETE_REPO" rev-parse HEAD)"
rm -f "$TMP_DIR/show-called" "$TMP_DIR/commented"
(
    cd "$DELETE_REPO"
    PATH="$TMP_DIR/bin:$PATH" \
        BASE_SHA="$DELETE_BASE_SHA" \
        HEAD_SHA="$DELETE_HEAD_SHA" \
        HOME_K8S_REVISION="$DELETE_HEAD_SHA" \
        GH_COMMENT_MARKER="$TMP_DIR/commented" \
        SHOW_HELPER_MARKER="$TMP_DIR/show-called" \
        SHOW_APP_DIFF_BIN="$TMP_DIR/deletion-diff" \
        "$REPO_ROOT/scripts/argo-cd/post-gh-pr-diff-comment.sh" 467 >/dev/null
)
if [[ ! -e "$TMP_DIR/show-called" || ! -e "$TMP_DIR/commented" ]]; then
    echo "deleted values files must still trigger the owning Application diff" >&2
    exit 1
fi

DELETE_APP_BASE_SHA="$DELETE_HEAD_SHA"
rm "$DELETE_REPO/argo-cd/apps/k3s-ceplea/backup-cronjobs.yaml"
git -C "$DELETE_REPO" add -u
git -C "$DELETE_REPO" commit -qm delete-application
DELETE_APP_HEAD_SHA="$(git -C "$DELETE_REPO" rev-parse HEAD)"
rm -f "$TMP_DIR/show-called" "$TMP_DIR/commented"
set +e
(
    cd "$DELETE_REPO"
    PATH="$TMP_DIR/bin:$PATH" \
        BASE_SHA="$DELETE_APP_BASE_SHA" \
        HEAD_SHA="$DELETE_APP_HEAD_SHA" \
        HOME_K8S_REVISION="$DELETE_APP_HEAD_SHA" \
        GH_COMMENT_MARKER="$TMP_DIR/commented" \
        SHOW_HELPER_MARKER="$TMP_DIR/show-called" \
        SHOW_APP_DIFF_BIN="$TMP_DIR/deletion-diff" \
        "$REPO_ROOT/scripts/argo-cd/post-gh-pr-diff-comment.sh" 467 >/dev/null 2>&1
)
STATUS=$?
set -e
if [[ $STATUS -eq 0 || -e "$TMP_DIR/show-called" || -e "$TMP_DIR/commented" ]]; then
    echo "deleted Application manifests must fail closed before diff/comment" >&2
    exit 1
fi

echo "post-gh-pr-diff-comment status handling: PASS"
