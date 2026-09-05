[CmdletBinding()]
param(
    [string]$Archive = "",
    [string]$GitHubRepository = "marlon82/FabricNavigator",
    [string]$GitHubTokenFile = "",
    [switch]$SkipUpdater
)

$ErrorActionPreference = 'Stop'
$InstallDirectory = $PSScriptRoot

function Set-EnvironmentSetting {
    param([string]$Name, [string]$Value)
    $path = Join-Path $InstallDirectory '.env'
    $lines = if (Test-Path -LiteralPath $path) { [Collections.Generic.List[string]](Get-Content -LiteralPath $path) } else { [Collections.Generic.List[string]]::new() }
    $replaced = $false
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match ('^\s*' + [Regex]::Escape($Name) + '=')) {
            $lines[$index] = "$Name=$Value"
            $replaced = $true
        }
    }
    if (-not $replaced) { $lines.Add("$Name=$Value") }
    [IO.File]::WriteAllLines($path, $lines, [Text.UTF8Encoding]::new($false))
}

function Install-GitHubTokenFile {
    param([string]$SourcePath)
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw "GitHub-Token-Datei nicht gefunden: $SourcePath" }
    $token = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $SourcePath), [Text.Encoding]::UTF8).Trim()
    if ($token -notmatch '^[A-Za-z0-9_]{20,512}$') { throw 'Die GitHub-Token-Datei hat ein ungültiges Format.' }
    $secretDirectory = Join-Path $InstallDirectory 'secrets'
    $destination = Join-Path $secretDirectory 'github-update-token.txt'
    New-Item -ItemType Directory -Force -Path $secretDirectory | Out-Null
    [IO.File]::WriteAllText($destination, $token, [Text.UTF8Encoding]::new($false))

    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $secretDirectory /inheritance:r /grant:r "${currentUser}:(OI)(CI)(F)" '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Die Zugriffsrechte des Secret-Verzeichnisses konnten nicht gesetzt werden.' }
    & icacls.exe $destination /inheritance:r /grant:r "${currentUser}:(F)" '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Die Zugriffsrechte der GitHub-Token-Datei konnten nicht gesetzt werden.' }
}

$docker = Get-Command docker.exe -ErrorAction SilentlyContinue
if (-not $docker) {
    $knownPath = Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\resources\bin\docker.exe'
    if (Test-Path -LiteralPath $knownPath) { $docker = Get-Item -LiteralPath $knownPath }
}
if (-not $docker) { throw 'Docker CLI wurde nicht gefunden. Docker Desktop starten und erneut ausführen.' }

if (-not $Archive) {
    $candidate = Get-ChildItem -LiteralPath $InstallDirectory -Filter 'FabricNavigator-Image-*.tar.gz' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $candidate) { $candidate = Get-Item -LiteralPath (Join-Path $InstallDirectory 'FabricNavigator-Docker-20260821.tar.gz') -ErrorAction SilentlyContinue }
    if ($candidate) { $Archive = $candidate.FullName }
}
if (-not $Archive -or -not (Test-Path -LiteralPath $Archive)) { throw "Image-Archiv nicht gefunden: $Archive" }
if ($GitHubRepository) {
    if ($GitHubRepository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'GitHubRepository muss im Format BENUTZER/REPOSITORY angegeben werden.' }
    Set-EnvironmentSetting -Name 'FABRICNAVIGATOR_GITHUB_REPOSITORY' -Value $GitHubRepository
}
Set-EnvironmentSetting -Name 'FABRICNAVIGATOR_GITHUB_TOKEN_FILE' -Value 'secrets/github-update-token.txt'
if ($GitHubTokenFile) { Install-GitHubTokenFile -SourcePath $GitHubTokenFile }
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDirectory 'secrets') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDirectory 'update-state') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDirectory 'plugins\extreme-device-images') | Out-Null

& $docker.Source load --input $Archive
if ($LASTEXITCODE -ne 0) { throw 'docker load ist fehlgeschlagen.' }
& $docker.Source compose -f (Join-Path $InstallDirectory 'compose.yaml') up -d
if ($LASTEXITCODE -ne 0) { throw 'docker compose up ist fehlgeschlagen.' }

if (-not $SkipUpdater) {
    $updater = Join-Path $InstallDirectory 'FabricNavigator-Updater.ps1'
    if (-not (Test-Path -LiteralPath $updater)) { throw 'FabricNavigator-Updater.ps1 fehlt.' }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $updater + '" -Watch -InstallDirectory "' + $InstallDirectory + '"'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments -WorkingDirectory $InstallDirectory
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName 'FabricNavigator Updater' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Verifiziert und installiert vom Administrator freigegebene FabricNavigator GitHub-Releases.' -Force | Out-Null
    Start-ScheduledTask -TaskName 'FabricNavigator Updater'
}

& $docker.Source compose -f (Join-Path $InstallDirectory 'compose.yaml') ps
Write-Host ''
Write-Host 'FabricNavigator: https://localhost:8443/' -ForegroundColor Cyan
Write-Host 'Automatische Updates: Admin -> Updates' -ForegroundColor Cyan
if (-not $GitHubRepository) { Write-Warning 'Noch kein GitHub-Repository konfiguriert. Starte den Installer später mit -GitHubRepository BENUTZER/REPOSITORY erneut.' }
if (-not (Test-Path -LiteralPath (Join-Path $InstallDirectory 'secrets\github-update-token.txt') -PathType Leaf)) {
    Write-Host 'Kein GitHub-Token konfiguriert. Öffentliche Updates funktionieren ohne Token; für private Forks kann später ein Token hinterlegt werden.'
}
Write-Host 'Beim ersten Start muss wegen des lokalen selbstsignierten Zertifikats eine Browserwarnung bestätigt werden.'
