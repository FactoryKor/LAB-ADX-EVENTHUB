<#
============================================================
 Event Hub + ADX Diagnostic Test Lab  (Windows / PowerShell)
 PowerShell port of 00_create_lab.sh
 Run in Windows PowerShell / PowerShell 7 with Azure CLI installed and `az login` done.

 Usage:
   ./00_create_lab.ps1
   $env:ADX_QUERY_PRINCIPAL = "aadapp=<appId>;<tenantId>"; ./00_create_lab.ps1
============================================================
#>
$ErrorActionPreference = 'Stop'

# Run an az command and throw if it fails (emulates `set -e`).
function Invoke-Az {
    az @args
    if ($LASTEXITCODE -ne 0) { throw "az failed (exit $LASTEXITCODE): az $($args -join ' ')" }
}

# -----------------------------
# 0) User variables
# -----------------------------
$SubscriptionId = az account show --query id -o tsv
$TenantId       = az account show --query tenantId -o tsv
$Location       = if ($env:LOCATION) { $env:LOCATION } else { 'koreacentral' }

# Unique suffix to avoid name collisions (override $env:SUFFIX to reuse names)
$Suffix = if ($env:SUFFIX) { $env:SUFFIX } else { (Get-Date -Format 'MMddHHmm') }

$Rg        = "rg-eh-adx-diag-lab-$Suffix"
$EhNs      = "ehnsdiag$Suffix"
$EhName    = "telemetry-events"
$EhCgAdx   = "adx-cg"
$EhCgSlow  = "slow-cg"

$AdxCluster = "adxdiag$Suffix"
$AdxDb      = "diagdb"
$AdxTable   = "TelemetryRaw"
$AdxMapping = "TelemetryRawMapping"
$AdxConn    = "conn-eh-telemetry"

$LogWs = "law-eh-adx-diag-$Suffix"

# Storage account for Event Hub consumer checkpoint store (3-24 lowercase alnum)
$StorageAcct  = "stehadx$Suffix"
$BlobContainer = "checkpoints"

# Optional extra ADX data-plane principal for adx_diagnose / RBAC tests.
# e.g. "aadapp=<appId>;<tenantId>" or "aaduser=<upn>"
$AdxQueryPrincipal = $env:ADX_QUERY_PRINCIPAL

# ADX SKU (override via env if unavailable in your region/subscription)
$AdxSkuName = if ($env:ADX_SKU_NAME) { $env:ADX_SKU_NAME } else { 'Standard_D11_v2' }
$AdxSkuTier = if ($env:ADX_SKU_TIER) { $env:ADX_SKU_TIER } else { 'Standard' }
$AdxCapacity = if ($env:ADX_CAPACITY) { $env:ADX_CAPACITY } else { '2' }

Write-Host "============================================================"
Write-Host "Subscription : $SubscriptionId"
Write-Host "Location     : $Location"
Write-Host "ResourceGroup: $Rg"
Write-Host "EventHub NS  : $EhNs"
Write-Host "ADX Cluster  : $AdxCluster"
Write-Host "ADX DB       : $AdxDb"
Write-Host "============================================================"

# -----------------------------
# 1) Provider registration
# -----------------------------
Write-Host "[1/12] Register providers..."
az provider register --namespace Microsoft.EventHub --wait
az provider register --namespace Microsoft.Kusto --wait
az provider register --namespace Microsoft.OperationalInsights --wait
az provider register --namespace Microsoft.Insights --wait
az provider register --namespace Microsoft.Storage --wait
az extension add --name kusto --upgrade 2>$null
$global:LASTEXITCODE = 0

# -----------------------------
# 2) Resource group
# -----------------------------
Write-Host "[2/12] Create resource group..."
Invoke-Az group create --name $Rg --location $Location -o table

# -----------------------------
# 3) Log Analytics workspace
# -----------------------------
Write-Host "[3/12] Create Log Analytics workspace..."
Invoke-Az monitor log-analytics workspace create --resource-group $Rg --workspace-name $LogWs --location $Location -o table
$LogWsId = az monitor log-analytics workspace show --resource-group $Rg --workspace-name $LogWs --query id -o tsv

# -----------------------------
# 3-1) Storage account (Event Hub consumer checkpoint store)
# -----------------------------
Write-Host "[3-1/12] Create Storage account for checkpoint store..."
Invoke-Az storage account create --name $StorageAcct --resource-group $Rg --location $Location --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 -o table
$StorageConnStr = az storage account show-connection-string --name $StorageAcct --resource-group $Rg --query connectionString -o tsv
az storage container create --name $BlobContainer --connection-string $StorageConnStr -o table
$global:LASTEXITCODE = 0

