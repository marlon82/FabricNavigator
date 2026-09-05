[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string]$Version,

    [string]$InstallerArchive = '',
    [string]$OutputDirectory = '',
    [string]$Repository = 'marlon82/FabricNavigator'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw 'Repository must use OWNER/REPOSITORY format.'
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'dist' }
if (-not $InstallerArchive) {
    $InstallerArchive = Join-Path $PSScriptRoot "..\work\fabricnavigator-import\FabricNavigator-Docker-20260821\dist\FabricNavigator-Installer-$Version.zip"
}
$InstallerArchive = (Resolve-Path -LiteralPath $InstallerArchive).Path

$required = @(
    'install-fabricnavigator.sh',
    'README-Linux.md',
    'README-Linux-Online.md',
    '..\proxmox\guest\fabricnavigator-token',
    '..\proxmox\guest\fabricnavigator-updater.py',
    '..\proxmox\guest\fabricnavigator-updater.service'
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $relative) -PathType Leaf)) {
        throw "Required Linux installer file is missing: $relative"
    }
}

function Expand-SafeArchive {
    param([string]$Archive, [string]$Destination)
    $destinationRoot = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($entry in $zip.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (-not $target.StartsWith($destinationRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Unsafe ZIP path: $($entry.FullName)"
            }
            if (-not $entry.Name) {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
                continue
            }
            New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
            $input = $entry.Open()
            $output = [IO.File]::Create($target)
            try { $input.CopyTo($output) } finally { $input.Dispose(); $output.Dispose() }
        }
    } finally {
        $zip.Dispose()
    }
}

