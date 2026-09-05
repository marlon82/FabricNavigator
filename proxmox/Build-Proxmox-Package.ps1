[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string]$Version = '26.08.10.116',
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'dist' }
$required = @(
    'create-fabricnavigator-template.sh',
    'README-Proxmox.md',
    'guest\fabricnavigator-firstboot.sh',
    'guest\fabricnavigator-token',
    'guest\fabricnavigator-updater.py',
    'guest\migrate-fabricnavigator-updater.sh',
    'guest\fabricnavigator-firstboot.service',
    'guest\fabricnavigator-updater.service'
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $relative) -PathType Leaf)) {
        throw "Required package file is missing: $relative"
    }
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('FabricNavigator-Proxmox-' + [Guid]::NewGuid().ToString('N'))
$stage = Join-Path $temporary "FabricNavigator-Proxmox-$Version"
New-Item -ItemType Directory -Force -Path $stage | Out-Null
try {
    foreach ($relative in $required) {
        $destination = Join-Path $stage $relative
        New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $relative) -Destination $destination
    }
    # Keep the generated builder's default release and its bundled instructions
    # aligned with the package version selected above. Source files intentionally
    # retain examples that can also be used outside a generated release archive.
    foreach ($relative in @('create-fabricnavigator-template.sh', 'README-Proxmox.md')) {
        $path = Join-Path $stage $relative
        $content = [IO.File]::ReadAllText($path)
        $content = [Regex]::Replace($content, '\d{2}\.\d{2}\.\d{2}\.\d+', $Version)
        [IO.File]::WriteAllText($path, $content, [Text.UTF8Encoding]::new($false))
    }
    # Git blobs and Linux shells require LF regardless of the Windows checkout.
    foreach ($file in Get-ChildItem -LiteralPath $stage -Recurse -File) {
        $content = [IO.File]::ReadAllText($file.FullName)
        [IO.File]::WriteAllText($file.FullName, $content.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    }
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $archive = Join-Path $OutputDirectory "FabricNavigator-Proxmox-Template-Builder-$Version.zip"
    if (Test-Path -LiteralPath $archive) { Remove-Item -Force -LiteralPath $archive }
    Add-Type -AssemblyName System.IO.Compression
    $archiveStream = [IO.File]::Create($archive)
    try {
        $zip = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($file in Get-ChildItem -LiteralPath $stage -Recurse -File) {
                $entryName = $file.FullName.Substring($temporary.Length + 1).Replace('\', '/')
                $entry = $zip.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
                $entryStream = $entry.Open()
                $inputStream = $file.OpenRead()
                try { $inputStream.CopyTo($entryStream) } finally { $inputStream.Dispose(); $entryStream.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $archiveStream.Dispose() }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(
        (Join-Path $OutputDirectory "SHA256SUMS-Proxmox-$Version"),
        "$hash  $([IO.Path]::GetFileName($archive))`n",
        [Text.UTF8Encoding]::new($false)
    )
    Write-Host "Created $archive"
    Write-Host "$hash  $([IO.Path]::GetFileName($archive))"
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -Recurse -Force -LiteralPath $temporary }
}
