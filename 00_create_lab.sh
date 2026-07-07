#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Event Hub + ADX Diagnostic Test Lab
# Purpose:
#   - eh_diagnose 테스트: metric, partition, consumer group, lag, skew, errors
#   - adx_diagnose 테스트: ingestion, query, cache/scan, monitor metric
# ============================================================

# -----------------------------
# 0) User variables
# -----------------------------
export SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
export TENANT_ID="$(az account show --query tenantId -o tsv)"
export LOCATION="koreacentral"

# 중복 방지를 위해 suffix 사용
export SUFFIX="${SUFFIX:-$(date +%m%d%H%M)}"

export RG="rg-eh-adx-diag-lab-${SUFFIX}"
export EH_NS="ehnsdiag${SUFFIX}"
export EH_NAME="telemetry-events"
export EH_CG_ADX="adx-cg"
export EH_CG_SLOW="slow-cg"

export ADX_CLUSTER="adxdiag${SUFFIX}"
export ADX_DB="diagdb"
export ADX_TABLE="TelemetryRaw"
export ADX_MAPPING="TelemetryRawMapping"
export ADX_CONN="conn-eh-telemetry"

export LOG_WS="law-eh-adx-diag-${SUFFIX}"

# Storage account for Event Hub consumer checkpoint store (name: 3-24 lowercase alnum)
export STORAGE_ACCT="stehadx${SUFFIX}"
export BLOB_CONTAINER="checkpoints"

# Optional: an extra ADX data-plane principal for adx_diagnose / RBAC tests.
# Provide a valid KQL principal token, e.g. "aadapp=<appId>;<tenantId>" or "aaduser=<upn>".
# Leave empty to skip (the lab creator is already AllDatabasesAdmin).
export ADX_QUERY_PRINCIPAL="${ADX_QUERY_PRINCIPAL:-}"

# ADX SKU
# 테스트/PoC라면 작은 SKU부터 시작. 리전/SKU 가용성은 구독에 따라 다를 수 있음.
export ADX_SKU_NAME="Standard_D11_v2"
export ADX_SKU_TIER="Standard"
export ADX_CAPACITY="2"

echo "============================================================"
echo "Subscription : ${SUBSCRIPTION_ID}"
echo "Location     : ${LOCATION}"
echo "ResourceGroup: ${RG}"
echo "EventHub NS  : ${EH_NS}"
echo "ADX Cluster  : ${ADX_CLUSTER}"
echo "ADX DB       : ${ADX_DB}"
echo "============================================================"

# -----------------------------
# 1) Provider registration
# -----------------------------
echo "[1/12] Register providers..."
az provider register --namespace Microsoft.EventHub --wait
az provider register --namespace Microsoft.Kusto --wait
az provider register --namespace Microsoft.OperationalInsights --wait
az provider register --namespace Microsoft.Insights --wait
az provider register --namespace Microsoft.Storage --wait

# Kusto extension
az extension add --name kusto --upgrade >/dev/null

# -----------------------------
# 2) Resource group
# -----------------------------
echo "[2/12] Create resource group..."
az group create \
  --name "${RG}" \
  --location "${LOCATION}" \
  -o table

# -----------------------------
# 3) Log Analytics workspace
# -----------------------------
echo "[3/12] Create Log Analytics workspace..."
az monitor log-analytics workspace create \
  --resource-group "${RG}" \
  --workspace-name "${LOG_WS}" \
  --location "${LOCATION}" \
  -o table

export LOG_WS_ID="$(az monitor log-analytics workspace show \
  --resource-group "${RG}" \
  --workspace-name "${LOG_WS}" \
  --query id -o tsv)"

# -----------------------------
# 3-1) Storage account (Event Hub consumer checkpoint store)
# -----------------------------
echo "[3-1/12] Create Storage account for checkpoint store..."
az storage account create \
  --name "${STORAGE_ACCT}" \
  --resource-group "${RG}" \
  --location "${LOCATION}" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  -o table

