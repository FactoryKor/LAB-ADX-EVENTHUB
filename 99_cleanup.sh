#!/usr/bin/env bash
set -euo pipefail

if [[ -f ./lab.env ]]; then
  source ./lab.env
fi

if [[ -z "${RG:-}" ]]; then
  echo "RG is not set. Run: source ./lab.env"
  exit 1
fi

echo "Deleting resource group: ${RG}"
az group delete --name "${RG}" --yes --no-wait

echo "Delete submitted."