#!/usr/bin/env bash
set -euo pipefail

if [[ -z ${1:-} ]]; then
    echo "Usage: $0 <path-to-argo-app-file>"
    exit 1
fi

function git_repo_revision() {
    local repo_url="$1"
    local revision="$2"
    if [[ "$repo_url" == "https://github.com/ionutbalutoiu/home-k8s.git" ]]; then
        if [[ -z ${HOME_K8S_REVISION:-} ]]; then
            echo "HOME_K8S_REVISION is required for home-k8s Application sources" >&2
            return 2
        fi
        revision="$HOME_K8S_REVISION"
    fi
    printf '%s\n' "$revision"
}

ARGO_APP_FILE="$1"
case "${ARGOCD_CONTEXT:-}" in
    k3s-ceplea | k3s-buc) ;;
    *)
        echo "unsupported or missing Argo CD context: ${ARGOCD_CONTEXT:-<empty>}" >&2
        exit 2
        ;;
esac

ARGO_APP_NAME="$(yq -r '.metadata.name' "$ARGO_APP_FILE")"
if [[ ! "$ARGO_APP_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "invalid Argo CD Application name: $ARGO_APP_NAME" >&2
    exit 2
fi
EXPECTED_APP_FILE="argo-cd/apps/${ARGOCD_CONTEXT}/${ARGO_APP_NAME}.yaml"
if [[ "$ARGO_APP_FILE" != "$EXPECTED_APP_FILE" ]]; then
    echo "Application identity/path mismatch: $ARGO_APP_FILE != $EXPECTED_APP_FILE" >&2
    exit 2
fi

ARGOCD_APP_DIFF_CMD=(
    argocd app diff "$ARGO_APP_NAME"
    --hard-refresh
    --diff-exit-code 20
    --argocd-context "$ARGOCD_CONTEXT"
)

IS_MULTI_SOURCES_APP="$(yq -r '.spec | has("sources")' "$ARGO_APP_FILE")"
if [[ "$IS_MULTI_SOURCES_APP" == "true" ]]; then
    SOURCE_POSITION=1
    mapfile -t SOURCES < <(yq -r '.spec.sources[] | [.repoURL, .targetRevision] | @tsv' "$ARGO_APP_FILE")
    for SOURCE in "${SOURCES[@]}"; do
        IFS=$'\t' read -r REPO_URL REVISION <<<"$SOURCE"
        REVISION="$(git_repo_revision "$REPO_URL" "$REVISION")"
        ARGOCD_APP_DIFF_CMD+=(--source-positions "$SOURCE_POSITION" --revisions "$REVISION")
        ((SOURCE_POSITION += 1))
    done
else
    IFS=$'\t' read -r REPO_URL REVISION < <(yq -r '.spec.source | [.repoURL, .targetRevision] | @tsv' "$ARGO_APP_FILE")
    REVISION="$(git_repo_revision "$REPO_URL" "$REVISION")"
    ARGOCD_APP_DIFF_CMD+=(--revision "$REVISION")
fi

"${ARGOCD_APP_DIFF_CMD[@]}"