export STORAGE_CONN_STR="$(az storage account show-connection-string \
  --name "${STORAGE_ACCT}" \
  --resource-group "${RG}" \
  --query connectionString -o tsv)"

az storage container create \
  --name "${BLOB_CONTAINER}" \
  --connection-string "${STORAGE_CONN_STR}" \
  -o table || true

# -----------------------------
# 4) Event Hubs namespace
# -----------------------------
echo "[4/12] Create Event Hubs namespace..."
az eventhubs namespace create \
  --resource-group "${RG}" \
  --name "${EH_NS}" \
  --location "${LOCATION}" \
  --sku Standard \
  --capacity 1 \
  --enable-auto-inflate false \
  -o table

# -----------------------------
# 5) Event Hub
# -----------------------------
echo "[5/12] Create Event Hub..."
az eventhubs eventhub create \
  --resource-group "${RG}" \
  --namespace-name "${EH_NS}" \
  --name "${EH_NAME}" \
  --partition-count 4 \
  --message-retention 1 \
  -o table

# Consumer groups
echo "[5-1/12] Create consumer groups..."
az eventhubs eventhub consumer-group create \
  --resource-group "${RG}" \
  --namespace-name "${EH_NS}" \
  --eventhub-name "${EH_NAME}" \
  --name "${EH_CG_ADX}" \
  -o table

az eventhubs eventhub consumer-group create \
  --resource-group "${RG}" \
  --namespace-name "${EH_NS}" \
  --eventhub-name "${EH_NAME}" \
  --name "${EH_CG_SLOW}" \
  -o table

export EH_ID="$(az eventhubs eventhub show \
  --resource-group "${RG}" \
  --namespace-name "${EH_NS}" \
  --name "${EH_NAME}" \
  --query id -o tsv)"

export EH_NS_ID="$(az eventhubs namespace show \
  --resource-group "${RG}" \
  --name "${EH_NS}" \
  --query id -o tsv)"

# -----------------------------
# 6) Diagnostic settings for Event Hubs
# -----------------------------
echo "[6/12] Enable Event Hubs diagnostic settings..."
az monitor diagnostic-settings create \
  --name "diag-eh-to-law" \
  --resource "${EH_NS_ID}" \
  --workspace "${LOG_WS_ID}" \
  --logs '[{"category":"OperationalLogs","enabled":true},{"category":"RuntimeAuditLogs","enabled":true}]' \
  --metrics '[{"category":"AllMetrics","enabled":true}]' \
  -o table || true

# -----------------------------
# 7) ADX cluster with system-assigned managed identity
# -----------------------------
echo "[7/12] Create ADX cluster..."
az kusto cluster create \
  --resource-group "${RG}" \
  --name "${ADX_CLUSTER}" \
  --location "${LOCATION}" \
  --sku name="${ADX_SKU_NAME}" tier="${ADX_SKU_TIER}" capacity="${ADX_CAPACITY}" \
  --enable-streaming-ingest true \
  --type SystemAssigned \
  -o table

export ADX_ID="$(az kusto cluster show \
  --resource-group "${RG}" \
  --name "${ADX_CLUSTER}" \
  --query id -o tsv)"

export ADX_PRINCIPAL_ID="$(az kusto cluster show \
  --resource-group "${RG}" \
  --name "${ADX_CLUSTER}" \
  --query identity.principalId -o tsv)"

echo "ADX resource id   : ${ADX_ID}"
echo "ADX principal id  : ${ADX_PRINCIPAL_ID}"

# -----------------------------
# 7-1) ADX cluster diagnostic settings -> Log Analytics
#      (required so adx_diagnose can observe ingestion failures/latency/queries)
# -----------------------------
echo "[7-1/12] Enable ADX diagnostic settings..."
az monitor diagnostic-settings create \
  --name "diag-adx-to-law" \
  --resource "${ADX_ID}" \
  --workspace "${LOG_WS_ID}" \
  --logs '[{"category":"SucceededIngestion","enabled":true},{"category":"FailedIngestion","enabled":true},{"category":"IngestionBatching","enabled":true},{"category":"Command","enabled":true},{"category":"Query","enabled":true},{"category":"TableUsageStatistics","enabled":true}]' \
  --metrics '[{"category":"AllMetrics","enabled":true}]' \
  -o table || true

