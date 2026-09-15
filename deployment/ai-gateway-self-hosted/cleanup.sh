#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/demo.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID in $ENV_FILE}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aigw-shgw-demo}"

az account set --subscription "$SUBSCRIPTION_ID"

echo "Subscription: $SUBSCRIPTION_ID"
echo "Resource group: $RESOURCE_GROUP"
az resource list --resource-group "$RESOURCE_GROUP" --query '[].{name:name,type:type}' --output table
echo
read -r -p "Type the resource group name to permanently delete it: " confirmation
[[ "$confirmation" == "$RESOURCE_GROUP" ]] || {
  echo '[INFO] Confirmation did not match; cleanup cancelled.'
  exit 1
}

az group delete --name "$RESOURCE_GROUP" --yes --no-wait
echo "[OK] Deletion started for $RESOURCE_GROUP"
