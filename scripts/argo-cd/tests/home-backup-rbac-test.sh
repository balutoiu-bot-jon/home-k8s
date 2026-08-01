#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RBAC_DIR="$REPO_ROOT/argo-cd/extras/k3s-ceplea/backup-cronjobs"
shopt -s globstar nullglob
RBAC_FILES=("$RBAC_DIR"/**/*.yaml "$RBAC_DIR"/**/*.yml)
if [[ ${#RBAC_FILES[@]} -eq 0 ]]; then
    echo "no recursively deployed RBAC manifests found" >&2
    exit 1
fi
RBAC_JSON="$(yq eval-all -o=json '.' "${RBAC_FILES[@]}" | jq -s '.')"

if ! jq -e '
  def object($kind; $name; $namespace):
    first(.[] | select(
      .kind == $kind and
      .metadata.name == $name and
      (.metadata.namespace // "") == $namespace
    ));
  length == 6 and
  ([.[] | [.kind, .metadata.name, (.metadata.namespace // "")]] | sort) == ([
    ["Role", "home-backup-longhorn-runner", ""],
    ["RoleBinding", "home-backup-longhorn-runner", ""],
    ["Role", "home-backup-longhorn-source", "www-balutoiu"],
    ["RoleBinding", "home-backup-longhorn-source", "www-balutoiu"],
    ["ClusterRole", "home-backup-longhorn-snapshot-alias", ""],
    ["ClusterRoleBinding", "home-backup-longhorn-snapshot-alias", ""]
  ] | sort) and
  object("Role"; "home-backup-longhorn-runner"; "").rules == [
    {apiGroups:[""], resources:["pods"], verbs:["get","list","delete"]},
    {apiGroups:[""], resources:["pods/log"], verbs:["get"]},
    {apiGroups:[""], resources:["persistentvolumeclaims","secrets"], verbs:["get","list","create","delete"]},
    {apiGroups:["batch"], resources:["cronjobs"], verbs:["get"]},
    {apiGroups:["batch"], resources:["jobs"], verbs:["get","list","create","delete"]},
    {apiGroups:["snapshot.storage.k8s.io"], resources:["volumesnapshots"], verbs:["get","list","create","delete"]}
  ] and
  object("Role"; "home-backup-longhorn-source"; "www-balutoiu").rules == [
    {apiGroups:[""], resources:["persistentvolumeclaims"], verbs:["get"]},
    {apiGroups:["snapshot.storage.k8s.io"], resources:["volumesnapshots"], verbs:["get","list","create","delete"]}
  ] and
  object("ClusterRole"; "home-backup-longhorn-snapshot-alias"; "").rules == [
    {apiGroups:["snapshot.storage.k8s.io"], resources:["volumesnapshotcontents"], verbs:["get","list","create","delete"]}
  ] and
  object("RoleBinding"; "home-backup-longhorn-runner"; "").subjects == [
    {kind:"ServiceAccount", name:"backup-cronjobs", namespace:"backup-cronjobs"}
  ] and
  object("RoleBinding"; "home-backup-longhorn-runner"; "").roleRef == {
    apiGroup:"rbac.authorization.k8s.io", kind:"Role", name:"home-backup-longhorn-runner"
  } and
  object("RoleBinding"; "home-backup-longhorn-source"; "www-balutoiu").subjects == [
    {kind:"ServiceAccount", name:"backup-cronjobs", namespace:"backup-cronjobs"}
  ] and
  object("RoleBinding"; "home-backup-longhorn-source"; "www-balutoiu").roleRef == {
    apiGroup:"rbac.authorization.k8s.io", kind:"Role", name:"home-backup-longhorn-source"
  } and
  object("ClusterRoleBinding"; "home-backup-longhorn-snapshot-alias"; "").subjects == [
    {kind:"ServiceAccount", name:"backup-cronjobs", namespace:"backup-cronjobs"}
  ] and
  object("ClusterRoleBinding"; "home-backup-longhorn-snapshot-alias"; "").roleRef == {
    apiGroup:"rbac.authorization.k8s.io", kind:"ClusterRole", name:"home-backup-longhorn-snapshot-alias"
  }
' <<<"$RBAC_JSON" >/dev/null; then
    echo "home-backup RBAC exact least-privilege contract failed" >&2
    exit 1
fi

echo "home-backup RBAC least-privilege contract: PASS"