# -----------------------------
# 8) ADX database
# -----------------------------
echo "[8/12] Create ADX database..."
az kusto database create \
  --resource-group "${RG}" \
  --cluster-name "${ADX_CLUSTER}" \
  --database-name "${ADX_DB}" \
  --read-write-database location="${LOCATION}" soft-delete-period="P7D" hot-cache-period="P1D" \
  -o table

# -----------------------------
# 8-1) (Optional) Grant an extra ADX data-plane principal for query / RBAC tests
# -----------------------------
if [[ -n "${ADX_QUERY_PRINCIPAL:-}" ]]; then
  echo "[8-1/12] Add ADX DB admin principal: ${ADX_QUERY_PRINCIPAL}"
  cat > adx_addprincipal.kql <<KQL2
.add database ['${ADX_DB}'] admins ('${ADX_QUERY_PRINCIPAL}') 'adx_diagnose lab principal'
KQL2
  az kusto script create \
    --resource-group "${RG}" \
    --cluster-name "${ADX_CLUSTER}" \
    --database-name "${ADX_DB}" \
    --name "add-principal-$(date +%s)" \
    --script-content "$(cat adx_addprincipal.kql)" \
    --continue-on-errors false \
    -o table || true
fi

# -----------------------------
# 9) Grant ADX Managed Identity permission to read Event Hub
# -----------------------------
echo "[9/12] Grant Azure Event Hubs Data Receiver to ADX managed identity..."
az role assignment create \
  --assignee-object-id "${ADX_PRINCIPAL_ID}" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Event Hubs Data Receiver" \
  --scope "${EH_ID}" \
  -o table || true

# optional: allow current user to manage/query ADX DB
export CURRENT_USER_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "")"

if [[ -n "${CURRENT_USER_OBJECT_ID}" ]]; then
  echo "[9-1/12] Grant current user Contributor on RG for lab operation..."
  az role assignment create \
    --assignee-object-id "${CURRENT_USER_OBJECT_ID}" \
    --assignee-principal-type User \
    --role "Contributor" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}" \
    -o table || true
fi

# -----------------------------
# 10) Create ADX table and JSON mapping
# -----------------------------
echo "[10/12] Create ADX table and JSON ingestion mapping..."

cat > adx_init.kql <<'KQL'
.create-merge table TelemetryRaw (
    Timestamp: datetime,
    DeviceId: string,
    PartitionKey: string,
    MetricName: string,
    MetricValue: real,
    Severity: string,
    Scenario: string,
    Payload: dynamic,
    EventHubEnqueuedTime: datetime,
    EventHubOffset: string,
    EventHubSequenceNumber: long
)

.create-or-alter table TelemetryRaw ingestion json mapping 'TelemetryRawMapping'
'[
  {"column":"Timestamp","path":"$.timestamp","datatype":"datetime"},
  {"column":"DeviceId","path":"$.deviceId","datatype":"string"},
  {"column":"PartitionKey","path":"$.partitionKey","datatype":"string"},
  {"column":"MetricName","path":"$.metricName","datatype":"string"},
  {"column":"MetricValue","path":"$.metricValue","datatype":"real"},
  {"column":"Severity","path":"$.severity","datatype":"string"},
  {"column":"Scenario","path":"$.scenario","datatype":"string"},
  {"column":"Payload","path":"$","datatype":"dynamic"},
  {"column":"EventHubEnqueuedTime","Properties":{"Path":"x-opt-enqueued-time"},"datatype":"datetime"},
  {"column":"EventHubOffset","Properties":{"Path":"x-opt-offset"},"datatype":"string"},
  {"column":"EventHubSequenceNumber","Properties":{"Path":"x-opt-sequence-number"},"datatype":"long"}
]'

