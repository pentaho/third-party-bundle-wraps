#!/usr/bin/env bash

set -euo pipefail

# Assigns release versions to Maven modules selected by the workflow.
#
# Change detection and the publish allowlist are handled by publish-maven.yml
# before Maven setup. This script queries Artifactory and updates each selected
# module to its next unused `-pentaho-N` release number.
#
# Arguments:
#   1. Comma-separated module paths
# Environment:
#   PUBLIC_RELEASE_REPO_URL: target Artifactory Maven repository
#   ARTIFACTORY_USERNAME / ARTIFACTORY_PASSWORD: metadata read credentials
module_list=${1:?comma-separated module paths are required}
repository_url=${PUBLIC_RELEASE_REPO_URL:?repository URL is required}

fetch_metadata() {
  local metadata_url=$1 response http_status

  response=$(curl --silent --show-error --write-out $'\n%{http_code}' \
    --user "$ARTIFACTORY_USERNAME:$ARTIFACTORY_PASSWORD" "$metadata_url")
  http_status=${response##*$'\n'}

  case "$http_status" in
    200) printf '%s' "${response%$'\n'*}" ;;
    404) return 0 ;;
    *) echo "Failed to query Artifactory metadata (HTTP $http_status): $metadata_url" >&2; return 1 ;;
  esac
}

next_release_counter() {
  local metadata=$1 base_version=$2 release counter highest=0

  while IFS= read -r release; do
    [[ "$release" == "${base_version}-pentaho-"* ]] || continue
    counter=${release##*-}
    [[ "$counter" =~ ^[0-9]+$ && "$counter" -gt "$highest" ]] && highest=$counter
  done < <(sed -n 's|.*<version>\([^<]*\)</version>.*|\1|p' <<<"$metadata")

  echo $((highest + 1))
}

IFS=',' read -r -a modules <<< "$module_list"

for module in "${modules[@]}"; do
  pom="$module/pom.xml"

  mvn_evaluate=(mvn --batch-mode --quiet -pl "$module" -DforceStdout help:evaluate)
  group_id=$("${mvn_evaluate[@]}" -Dexpression=project.groupId)
  artifact_id=$("${mvn_evaluate[@]}" -Dexpression=project.artifactId)
  version=$("${mvn_evaluate[@]}" -Dexpression=project.version)

  if [[ -z "$group_id" || -z "$artifact_id" || ! "$version" =~ ^(.+)-pentaho-[0-9]+$ ]]; then
    echo "Module '$module' must resolve groupId, artifactId, and a version ending in -pentaho-N." >&2
    exit 1
  fi

  base_version=${BASH_REMATCH[1]}
  metadata_url="${repository_url%/}/${group_id//.//}/${artifact_id}/maven-metadata.xml"
  metadata=$(fetch_metadata "$metadata_url")
  next_counter=$(next_release_counter "$metadata" "$base_version")

  sed -i.bak -E "s|(<revision>.*-pentaho-)[0-9]+(</revision>)|\1${next_counter}\2|" "$pom"
  rm "${pom}.bak"
  echo "Prepared $module as ${base_version}-pentaho-${next_counter}"
done
