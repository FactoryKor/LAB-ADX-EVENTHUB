#!/usr/bin/env bash
set -euo pipefail

# Pause / resume the ADX cluster to save compute cost between test sessions.
# Usage: ./10_adx_stop_start.sh {start|stop|status}

if [[ -f ./lab.env ]]; then
  source ./lab.env
fi

if [[ -z "${RG:-}" || -z "${ADX_CLUSTER:-}" ]]; then
  echo "RG / ADX_CLUSTER not set. Run: source ./lab.env"
  exit 1
fi

ACTION="${1:-}"
case "${ACTION}" in
  stop)
    echo "Stopping ADX cluster '${ADX_CLUSTER}' (compute billing pauses)..."
    az kusto cluster stop --resource-group "${RG}" --name "${ADX_CLUSTER}" --no-wait
    echo "Stop submitted."
    ;;
  start)
    echo "Starting ADX cluster '${ADX_CLUSTER}'..."
    az kusto cluster start --resource-group "${RG}" --name "${ADX_CLUSTER}" --no-wait
    echo "Start submitted."
    ;;
  status)
    az kusto cluster show --resource-group "${RG}" --name "${ADX_CLUSTER}" \
      --query "{name:name,state:state,provisioningState:provisioningState}" -o table
    ;;
  *)
    echo "Usage: $0 {start|stop|status}"
    exit 1
    ;;
esac
