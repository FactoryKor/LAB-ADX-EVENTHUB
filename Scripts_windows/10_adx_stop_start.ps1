<#
  Pause / resume the ADX cluster to save compute cost (Windows / PowerShell).
  PowerShell port of 10_adx_stop_start.sh
  Usage: ./10_adx_stop_start.ps1 -Action start|stop|status
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('start', 'stop', 'status')]
    [string]$Action
)

if (Test-Path .\lab.ps1) { . .\lab.ps1 }

if (-not $env:RG -or -not $env:ADX_CLUSTER) {
    Write-Error "RG / ADX_CLUSTER not set. Run: . .\lab.ps1"
    exit 1
}

switch ($Action) {
    'stop' {
        Write-Host "Stopping ADX cluster '$($env:ADX_CLUSTER)' (compute billing pauses)..."
        az kusto cluster stop --resource-group $env:RG --name $env:ADX_CLUSTER --no-wait
        Write-Host "Stop submitted."
    }
    'start' {
        Write-Host "Starting ADX cluster '$($env:ADX_CLUSTER)'..."
        az kusto cluster start --resource-group $env:RG --name $env:ADX_CLUSTER --no-wait
        Write-Host "Start submitted."
    }
    'status' {
        az kusto cluster show --resource-group $env:RG --name $env:ADX_CLUSTER `
            --query "{name:name,state:state,provisioningState:provisioningState}" -o table
    }
}