function New-PortableZipArchive {
    param([string]$SourceDirectory, [string]$DestinationArchive)
    if (Test-Path -LiteralPath $DestinationArchive) { Remove-Item -Force -LiteralPath $DestinationArchive }
    $sourceRoot = (Resolve-Path -LiteralPath $SourceDirectory).Path.TrimEnd('\', '/')
    $archive = [IO.Compression.ZipFile]::Open($DestinationArchive, [IO.Compression.ZipArchiveMode]::Create)
    try {
        Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File | ForEach-Object {
            $entryName = $_.FullName.Substring($sourceRoot.Length).TrimStart('\', '/').Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive, $_.FullName, $entryName, [IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    } finally {
        $archive.Dispose()
    }
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('FabricNavigator-Linux-' + [Guid]::NewGuid().ToString('N'))
$stage = Join-Path $temporary "FabricNavigator-Linux-$Version"
New-Item -ItemType Directory -Force -Path $stage | Out-Null
try {
    Expand-SafeArchive -Archive $InstallerArchive -Destination $stage
    foreach ($windowsFile in @('Import-FabricNavigator.ps1', 'FabricNavigator-Updater.ps1', 'README-Windows.md')) {
        $candidate = Join-Path $stage $windowsFile
        if (Test-Path -LiteralPath $candidate) { Remove-Item -Force -LiteralPath $candidate }
    }

    $installer = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'install-fabricnavigator.sh'))
    $installer = $installer.Replace('__VERSION__', $Version).Replace('__REPOSITORY__', $Repository)
    [IO.File]::WriteAllText((Join-Path $stage 'install-fabricnavigator.sh'), $installer.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README-Linux.md') -Destination (Join-Path $stage 'README-Linux.md')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\proxmox\guest\fabricnavigator-token') -Destination (Join-Path $stage 'fabricnavigator-token')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\proxmox\guest\fabricnavigator-updater.py') -Destination (Join-Path $stage 'fabricnavigator-updater.py') -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\proxmox\guest\fabricnavigator-updater.service') -Destination (Join-Path $stage 'fabricnavigator-updater.service') -Force

    foreach ($file in @('README-Linux.md', 'fabricnavigator-token', 'fabricnavigator-updater.py', 'fabricnavigator-updater.service')) {
        $path = Join-Path $stage $file
        $content = [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
        if ($file -eq 'README-Linux.md') {
            $content = $content.Replace('26.09.10.231', $Version)
        }
        [IO.File]::WriteAllText($path, $content, [Text.UTF8Encoding]::new($false))
    }

    $image = @(Get-ChildItem -LiteralPath $stage -File -Filter 'FabricNavigator-Image-*.tar.gz')
    if ($image.Count -ne 1 -or $image[0].Name -ne "FabricNavigator-Image-$Version.tar.gz") {
        throw "The source installer does not contain the matching FabricNavigator image for $Version."
    }
    foreach ($requiredFile in @('compose.yaml', '.env.example', 'fabricnavigator-updater.py', 'fabricnavigator-updater.service')) {
        if (-not (Test-Path -LiteralPath (Join-Path $stage $requiredFile) -PathType Leaf)) {
            throw "The source installer is incomplete: $requiredFile"
        }
    }

    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $archive = Join-Path $OutputDirectory "FabricNavigator-Linux-Installer-$Version.zip"
    # Keep all files below one versioned directory so extracting the archive
    # never scatters installer payload into the caller's current directory.
    New-PortableZipArchive -SourceDirectory $temporary -DestinationArchive $archive
    $tarCommand = Get-Command tar -ErrorAction Stop
    $tarArchive = Join-Path $OutputDirectory "FabricNavigator-Linux-Installer-$Version.tar.gz"
    if (Test-Path -LiteralPath $tarArchive) { Remove-Item -Force -LiteralPath $tarArchive }
    & $tarCommand.Source -czf $tarArchive -C $temporary "FabricNavigator-Linux-$Version"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tarArchive -PathType Leaf)) {
        throw 'Could not create the Linux tar.gz installer.'
    }

    $zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    $tarHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $tarArchive).Hash.ToLowerInvariant()

    $onlineStageName = 'FabricNavigator-Linux-Online-Installer'
    $onlineStage = Join-Path $temporary $onlineStageName
    New-Item -ItemType Directory -Force -Path $onlineStage | Out-Null
    $onlineInstaller = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'install-fabricnavigator.sh'))
    $onlineInstaller = $onlineInstaller.Replace('__VERSION__', 'latest').Replace('__REPOSITORY__', $Repository)
    [IO.File]::WriteAllText(
        (Join-Path $onlineStage 'install-fabricnavigator.sh'),
        $onlineInstaller.Replace("`r`n", "`n"),
        [Text.UTF8Encoding]::new($false)
    )
    foreach ($onlineFile in @('README-Linux-Online.md', '..\proxmox\guest\fabricnavigator-token')) {
        $source = Join-Path $PSScriptRoot $onlineFile
        $destinationName = if ($onlineFile -like '*fabricnavigator-token') { 'fabricnavigator-token' } else { 'README-Linux-Online.md' }
        $content = [IO.File]::ReadAllText($source).Replace("`r`n", "`n")
        [IO.File]::WriteAllText((Join-Path $onlineStage $destinationName), $content, [Text.UTF8Encoding]::new($false))
    }
    $onlineArchive = Join-Path $OutputDirectory 'FabricNavigator-Linux-Online-Installer.tar.gz'
    if (Test-Path -LiteralPath $onlineArchive) { Remove-Item -Force -LiteralPath $onlineArchive }
    & $tarCommand.Source -czf $onlineArchive -C $temporary $onlineStageName
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $onlineArchive -PathType Leaf)) {
        throw 'Could not create the Linux online installer.'
    }
    $onlineHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $onlineArchive).Hash.ToLowerInvariant()

    $manifest = Join-Path $OutputDirectory "SHA256SUMS-Linux-$Version"
    $checksums = @(
        "$onlineHash  $([IO.Path]::GetFileName($onlineArchive))"
        "$tarHash  $([IO.Path]::GetFileName($tarArchive))"
        "$zipHash  $([IO.Path]::GetFileName($archive))"
    ) -join "`n"
    [IO.File]::WriteAllText($manifest, "$checksums`n", [Text.UTF8Encoding]::new($false))
    Write-Host 'Linux installers created:' -ForegroundColor Green
    Write-Host "  $onlineArchive"
    Write-Host "  $tarArchive"
    Write-Host "  $archive"
    Write-Host $checksums
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -Recurse -Force -LiteralPath $temporary }
}
