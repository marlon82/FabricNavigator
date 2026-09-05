[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string]$Version = '26.08.10.117',

    [Parameter(Mandatory)]
    [string]$FabricNavigatorInstaller,

    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'dist' }
$installerPath = (Resolve-Path -LiteralPath $FabricNavigatorInstaller).Path

$required = @(
    @{ Source = (Join-Path $PSScriptRoot 'create-fabricnavigator-esxi-ova.sh'); Destination = 'create-fabricnavigator-esxi-ova.sh' },
    @{ Source = (Join-Path $PSScriptRoot 'README-ESXi.md'); Destination = 'README-ESXi.md' },
    @{ Source = (Join-Path $PSScriptRoot 'guest\fabricnavigator-firstboot.sh'); Destination = 'guest\fabricnavigator-firstboot.sh' },
    @{ Source = (Join-Path $PSScriptRoot 'guest\fabricnavigator-firstboot.service'); Destination = 'guest\fabricnavigator-firstboot.service' },
    @{ Source = (Join-Path $PSScriptRoot '..\proxmox\guest\fabricnavigator-token'); Destination = 'guest\fabricnavigator-token' },
    @{ Source = (Join-Path $PSScriptRoot '..\proxmox\guest\fabricnavigator-updater.py'); Destination = 'guest\fabricnavigator-updater.py' },
    @{ Source = (Join-Path $PSScriptRoot '..\proxmox\guest\fabricnavigator-updater.service'); Destination = 'guest\fabricnavigator-updater.service' }
)
foreach ($item in $required) {
    if (-not (Test-Path -LiteralPath $item.Source -PathType Leaf)) {
        throw "Required package file is missing: $($item.Source)"
    }
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('FabricNavigator-ESXi-' + [Guid]::NewGuid().ToString('N'))
$stage = Join-Path $temporary "FabricNavigator-ESXi-$Version"
New-Item -ItemType Directory -Force -Path $stage | Out-Null
try {
    foreach ($item in $required) {
        $destination = Join-Path $stage $item.Destination
        New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
        Copy-Item -LiteralPath $item.Source -Destination $destination
    }
    $payloadName = "FabricNavigator-ESXi-Payload-$Version.zip"
    Copy-Item -LiteralPath $installerPath -Destination (Join-Path $stage $payloadName)

    $readmePath = Join-Path $stage 'README-ESXi.md'
    $readmeContent = [IO.File]::ReadAllText($readmePath)
    $readmeContent = [Regex]::Replace($readmeContent, '\d{2}\.\d{2}\.\d{2}\.\d+', $Version)
    [IO.File]::WriteAllText($readmePath, $readmeContent, [Text.UTF8Encoding]::new($false))

    foreach ($file in Get-ChildItem -LiteralPath $stage -Recurse -File | Where-Object Extension -in @('.sh', '.service', '.py', '.md')) {
        $content = [IO.File]::ReadAllText($file.FullName)
        [IO.File]::WriteAllText($file.FullName, $content.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    }

    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $archive = Join-Path $OutputDirectory "FabricNavigator-ESXi-Installer-$Version.zip"
    if (Test-Path -LiteralPath $archive) { Remove-Item -Force -LiteralPath $archive }
    Add-Type -AssemblyName System.IO.Compression
    $archiveStream = [IO.File]::Create($archive)
    try {
        $zip = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($file in Get-ChildItem -LiteralPath $stage -Recurse -File) {
                $entryName = $file.FullName.Substring($temporary.Length + 1).Replace('\', '/')
                $compression = if ($file.Extension -eq '.zip') { [IO.Compression.CompressionLevel]::NoCompression } else { [IO.Compression.CompressionLevel]::Optimal }
                $entry = $zip.CreateEntry($entryName, $compression)
                $entryStream = $entry.Open()
                $inputStream = $file.OpenRead()
                try { $inputStream.CopyTo($entryStream) } finally { $inputStream.Dispose(); $entryStream.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $archiveStream.Dispose() }

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    $checksum = Join-Path $OutputDirectory "SHA256SUMS-ESXi-$Version"
    [IO.File]::WriteAllText($checksum, "$hash  $([IO.Path]::GetFileName($archive))`n", [Text.UTF8Encoding]::new($false))
    Write-Host "Created $archive"
    Write-Host "$hash  $([IO.Path]::GetFileName($archive))"
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -Recurse -Force -LiteralPath $temporary }
}
