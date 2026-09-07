#!/usr/bin/env bash

set -euo pipefail

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-00000000-0000-0000-0000-000000000000}"
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