# -----------------------------
# 4) Event Hubs namespace
# -----------------------------
Write-Host "[4/12] Create Event Hubs namespace..."
Invoke-Az eventhubs namespace create --resource-group $Rg --name $EhNs --location $Location --sku Standard --capacity 1 --enable-auto-inflate false -o table

# -----------------------------
# 5) Event Hub + consumer groups
# -----------------------------
Write-Host "[5/12] Create Event Hub..."
Invoke-Az eventhubs eventhub create --resource-group $Rg --namespace-name $EhNs --name $EhName --partition-count 4 --message-retention 1 -o table

Write-Host "[5-1/12] Create consumer groups..."
Invoke-Az eventhubs eventhub consumer-group create --resource-group $Rg --namespace-name $EhNs --eventhub-name $EhName --name $EhCgAdx -o table
Invoke-Az eventhubs eventhub consumer-group create --resource-group $Rg --namespace-name $EhNs --eventhub-name $EhName --name $EhCgSlow -o table

$EhId   = az eventhubs eventhub show --resource-group $Rg --namespace-name $EhNs --name $EhName --query id -o tsv
$EhNsId = az eventhubs namespace show --resource-group $Rg --name $EhNs --query id -o tsv

# -----------------------------
# 6) Diagnostic settings for Event Hubs
# -----------------------------
Write-Host "[6/12] Enable Event Hubs diagnostic settings..."
Set-Content -Path .\_eh_logs.json    -Encoding ascii -Value '[{"category":"OperationalLogs","enabled":true},{"category":"RuntimeAuditLogs","enabled":true}]'
Set-Content -Path .\_all_metrics.json -Encoding ascii -Value '[{"category":"AllMetrics","enabled":true}]'
az monitor diagnostic-settings create --name "diag-eh-to-law" --resource $EhNsId --workspace $LogWsId --logs "@_eh_logs.json" --metrics "@_all_metrics.json" -o table
$global:LASTEXITCODE = 0

# -----------------------------
# 7) ADX cluster (system-assigned managed identity)
# -----------------------------
Write-Host "[7/12] Create ADX cluster..."
Invoke-Az kusto cluster create --resource-group $Rg --name $AdxCluster --location $Location --sku "name=$AdxSkuName" "tier=$AdxSkuTier" "capacity=$AdxCapacity" --enable-streaming-ingest true --type SystemAssigned -o table

$AdxId          = az kusto cluster show --resource-group $Rg --name $AdxCluster --query id -o tsv
$AdxPrincipalId = az kusto cluster show --resource-group $Rg --name $AdxCluster --query identity.principalId -o tsv
Write-Host "ADX resource id   : $AdxId"
Write-Host "ADX principal id  : $AdxPrincipalId"

# -----------------------------
# 7-1) ADX cluster diagnostic settings -> Log Analytics
# -----------------------------
Write-Host "[7-1/12] Enable ADX diagnostic settings..."
Set-Content -Path .\_adx_logs.json -Encoding ascii -Value '[{"category":"SucceededIngestion","enabled":true},{"category":"FailedIngestion","enabled":true},{"category":"IngestionBatching","enabled":true},{"category":"Command","enabled":true},{"category":"Query","enabled":true},{"category":"TableUsageStatistics","enabled":true}]'
az monitor diagnostic-settings create --name "diag-adx-to-law" --resource $AdxId --workspace $LogWsId --logs "@_adx_logs.json" --metrics "@_all_metrics.json" -o table
$global:LASTEXITCODE = 0

# -----------------------------
# 8) ADX database
# -----------------------------
Write-Host "[8/12] Create ADX database..."
Invoke-Az kusto database create --resource-group $Rg --cluster-name $AdxCluster --database-name $AdxDb --read-write-database "location=$Location" "soft-delete-period=P7D" "hot-cache-period=P1D" -o table

# -----------------------------
# 8-1) (Optional) extra ADX data-plane principal
# -----------------------------
if ($AdxQueryPrincipal) {
    Write-Host "[8-1/12] Add ADX DB admin principal: $AdxQueryPrincipal"
    Set-Content -Path .\adx_addprincipal.kql -Encoding ascii -Value ".add database ['$AdxDb'] admins ('$AdxQueryPrincipal') 'adx_diagnose lab principal'"
    az kusto script create --resource-group $Rg --cluster-name $AdxCluster --database-name $AdxDb --name "add-principal-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" --script-content "@adx_addprincipal.kql" --continue-on-errors false -o table
    $global:LASTEXITCODE = 0
}

# -----------------------------
# 9) Grant ADX Managed Identity permission to read Event Hub
# -----------------------------
Write-Host "[9/12] Grant Azure Event Hubs Data Receiver to ADX managed identity..."
az role assignment create --assignee-object-id $AdxPrincipalId --assignee-principal-type ServicePrincipal --role "Azure Event Hubs Data Receiver" --scope $EhId -o table
$global:LASTEXITCODE = 0

