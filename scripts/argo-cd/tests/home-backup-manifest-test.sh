#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ceplea_values="$REPO_ROOT/argo-cd/helm_values/k3s-ceplea/backup-cronjobs/values.yaml"
buc_values="$REPO_ROOT/argo-cd/helm_values/k3s-buc/backup-cronjobs/values.yaml"
app="$REPO_ROOT/argo-cd/apps/k3s-ceplea/backup-cronjobs.yaml"
rbac_dir="$REPO_ROOT/argo-cd/extras/k3s-ceplea/backup-cronjobs"
shopt -s globstar nullglob
rbac_files=("$rbac_dir"/**/*.yaml "$rbac_dir"/**/*.yml)
if [[ ${#rbac_files[@]} -eq 0 ]]; then
    echo "no recursively deployed RBAC manifests found" >&2
    exit 1
fi
app_json="$(yq -o=json '.' "$app")"

if ! jq -e '
  .spec.destination == {namespace:"backup-cronjobs", server:"https://kubernetes.default.svc"} and
  .spec.sources == [
    {
      chart:"app-template",
      repoURL:"https://bjw-s-labs.github.io/helm-charts",
      targetRevision:"5.0.1",
      helm:{valueFiles:["$values/argo-cd/helm_values/k3s-ceplea/backup-cronjobs/values.yaml"]}
    },
    {
      repoURL:"https://github.com/ionutbalutoiu/home-k8s.git",
      path:"charts/external-secrets",
      targetRevision:"HEAD",
      helm:{valueFiles:["$values/argo-cd/helm_values/k3s-ceplea/backup-cronjobs/values_external_secrets.yaml"]}
    },
    {
      repoURL:"https://github.com/ionutbalutoiu/home-k8s.git",
      targetRevision:"HEAD",
      ref:"values"
    },
    {
      path:"argo-cd/extras/k3s-ceplea/backup-cronjobs",
      repoURL:"https://github.com/ionutbalutoiu/home-k8s.git",
      targetRevision:"HEAD",
      directory:{recurse:true}
    }
  ]
' <<<"$app_json" >/dev/null; then
    echo "Argo CD Application ordered-source contract failed" >&2
    exit 1
fi

chart_name="$(jq -r '.spec.sources[0].chart' <<<"$app_json")"
chart_repo="$(jq -r '.spec.sources[0].repoURL' <<<"$app_json")"
chart_version="$(jq -r '.spec.sources[0].targetRevision' <<<"$app_json")"
helm repo add validated-app-template "$chart_repo" --force-update >/dev/null
helm repo update validated-app-template >/dev/null
helm template backup-cronjobs "validated-app-template/$chart_name" --version "$chart_version" \
    --namespace backup-cronjobs -f "$ceplea_values" >"$TMP_DIR/ceplea.yaml"
helm template backup-cronjobs "validated-app-template/$chart_name" --version "$chart_version" \
    --namespace backup-cronjobs -f "$buc_values" >"$TMP_DIR/buc.yaml"

ceplea_json="$(yq eval-all -o=json '.' "$TMP_DIR/ceplea.yaml" | jq -s '.')"
buc_json="$(yq eval-all -o=json '.' "$TMP_DIR/buc.yaml" | jq -s '.')"
if ! jq -e '
  ([.[] | [.kind, .metadata.name, .metadata.namespace]] | sort) == ([
    ["ServiceAccount", "backup-cronjobs", "backup-cronjobs"],
    ["ConfigMap", "backup-configs", "backup-cronjobs"],
    ["CronJob", "backup-hyper-ryzen", "backup-cronjobs"]
  ] | sort) and
  ((first(.[] | select(.kind == "CronJob" and .metadata.name == "backup-hyper-ryzen"))) as $job |
    $job.spec.concurrencyPolicy == "Forbid" and
    $job.spec.jobTemplate.spec.template.spec.terminationGracePeriodSeconds == 300 and
    $job.spec.jobTemplate.spec.template.spec.serviceAccountName == "backup-cronjobs" and
    $job.spec.jobTemplate.spec.template.spec.automountServiceAccountToken == true and
    $job.spec.jobTemplate.spec.template.spec.containers == [
      ($job.spec.jobTemplate.spec.template.spec.containers[0] |
        select(.name == "home-backup" and .image == "ghcr.io/ionutbalutoiu/home-backup:2.0.0"))
    ]
  )
' <<<"$ceplea_json" >/dev/null; then
    echo "k3s-ceplea rendered resource/CronJob contract failed" >&2
    exit 1
fi

if ! jq -e '
  ([.[] | [.kind, .metadata.name, .metadata.namespace]] | sort) == ([
    ["ServiceAccount", "backup-cronjobs", "backup-cronjobs"],
    ["ConfigMap", "backup-configs", "backup-cronjobs"],
    ["CronJob", "backup-sea-pi", "backup-cronjobs"]
  ] | sort) and
  ((first(.[] | select(.kind == "CronJob" and .metadata.name == "backup-sea-pi"))) as $job |
    $job.spec.jobTemplate.spec.template.spec.containers == [
      ($job.spec.jobTemplate.spec.template.spec.containers[0] |
        select(.name == "home-backup" and .image == "ghcr.io/ionutbalutoiu/home-backup:2.0.0"))
    ]
  )
' <<<"$buc_json" >/dev/null; then
    echo "k3s-buc rendered resource/CronJob contract failed" >&2
    exit 1
fi

embedded_config="$(yq -r '.configMaps.backup-configs.data."hyper-ryzen.yaml"' "$ceplea_values")"
embedded_json="$(yq -o=json '.' <<<"$embedded_config")"
if ! jq -e '
  [.backups[] | select(.source.type == "longhorn_pvc")] == [{
    source:{
      type:"longhorn_pvc",
      pvc_name:"www-balutoiu-www",
      namespace:"www-balutoiu",
      snapshot_class:"longhorn"
    },
    destination:{
      type:"restic",
      repo:"rclone:onedrive-iony:restic-backups/k3s-ceplea/hyper-ryzen_pvc_www-balutoiu-www",
      keep_last:4
    }
  }]
' <<<"$embedded_json" >/dev/null; then
    echo "structured Longhorn PVC source contract failed" >&2
    exit 1
fi

kubeconform -strict -summary "${rbac_files[@]}"
kubeconform -strict -summary "$TMP_DIR/ceplea.yaml"
kubeconform -strict -summary "$TMP_DIR/buc.yaml"

echo "home-backup rendered manifest contract: PASS"
