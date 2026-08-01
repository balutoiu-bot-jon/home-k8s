#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"

cat > "$TMP_DIR/bin/argocd" <<'MOCK_ARGOCD'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$ARGOCD_ARGS_FILE"
exit 20
MOCK_ARGOCD
chmod +x "$TMP_DIR/bin/argocd"

set +e
(
    cd "$REPO_ROOT"
    PATH="$TMP_DIR/bin:$PATH" \
        ARGOCD_ARGS_FILE="$TMP_DIR/args" \
        ARGOCD_CONTEXT="k3s-ceplea" \
        HOME_K8S_REVISION='0123456789abcdef0123456789abcdef01234567' \
        GITHUB_HEAD_REF='feature;touch-should-not-execute' \
        ./scripts/argo-cd/show-app-diff.sh argo-cd/apps/k3s-ceplea/backup-cronjobs.yaml
)
STATUS=$?
set -e
if [[ $STATUS -ne 20 ]]; then
    echo "expected Argo CD diff status 20, got $STATUS" >&2
    exit 1
fi

mapfile -t ARGS < "$TMP_DIR/args"
EXPECTED=(
    app diff backup-cronjobs
    --hard-refresh --diff-exit-code 20
    --argocd-context k3s-ceplea
    --source-positions 1 --revisions 5.0.1
    --source-positions 2 --revisions '0123456789abcdef0123456789abcdef01234567'
    --source-positions 3 --revisions '0123456789abcdef0123456789abcdef01234567'
    --source-positions 4 --revisions '0123456789abcdef0123456789abcdef01234567'
)
if [[ ${#ARGS[@]} -ne ${#EXPECTED[@]} ]]; then
    printf 'unexpected argument count; got:\n%s\n' "${ARGS[*]}" >&2
    exit 1
fi
for i in "${!EXPECTED[@]}"; do
    if [[ "${ARGS[$i]}" != "${EXPECTED[$i]}" ]]; then
        printf 'argument %s: got %q, want %q\n' "$i" "${ARGS[$i]}" "${EXPECTED[$i]}" >&2
        exit 1
    fi
done
if [[ -e "$REPO_ROOT/touch-should-not-execute" ]]; then
    echo "revision text was executed instead of passed as an argument" >&2
    exit 1
fi

rm -f "$TMP_DIR/args"
set +e
(
    cd "$REPO_ROOT"
    PATH="$TMP_DIR/bin:$PATH" \
        ARGOCD_ARGS_FILE="$TMP_DIR/args" \
        ARGOCD_CONTEXT='k3s-ceplea --server 16909060 --plaintext' \
        HOME_K8S_REVISION='0123456789abcdef0123456789abcdef01234567' \
        ./scripts/argo-cd/show-app-diff.sh argo-cd/apps/k3s-ceplea/backup-cronjobs.yaml >/dev/null 2>&1
)
STATUS=$?
set -e
if [[ $STATUS -eq 0 || -e "$TMP_DIR/args" ]]; then
    echo "candidate-controlled Argo CD context options must be rejected before execution" >&2
    exit 1
fi

echo "show-app-diff argument construction: PASS"
