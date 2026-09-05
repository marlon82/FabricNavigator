[CmdletBinding()]
param([string]$InstallDirectory = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'plugin'
$destination = Join-Path $InstallDirectory 'plugins\extreme-device-images'
if (-not (Test-Path -LiteralPath (Join-Path $source 'plugin.json'))) { throw 'The Extreme image plugin payload is missing.' }
New-Item -ItemType Directory -Force -Path $destination | Out-Null
Get-ChildItem -LiteralPath $destination -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force
Write-Host "Extreme device images installed in $destination"
Write-Host 'Reload the FabricNavigator topology page to use the product images.'