// Small batching window so ingestion is observable quickly during tests (default is up to 5 min).
.alter table TelemetryRaw policy ingestionbatching '{"MaximumBatchingTimeSpan":"00:00:30", "MaximumNumberOfItems": 1000, "MaximumRawDataSizeMB": 1024}'
KQL

# ADX database script resource로 KQL 실행
az kusto script create \
  --resource-group "${RG}" \
  --cluster-name "${ADX_CLUSTER}" \
  --database-name "${ADX_DB}" \
  --name "init-${ADX_TABLE}" \
  --script-content "$(cat adx_init.kql)" \
  --continue-on-errors false \
  --force-update-tag "$(date +%s)" \
  -o table

# -----------------------------
# 11) Create ADX Event Hub data connection
# -----------------------------
echo "[11/12] Create ADX Event Hub data connection..."

az kusto data-connection event-hub create \
  --resource-group "${RG}" \
  --cluster-name "${ADX_CLUSTER}" \
  --database-name "${ADX_DB}" \
  --name "${ADX_CONN}" \
  --location "${LOCATION}" \
  --event-hub-resource-id "${EH_ID}" \
  --consumer-group "${EH_CG_ADX}" \
  --table-name "${ADX_TABLE}" \
  --mapping-rule-name "${ADX_MAPPING}" \
  --data-format "JSON" \
  --compression "None" \
  --event-system-properties x-opt-enqueued-time x-opt-offset x-opt-sequence-number \
  --managed-identity-resource-id "${ADX_ID}" \
  -o table

# -----------------------------
# 12) Get connection string for test producer/consumer
# -----------------------------
echo "[12/12] Generate Event Hub connection string for local test..."

export EH_CONN_STR="$(az eventhubs namespace authorization-rule keys list \
  --resource-group "${RG}" \
  --namespace-name "${EH_NS}" \
  --name RootManageSharedAccessKey \
  --query primaryConnectionString -o tsv)"

cat > lab.env <<EOF
export SUBSCRIPTION_ID="${SUBSCRIPTION_ID}"
export LOCATION="${LOCATION}"
export RG="${RG}"
export EH_NS="${EH_NS}"
export EH_NAME="${EH_NAME}"
export EH_CG_ADX="${EH_CG_ADX}"
export EH_CG_SLOW="${EH_CG_SLOW}"
export EH_ID="${EH_ID}"
export EH_CONN_STR="${EH_CONN_STR}"
export ADX_CLUSTER="${ADX_CLUSTER}"
export ADX_DB="${ADX_DB}"
export ADX_TABLE="${ADX_TABLE}"
export ADX_ID="${ADX_ID}"
export ADX_CONN="${ADX_CONN}"
export LOG_WS="${LOG_WS}"
export TENANT_ID="${TENANT_ID}"
export STORAGE_ACCT="${STORAGE_ACCT}"
export STORAGE_CONN_STR="${STORAGE_CONN_STR}"
export BLOB_CONTAINER="${BLOB_CONTAINER}"
export EH_NS_FQDN="${EH_NS}.servicebus.windows.net"
export ADX_QUERY_URI="https://${ADX_CLUSTER}.${LOCATION}.kusto.windows.net"
EOF

echo ""
echo "============================================================"
echo "LAB CREATED"
echo "============================================================"
echo "Run:"
echo "  source ./lab.env"
echo "  python3 -m venv .venv"
echo "  source .venv/bin/activate"
echo "  pip install -r requirements.txt"
echo "  python 01_send_events.py --mode normal --count 5000"
echo "  python 03_verify.py                 # assert expected diagnostic signals"
echo ""
echo "ADX Query endpoint:"
echo "  https://dataexplorer.azure.com/clusters/${ADX_CLUSTER}.${LOCATION}.kusto.windows.net/databases/${ADX_DB}"
echo ""
echo "Saved variables to ./lab.env"
echo "============================================================"
`