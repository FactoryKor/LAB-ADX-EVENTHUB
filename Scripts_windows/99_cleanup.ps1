<#
  Delete the entire lab resource group (Windows / PowerShell).
  PowerShell port of 99_cleanup.sh
  Usage: ./99_cleanup.ps1
#>
$ErrorActionPreference = 'Stop'

if (Test-Path .\lab.ps1) { . .\lab.ps1 }

if (-not $env:RG) {
    Write-Error "RG is not set. Run: . .\lab.ps1"
    exit 1
}

Write-Host "Deleting resource group: $($env:RG)"
az group delete --name $env:RG --yes --no-wait
Write-Host "Delete submitted."