$CurrentUserObjectId = az ad signed-in-user show --query id -o tsv 2>$null
if (-not $CurrentUserObjectId) { $CurrentUserObjectId = "" }
$global:LASTEXITCODE = 0

if ($CurrentUserObjectId) {
    Write-Host "[9-1/12] Grant current user Contributor on RG for lab operation..."
    az role assignment create --assignee-object-id $CurrentUserObjectId --assignee-principal-type User --role "Contributor" --scope "/subscriptions/$SubscriptionId/resourceGroups/$Rg" -o table
    $global:LASTEXITCODE = 0
}

# -----------------------------
# 10) Create ADX table + JSON mapping + batching policy
# -----------------------------
Write-Host "[10/12] Create ADX table and JSON ingestion mapping..."
$adxInit = @'
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

.alter table TelemetryRaw policy ingestionbatching '{"MaximumBatchingTimeSpan":"00:00:30", "MaximumNumberOfItems": 1000, "MaximumRawDataSizeMB": 1024}'
'@
Set-Content -Path .\adx_init.kql -Encoding ascii -Value $adxInit

Invoke-Az kusto script create --resource-group $Rg --cluster-name $AdxCluster --database-name $AdxDb --name "init-$AdxTable" --script-content "@adx_init.kql" --continue-on-errors false --force-update-tag "$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" -o table

# -----------------------------
# 11) Create ADX Event Hub data connection
# -----------------------------
Write-Host "[11/12] Create ADX Event Hub data connection..."
Invoke-Az kusto data-connection event-hub create --resource-group $Rg --cluster-name $AdxCluster --database-name $AdxDb --name $AdxConn --location $Location --event-hub-resource-id $EhId --consumer-group $EhCgAdx --table-name $AdxTable --mapping-rule-name $AdxMapping --data-format "JSON" --compression "None" --event-system-properties x-opt-enqueued-time x-opt-offset x-opt-sequence-number --managed-identity-resource-id $AdxId -o table

# -----------------------------
# 12) Connection string + write lab.ps1
# -----------------------------
Write-Host "[12/12] Generate Event Hub connection string for local test..."
$EhConnStr = az eventhubs namespace authorization-rule keys list --resource-group $Rg --namespace-name $EhNs --name RootManageSharedAccessKey --query primaryConnectionString -o tsv

$labLines = @(
    "`$env:SUBSCRIPTION_ID = '$SubscriptionId'"
    "`$env:TENANT_ID = '$TenantId'"
    "`$env:LOCATION = '$Location'"
    "`$env:RG = '$Rg'"
    "`$env:EH_NS = '$EhNs'"
    "`$env:EH_NAME = '$EhName'"
    "`$env:EH_CG_ADX = '$EhCgAdx'"
    "`$env:EH_CG_SLOW = '$EhCgSlow'"
    "`$env:EH_ID = '$EhId'"
    "`$env:EH_CONN_STR = '$EhConnStr'"
    "`$env:EH_NS_FQDN = '$EhNs.servicebus.windows.net'"
    "`$env:ADX_CLUSTER = '$AdxCluster'"
    "`$env:ADX_DB = '$AdxDb'"
    "`$env:ADX_TABLE = '$AdxTable'"
    "`$env:ADX_ID = '$AdxId'"
    "`$env:ADX_CONN = '$AdxConn'"
    "`$env:ADX_QUERY_URI = 'https://$AdxCluster.$Location.kusto.windows.net'"
    "`$env:LOG_WS = '$LogWs'"
    "`$env:STORAGE_ACCT = '$StorageAcct'"
    "`$env:STORAGE_CONN_STR = '$StorageConnStr'"
    "`$env:BLOB_CONTAINER = '$BlobContainer'"
)
Set-Content -Path .\lab.ps1 -Encoding utf8 -Value $labLines

# cleanup temp json files
Remove-Item .\_eh_logs.json, .\_all_metrics.json, .\_adx_logs.json -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "============================================================"
Write-Host "LAB CREATED"
Write-Host "============================================================"
Write-Host "Run:"
Write-Host "  . .\lab.ps1                       # dot-source to load env vars"
Write-Host "  python -m venv .venv"
Write-Host "  .\.venv\Scripts\Activate.ps1"
Write-Host "  pip install -r requirements.txt"
Write-Host "  python 01_send_events.py --mode normal --count 5000"
Write-Host "  python 03_verify.py"
Write-Host ""
Write-Host "ADX Query endpoint:"
Write-Host "  https://$AdxCluster.$Location.kusto.windows.net/databases/$AdxDb"
Write-Host ""
Write-Host "Saved variables to .\lab.ps1"
Write-Host "============================================================"
