#!/usr/bin/env bash
# Optional private npm registry (Artifactory). Scopes and registry URL are configurable.
set -euo pipefail

NPM_REGISTRY_URL="${NPM_REGISTRY_URL:-https://artifactory.bayer.com/artifactory/api/npm/npm-platforms-engineering/}"
NPM_SCOPES="${NPM_SCOPES:-@monsantoit,@element}"

if [[ -z "${ARTIFACTORY_USERNAME:-}" || -z "${ARTIFACTORY_AUTH_TOKEN:-}" ]]; then
  echo "WARNING: No Artifactory credentials - private packages may fail"
  npm config set registry https://registry.npmjs.org/ 2>/dev/null || true
  exit 0
fi

IFS=',' read -ra SCOPES <<< "$NPM_SCOPES"
for scope in "${SCOPES[@]}"; do
  scope=$(echo "$scope" | xargs)
  [[ -z "$scope" ]] && continue
  echo "${scope}:registry=${NPM_REGISTRY_URL}" >> ~/.npmrc
done

echo "//${NPM_REGISTRY_URL#https://}:username=${ARTIFACTORY_USERNAME}" >> ~/.npmrc
echo "//${NPM_REGISTRY_URL#https://}:_authToken=${ARTIFACTORY_AUTH_TOKEN}" >> ~/.npmrc
echo "//${NPM_REGISTRY_URL#https://}:always-auth=true" >> ~/.npmrc
echo "Private npm registry configured (${NPM_SCOPES})"
npm config set registry https://registry.npmjs.org/ 2>/dev/null || true
