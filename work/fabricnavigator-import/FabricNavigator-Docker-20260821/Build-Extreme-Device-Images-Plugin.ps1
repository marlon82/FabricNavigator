[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$PluginVersion,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceDirectory,
    [string]$OutputDirectory = '',
    [string]$PythonExecutable = 'python'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'dist' }
$source = (Resolve-Path -LiteralPath $SourceDirectory).Path
$optimizer = Join-Path $PSScriptRoot 'Optimize-Extreme-Device-Images.py'
$windowsInstaller = Join-Path $PSScriptRoot 'Install-Extreme-Device-Images.ps1'
$linuxInstaller = Join-Path $PSScriptRoot 'install-extreme-device-images.sh'
foreach ($required in @($source, $optimizer, $windowsInstaller, $linuxInstaller)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required plugin source is missing: $required" }
}
$python = Get-Command $PythonExecutable -ErrorAction Stop
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('FabricNavigator-Images-' + [Guid]::NewGuid().ToString('N'))
$stage = Join-Path $temporaryRoot 'stage'
$plugin = Join-Path $stage 'plugin'
New-Item -ItemType Directory -Force -Path $plugin, $OutputDirectory | Out-Null
try {
    & $python.Source $optimizer $source $plugin --version $PluginVersion
    if ($LASTEXITCODE -ne 0) { throw 'Image optimization failed.' }
    Copy-Item -LiteralPath $windowsInstaller -Destination $stage
    Copy-Item -LiteralPath $linuxInstaller -Destination $stage
    $archivePath = Join-Path $OutputDirectory "FabricNavigator-Extreme-Device-Images-$PluginVersion.zip"
    if (Test-Path -LiteralPath $archivePath) { Remove-Item -Force -LiteralPath $archivePath }
    $archive = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        Get-ChildItem -LiteralPath $stage -Recurse -File | ForEach-Object {
            $entry = $_.FullName.Substring($stage.Length).TrimStart('\', '/').Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally { $archive.Dispose() }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$archivePath.sha256", "$hash  $([IO.Path]::GetFileName($archivePath))`n", [Text.UTF8Encoding]::new($false))
    Get-Item -LiteralPath $archivePath
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -Recurse -Force -LiteralPath $temporaryRoot }
}
