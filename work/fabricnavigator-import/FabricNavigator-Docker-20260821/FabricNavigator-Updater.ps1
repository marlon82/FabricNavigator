[CmdletBinding()]
param(
    [switch]$Watch,
    [switch]$Once,
    [string]$InstallDirectory = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$StateDirectory = Join-Path $InstallDirectory 'update-state'
$RequestFile = Join-Path $StateDirectory 'install.request'
$StatusFile = Join-Path $StateDirectory 'host-status.properties'
$OfflineDirectory = Join-Path $StateDirectory 'offline'
$OfflineStatusFile = Join-Path $StateDirectory 'offline-update.properties'
$PluginRequestFile = Join-Path $StateDirectory 'plugin-install.request'
$PluginStatusFile = Join-Path $StateDirectory 'plugin-status.properties'
$PluginDestination = Join-Path $InstallDirectory 'plugins\extreme-device-images'
$HostRouteRequestFile = Join-Path $StateDirectory 'host-routes.conf'
$HostRouteManagedFile = Join-Path $StateDirectory 'host-routes-managed.conf'
$HostRouteStatusFile = Join-Path $StateDirectory 'host-route-status.txt'
$HostRouteActiveFile = Join-Path $StateDirectory 'host-routes-active.txt'
$HostRouteGatewayFile = Join-Path $StateDirectory 'host-route-gateway.txt'
$GitHubTokenRequestFile = Join-Path $StateDirectory 'github-token.request'
$GitHubTokenStatusFile = Join-Path $StateDirectory 'github-token-status.properties'
$GitHubTokenDestination = Join-Path $InstallDirectory 'secrets\github-update-token.txt'
$SystemActionRequestFile = Join-Path $StateDirectory 'system-action.request'
$SystemActionStatusFile = Join-Path $StateDirectory 'system-action-status.properties'
$HostNetworkRequestFile = Join-Path $StateDirectory 'host-network.request'
$HostNetworkStatusFile = Join-Path $StateDirectory 'host-network-status.properties'
$script:LastHostRouteSignature = ''
$script:LastHostNetworkSnapshot = [DateTime]::MinValue

function Write-UpdateStatus {
    param([string]$State, [string]$Version = '', [string]$Message = '')
    New-Item -ItemType Directory -Force -Path $StateDirectory | Out-Null
    $clean = { param($Value) ([string]$Value).Replace('\', '\\').Replace("`r", '').Replace("`n", '\n') }
    $content = "state=$(& $clean $State)`nversion=$(& $clean $Version)`nupdatedAt=$([DateTime]::UtcNow.ToString('o'))`nmessage=$(& $clean $Message)`ncapabilities=offline-core,device-images`n"
    $temporary = "$StatusFile.tmp"
    [IO.File]::WriteAllText($temporary, $content, [Text.UTF8Encoding]::new($false))
    Move-Item -Force -LiteralPath $temporary -Destination $StatusFile
}

function Read-EnvironmentFile {
    $result = @{}
    $path = Join-Path $InstallDirectory '.env'
    if (-not (Test-Path -LiteralPath $path)) { return $result }
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
        $name, $value = $line -split '=', 2
        $result[$name.Trim()] = $value.Trim().Trim('"').Trim("'")
    }
    return $result
}

function Get-GitHubToken {
    param([hashtable]$Settings)
    $relativePath = [string]$Settings.FABRICNAVIGATOR_GITHUB_TOKEN_FILE
    if (-not $relativePath) { $relativePath = 'secrets\github-update-token.txt' }
    if ([IO.Path]::IsPathRooted($relativePath)) { throw 'Der GitHub-Tokenpfad muss relativ zum Installationsverzeichnis sein.' }
    $installRoot = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\') + '\'
    $tokenPath = [IO.Path]::GetFullPath((Join-Path $InstallDirectory $relativePath))
    if (-not $tokenPath.StartsWith($installRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Der GitHub-Tokenpfad verlässt das Installationsverzeichnis.'
    }
    if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) { return '' }
    $token = [IO.File]::ReadAllText($tokenPath, [Text.Encoding]::UTF8).Trim()
    if ($token -notmatch '^[A-Za-z0-9_]{20,512}$') { throw 'Die GitHub-Token-Datei hat ein ungültiges Format.' }
    return $token
}

function Get-DockerExecutable {
    $command = Get-Command docker.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $desktop = Join-Path $env:LOCALAPPDATA 'Programs\Docker\Docker\resources\bin\docker.exe'
    if (-not (Test-Path -LiteralPath $desktop)) {
        $desktop = Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\resources\bin\docker.exe'
    }
    if (-not (Test-Path -LiteralPath $desktop)) { throw 'Docker Desktop wurde nicht gefunden.' }
    return $desktop
}

function ConvertFrom-JavaPropertyValue {
    param([string]$Value)
    if ($null -eq $Value -or $Value.IndexOf('\') -lt 0) { return $Value }
    $builder = [Text.StringBuilder]::new()
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        if ($character -ne '\' -or $index + 1 -ge $Value.Length) {
            [void]$builder.Append($character)
            continue
        }
        $index++
        $escaped = $Value[$index]
        if ($escaped -eq 'u' -and $index + 4 -lt $Value.Length) {
            $codepoint = $Value.Substring($index + 1, 4)
            if ($codepoint -match '^[0-9a-fA-F]{4}$') {
                [void]$builder.Append([char][Convert]::ToInt32($codepoint, 16))
                $index += 4
                continue
            }
        }
        switch ($escaped) {
            't' { [void]$builder.Append("`t") }
            'n' { [void]$builder.Append("`n") }
            'r' { [void]$builder.Append("`r") }
            'f' { [void]$builder.Append([char]12) }
            default { [void]$builder.Append($escaped) }
        }
    }
    return $builder.ToString()
}

function Resolve-FabricNavigatorBaseImage {
    param([string]$Docker)
    $reference = [string](& $Docker inspect fabricnavigator --format '{{.Config.Image}}' 2>$null | Select-Object -First 1)
    $reference = $reference.Trim()
    if (-not $reference) { throw 'Das aktuell ausgeführte FabricNavigator-Image konnte nicht ermittelt werden.' }
    & $Docker image inspect $reference *> $null
    if ($LASTEXITCODE -eq 0) { return [pscustomobject]@{ Reference = $reference; TemporaryTag = '' } }
    $imageId = [string](& $Docker inspect fabricnavigator --format '{{.Image}}' 2>$null | Select-Object -First 1)
    $imageId = $imageId.Trim()
    if (-not $imageId) { throw 'Die Image-ID des laufenden FabricNavigator-Containers konnte nicht ermittelt werden.' }
    $temporaryTag = 'fabricnavigator:update-base-' + [Guid]::NewGuid().ToString('N')
    & $Docker tag $imageId $temporaryTag
    if ($LASTEXITCODE -ne 0) { throw 'Das laufende FabricNavigator-Image konnte nicht als Update-Basis markiert werden.' }
    return [pscustomobject]@{ Reference = $temporaryTag; TemporaryTag = $temporaryTag }
}

function Write-SystemActionStatus {
    param([string]$State, [string]$Message = '')
    $clean = ([string]$Message).Replace("`r", ' ').Replace("`n", ' ').Trim()
    Write-AtomicText -Path $SystemActionStatusFile -Content "state=$State`nupdatedAt=$([DateTime]::UtcNow.ToString('o'))`nmessage=$clean`n"
}

function Invoke-SystemActionRequest {
    if (-not (Test-Path -LiteralPath $SystemActionRequestFile -PathType Leaf)) { return }
    $processing = "$SystemActionRequestFile.processing"
    Move-Item -Force -LiteralPath $SystemActionRequestFile -Destination $processing
    try {
        $request = Read-SimpleProperties -Path $processing
        if ([string]$request.action -ne 'restart') { throw 'Nicht unterstützte Systemaktion.' }
        & shutdown.exe /r /t 10 /c "FabricNavigator administrator requested a host restart." /d p:4:1
        if ($LASTEXITCODE -ne 0) { throw 'Der Neustart des Windows-Hosts konnte nicht geplant werden.' }
        Write-SystemActionStatus -State 'scheduled' -Message 'Der FabricNavigator-Host wird in ungefähr 10 Sekunden neu gestartet.'
    } catch {
        Write-SystemActionStatus -State 'error' -Message $_.Exception.Message
        Write-Warning $_.Exception.Message
    } finally {
        Remove-Item -Force -LiteralPath $processing -ErrorAction SilentlyContinue
    }
}

function Write-HostNetworkStatus {
    param([string]$State,[string]$InterfaceAlias='',[string]$Mode='',[string]$Address='',[string]$Prefix='',[string]$Gateway='',[string]$Dns='',[string]$Message='')
    $clean={param($v)([string]$v).Replace("`r",' ').Replace("`n",' ').Trim()}
    Write-AtomicText -Path $HostNetworkStatusFile -Content "state=$(& $clean $State)`nupdatedAt=$([DateTime]::UtcNow.ToString('o'))`ninterface=$(& $clean $InterfaceAlias)`nmode=$(& $clean $Mode)`naddress=$(& $clean $Address)`nprefix=$(& $clean $Prefix)`ngateway=$(& $clean $Gateway)`ndns=$(& $clean $Dns)`nmessage=$(& $clean $Message)`n"
}

function Update-HostNetworkSnapshot {
    param([switch]$Force)
    try {
        if (-not $Force -and (Test-Path -LiteralPath $HostNetworkStatusFile -PathType Leaf)) {
            $existing = Read-SimpleProperties -Path $HostNetworkStatusFile
            if ([string]$existing.state -eq 'error') { return }
        }
        $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Where-Object { $_.NextHop -ne '0.0.0.0' } | Sort-Object RouteMetric | Select-Object -First 1
        if (-not $route) { throw 'Keine aktive IPv4-Standardroute gefunden.' }
        $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop
        $ipInterface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop
        $address = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1
        $dns = @(Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            ForEach-Object { $_.ServerAddresses } | Where-Object { $_ })
        $mode = if ([string]$ipInterface.Dhcp -eq 'Enabled') { 'dhcp' } else { 'static' }
        Write-HostNetworkStatus 'active' $adapter.Name $mode ([string]$address.IPAddress) ([string]$address.PrefixLength) ([string]$route.NextHop) ($dns -join ',') 'Aktuelle Host-Netzwerkkonfiguration.'
        $script:LastHostNetworkSnapshot = Get-Date
    } catch {
        if (-not (Test-Path -LiteralPath $HostNetworkStatusFile -PathType Leaf)) {
            Write-HostNetworkStatus 'error' -Message $_.Exception.Message
        }
    }
}

function Test-IPv4SameSubnet {
    param([Net.IPAddress]$Address,[Net.IPAddress]$Gateway,[int]$PrefixLength)
    $addressBytes=$Address.GetAddressBytes();$gatewayBytes=$Gateway.GetAddressBytes();$remaining=$PrefixLength
    for($index=0;$index-lt 4;$index++){
        $bits=[Math]::Min(8,[Math]::Max(0,$remaining));$mask=if($bits-eq 0){0}else{(0xff-shl(8-$bits))-band 0xff}
        if(($addressBytes[$index]-band$mask)-ne($gatewayBytes[$index]-band$mask)){return $false}
        $remaining-=8
    }
    return $true
}

function Invoke-HostNetworkRequest {
    if(-not(Test-Path -LiteralPath $HostNetworkRequestFile -PathType Leaf)){return}
    $pending=Read-SimpleProperties -Path $HostNetworkRequestFile;$notBefore=0L;[long]::TryParse([string]$pending.notBefore,[ref]$notBefore)|Out-Null;if($notBefore-gt[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()){return}
    $processing="$HostNetworkRequestFile.processing";Move-Item -Force -LiteralPath $HostNetworkRequestFile -Destination $processing
    $request=@{}
    try{
        $request=Read-SimpleProperties -Path $processing;$mode=([string]$request.mode).ToLowerInvariant()
        if($mode -notin @('dhcp','static')){throw 'Der Netzwerkmodus muss DHCP oder statisch sein.'}
        $alias=[string]$request.interface
        if(-not$alias){$alias=[string](Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop|Where-Object{$_.NextHop-ne'0.0.0.0'}|Sort-Object RouteMetric|Select-Object -First 1 -ExpandProperty InterfaceAlias)}
        $adapter=Get-NetAdapter -Name $alias -ErrorAction Stop
        if($adapter.Status-ne'Up'){throw 'Die ausgewählte Netzwerkschnittstelle ist nicht aktiv.'}
        $dns=@();foreach($item in ([string]$request.dns -split ',')){if(-not$item.Trim()){continue};$server=$null;if(-not[Net.IPAddress]::TryParse($item.Trim(),[ref]$server)-or$server.AddressFamily-ne[Net.Sockets.AddressFamily]::InterNetwork){throw 'Ungültiger IPv4-DNS-Server.'};$dns+=$item.Trim()};if($dns.Count-gt3){throw 'Maximal drei DNS-Server werden unterstützt.'}
        if($mode-eq'dhcp'){
            Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop
            if($dns.Count){Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $dns -ErrorAction Stop}else{Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction Stop}
            Update-HostNetworkSnapshot -Force
        }else{
            $parsed=$null;if(-not[Net.IPAddress]::TryParse([string]$request.address,[ref]$parsed)-or$parsed.AddressFamily-ne[Net.Sockets.AddressFamily]::InterNetwork){throw 'Ungültige statische IPv4-Adresse.'}
            $gateway=$null;if(-not[Net.IPAddress]::TryParse([string]$request.gateway,[ref]$gateway)-or$gateway.AddressFamily-ne[Net.Sockets.AddressFamily]::InterNetwork){throw 'Ungültiges IPv4-Gateway.'}
            $prefix=0;if(-not[int]::TryParse([string]$request.prefix,[ref]$prefix)-or$prefix-lt 1-or$prefix-gt 32){throw 'Ungültige IPv4-Präfixlänge.'}
            if(-not(Test-IPv4SameSubnet -Address $parsed -Gateway $gateway -PrefixLength $prefix)){throw 'Das IPv4-Gateway muss im konfigurierten Subnetz liegen.'}
            Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
            Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue|Where-Object{$_.PrefixOrigin-ne'WellKnown'}|Remove-NetIPAddress -Confirm:$false -ErrorAction Stop
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress ([string]$request.address) -PrefixLength $prefix -DefaultGateway ([string]$request.gateway) -AddressFamily IPv4 -ErrorAction Stop|Out-Null
            if($dns.Count){Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $dns -ErrorAction Stop}else{Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction Stop}
            Update-HostNetworkSnapshot -Force
        }
    }catch{Write-HostNetworkStatus 'error' ([string]$request.interface) ([string]$request.mode) -Message $_.Exception.Message;Write-Warning $_.Exception.Message}finally{Remove-Item -Force -LiteralPath $processing -ErrorAction SilentlyContinue}
}

function Read-Request {
    if (-not (Test-Path -LiteralPath $RequestFile)) { return $null }
    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($RequestFile)) {
        if ($line -match '^\s*[#!]' -or $line -notmatch '=') { continue }
        $key, $value = $line -split '=', 2
        $values[(ConvertFrom-JavaPropertyValue -Value $key.Trim())] = ConvertFrom-JavaPropertyValue -Value $value.Trim()
    }
    return $values
}

function Write-AtomicText {
    param([string]$Path, [string]$Content)
    $temporary = "$Path.tmp"
    [IO.File]::WriteAllText($temporary, $Content, [Text.UTF8Encoding]::new($false))
    Move-Item -Force -LiteralPath $temporary -Destination $Path
}

function Write-HostRouteStatus {
    param([string]$Destination, [string]$Gateway, [string]$State, [string]$Message = '')
    $clean = ([string]$Message).Replace('|', '/').Replace("`r", ' ').Replace("`n", ' ').Trim()
    Write-AtomicText -Path $HostRouteStatusFile -Content "$Destination|$Gateway|$State|$clean`n"
}

function Write-GitHubTokenStatus {
    param([string]$State, [bool]$Configured, [string]$Message = '')
    $clean = ([string]$Message).Replace("`r", ' ').Replace("`n", ' ').Trim()
    $content = "state=$State`nconfigured=$($Configured.ToString().ToLowerInvariant())`nupdatedAt=$([DateTime]::UtcNow.ToString('o'))`nmessage=$clean`n"
    Write-AtomicText -Path $GitHubTokenStatusFile -Content $content
}

function Read-SimpleProperties {
    param([string]$Path)
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*[#!]' -or $line -notmatch '=') { continue }
        $key, $value = $line -split '=', 2
        $result[(ConvertFrom-JavaPropertyValue -Value $key.Trim())] = ConvertFrom-JavaPropertyValue -Value $value.Trim()
    }
    return $result
}

function Set-GitHubTokenAcl {
    $secretDirectory = Split-Path $GitHubTokenDestination -Parent
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $secretDirectory /inheritance:r /grant:r "${currentUser}:(OI)(CI)(F)" '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Die Zugriffsrechte des Secret-Verzeichnisses konnten nicht gesetzt werden.' }
    & icacls.exe $GitHubTokenDestination /inheritance:r /grant:r "${currentUser}:(F)" '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Die Zugriffsrechte der GitHub-Token-Datei konnten nicht gesetzt werden.' }
}

function Invoke-GitHubTokenRequest {
    if (-not (Test-Path -LiteralPath $GitHubTokenRequestFile -PathType Leaf)) { return }
    $processing = "$GitHubTokenRequestFile.processing"
    Move-Item -Force -LiteralPath $GitHubTokenRequestFile -Destination $processing
    try {
        $request = Read-SimpleProperties -Path $processing
        if ($request.action -eq 'install') {
            $token = [string]$request.token
            if ($token -notmatch '^[A-Za-z0-9_]{20,512}$') { throw 'Das GitHub-Token hat ein ungültiges Format.' }
            $secretDirectory = Split-Path $GitHubTokenDestination -Parent
            New-Item -ItemType Directory -Force -Path $secretDirectory | Out-Null
            $temporary = "$GitHubTokenDestination.tmp"
            [IO.File]::WriteAllText($temporary, $token, [Text.UTF8Encoding]::new($false))
            Move-Item -Force -LiteralPath $temporary -Destination $GitHubTokenDestination
            Set-GitHubTokenAcl
            Write-GitHubTokenStatus -State 'configured' -Configured $true -Message 'GitHub-Token wurde sicher auf dem Docker-Host gespeichert.'
        } elseif ($request.action -eq 'remove') {
            Remove-Item -Force -LiteralPath $GitHubTokenDestination -ErrorAction SilentlyContinue
            Write-GitHubTokenStatus -State 'removed' -Configured $false -Message 'GitHub-Token wurde vom Docker-Host entfernt.'
        } else {
            throw 'Unbekannte GitHub-Token-Aktion.'
        }
    } catch {
        Write-GitHubTokenStatus -State 'error' -Configured (Test-Path -LiteralPath $GitHubTokenDestination -PathType Leaf) -Message $_.Exception.Message
    } finally {
        if (Test-Path -LiteralPath $processing) { Remove-Item -Force -LiteralPath $processing }
        $token = $null
    }
}

function Convert-IPv4Number {
    param([string]$Address)
    $bytes = [Net.IPAddress]::Parse($Address).GetAddressBytes()
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    return [uint64][BitConverter]::ToUInt32($bytes, 0)
}

function Test-IPv4InPrefix {
    param([string]$Address, [string]$Prefix)
    $network, $lengthText = $Prefix -split '/', 2
    $length = [int]$lengthText
    $mask = if ($length -eq 0) { [uint64]0 } else { [uint64]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $length)) }
    return ((Convert-IPv4Number $Address) -band $mask) -eq ((Convert-IPv4Number $network) -band $mask)
}

function Read-DesiredHostRoutes {
    $result = [ordered]@{}
    if (-not (Test-Path -LiteralPath $HostRouteRequestFile -PathType Leaf)) { return $result }
    foreach ($line in [IO.File]::ReadAllLines($HostRouteRequestFile)) {
        $parts = $line.Trim() -split '\|', 2
        if ($parts.Count -ne 2) { continue }
        $destination = if ($parts[0] -eq 'default') { 'default' } else { $parts[0] }
        $gateway = $parts[1]
        if ($destination -notmatch '^(default|(?:\d{1,3}\.){3}\d{1,3}/(?:[0-9]|[12][0-9]|3[0-2]))$' -or
            $gateway -notmatch '^(?:\d{1,3}\.){3}\d{1,3}$') { continue }
        $result[$destination] = $gateway
    }
    return $result
}

function Read-ManagedHostRoutes {
    $result = @{}
    if (-not (Test-Path -LiteralPath $HostRouteManagedFile -PathType Leaf)) { return $result }
    foreach ($line in [IO.File]::ReadAllLines($HostRouteManagedFile)) {
        $parts = $line.Trim() -split '\|', 3
        if ($parts.Count -eq 3) { $result[$parts[0]] = @{ Gateway = $parts[1]; Owned = ($parts[2] -eq '1') } }
    }
    return $result
}

function Save-ManagedHostRoutes {
    param([hashtable]$Routes)
    $lines = foreach ($destination in ($Routes.Keys | Sort-Object)) {
        $entry = $Routes[$destination]
        "$destination|$($entry.Gateway)|$(if ($entry.Owned) { '1' } else { '0' })"
    }
    Write-AtomicText -Path $HostRouteManagedFile -Content (($lines -join "`n") + $(if ($lines.Count) { "`n" } else { '' }))
}

function Convert-HostDestination {
    param([string]$Destination)
    if ($Destination -eq 'default') { return '0.0.0.0/0' }
    return $Destination
}

function Add-HostRoute {
    param([string]$Destination, [string]$Gateway)
    $prefix = Convert-HostDestination $Destination
    $exact = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix $prefix -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $Gateway })
    if ($exact.Count -gt 0) { return $false }
    $conflicting = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix $prefix -ErrorAction SilentlyContinue)
    if ($conflicting.Count -gt 0) { throw "Für $Destination existiert auf dem Docker-Host bereits eine andere Route." }
    $connected = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
        $_.NextHop -eq '0.0.0.0' -and (Test-IPv4InPrefix -Address $Gateway -Prefix $_.DestinationPrefix)
    } | Sort-Object { [int]($_.DestinationPrefix -split '/')[1] } -Descending)
    if ($connected.Count -eq 0) { throw "Gateway $Gateway ist auf keinem direkt verbundenen Netzwerk des Docker-Hosts erreichbar." }
    New-NetRoute -AddressFamily IPv4 -DestinationPrefix $prefix -InterfaceIndex $connected[0].InterfaceIndex -NextHop $Gateway -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
    return $true
}

function Remove-HostRoute {
    param([string]$Destination, [string]$Gateway)
    $prefix = Convert-HostDestination $Destination
    Get-NetRoute -AddressFamily IPv4 -DestinationPrefix $prefix -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -eq $Gateway } |
        Remove-NetRoute -Confirm:$false -ErrorAction Stop
}

function Write-HostRouteSnapshot {
    $routes = Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop |
        Sort-Object DestinationPrefix, RouteMetric |
        Select-Object DestinationPrefix, NextHop, InterfaceAlias, RouteMetric
    Write-AtomicText -Path $HostRouteActiveFile -Content (($routes | Format-Table -AutoSize | Out-String).Trim() + "`n")
    $gateway = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne '0.0.0.0' } | Sort-Object RouteMetric | Select-Object -First 1 -ExpandProperty NextHop
    Write-AtomicText -Path $HostRouteGatewayFile -Content (([string]$gateway).Trim() + "`n")
}

function Invoke-HostRouteReconciliation {
    if (-not (Test-Path -LiteralPath $HostRouteRequestFile -PathType Leaf)) { return }
    $item = Get-Item -LiteralPath $HostRouteRequestFile
    $signature = "$($item.LastWriteTimeUtc.Ticks):$($item.Length)"
    if ($signature -eq $script:LastHostRouteSignature) { return }
    $desired = Read-DesiredHostRoutes
    $managed = Read-ManagedHostRoutes
    foreach ($destination in @($managed.Keys)) {
        $entry = $managed[$destination]
        if (-not $desired.Contains($destination) -or $desired[$destination] -ne $entry.Gateway) {
            try {
                if ($entry.Owned) { Remove-HostRoute -Destination $destination -Gateway $entry.Gateway }
                $managed.Remove($destination)
                Write-HostRouteStatus -Destination $destination -Gateway $entry.Gateway -State 'deleted'
            } catch {
                Write-HostRouteStatus -Destination $destination -Gateway $entry.Gateway -State 'error' -Message $_.Exception.Message
                Save-ManagedHostRoutes -Routes $managed
                Write-HostRouteSnapshot
                $script:LastHostRouteSignature = $signature
                return
            }
        }
    }
    foreach ($destination in $desired.Keys) {
        $gateway = $desired[$destination]
        if ($managed.ContainsKey($destination) -and $managed[$destination].Gateway -eq $gateway) {
            try {
                $added = Add-HostRoute -Destination $destination -Gateway $gateway
                if ($added) { $managed[$destination].Owned = $true }
            } catch {
                Write-HostRouteStatus -Destination $destination -Gateway $gateway -State 'error' -Message $_.Exception.Message
                Save-ManagedHostRoutes -Routes $managed
                Write-HostRouteSnapshot
                $script:LastHostRouteSignature = $signature
                return
            }
            Write-HostRouteStatus -Destination $destination -Gateway $gateway -State 'ok'
            continue
        }
        try {
            $owned = Add-HostRoute -Destination $destination -Gateway $gateway
            $managed[$destination] = @{ Gateway = $gateway; Owned = $owned }
            Write-HostRouteStatus -Destination $destination -Gateway $gateway -State 'ok'
        } catch {
            Write-HostRouteStatus -Destination $destination -Gateway $gateway -State 'error' -Message $_.Exception.Message
            Save-ManagedHostRoutes -Routes $managed
            Write-HostRouteSnapshot
            $script:LastHostRouteSignature = $signature
            return
        }
    }
    Save-ManagedHostRoutes -Routes $managed
    Write-HostRouteSnapshot
    $script:LastHostRouteSignature = $signature
}

function Test-SafeArchive {
    param([string]$Archive)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            if ([IO.Path]::IsPathRooted($name) -or $name -match '(^|\\)\.\.(\\|$)') {
                throw "Unsicherer Pfad im Updatearchiv: $name"
            }
        }
    } finally { $zip.Dispose() }
}

function Wait-FabricNavigatorHealth {
    param([string]$HealthUrl)
    for ($attempt = 0; $attempt -lt 45; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 4 -SkipCertificateCheck
            if ($response.StatusCode -eq 200) { return }
        } catch {
            # Windows PowerShell 5.1 has no SkipCertificateCheck.  Use curl only
            # for the loopback health endpoint when the parameter is unknown.
            try {
                & curl.exe -k -f -s --max-time 4 $HealthUrl | Out-Null
                if ($LASTEXITCODE -eq 0) { return }
            } catch {}
        }
        Start-Sleep -Seconds 2
    }
    throw 'Der Healthcheck der aktualisierten Anwendung ist fehlgeschlagen.'
}

function Install-FabricNavigatorOnlineRelease {
    param([hashtable]$Request)
    $version = [string]$Request.version
    if ($version -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw 'Ungültige angeforderte Version.' }
    $channel = if ([string]$Request.channel -eq 'beta') { 'beta' } else { 'stable' }
    $settings = Read-EnvironmentFile
    $repository = [string]$settings.FABRICNAVIGATOR_GITHUB_REPOSITORY
    if ($repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'FABRICNAVIGATOR_GITHUB_REPOSITORY ist nicht konfiguriert.' }
    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = "FabricNavigator-Updater/$version"
        'X-GitHub-Api-Version' = '2026-03-10'
    }
    $token = Get-GitHubToken -Settings $settings
    if ($token) { $headers.Authorization = "Bearer $token" }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/releases/tags/v$version" -Headers $headers
    $releaseVersion = ([string]$release.tag_name).TrimStart('v')
    if ($releaseVersion -ne $version) { throw "GitHub liefert Version $releaseVersion statt der angeforderten Version $version." }
    if ($release.draft) { throw 'Das angeforderte GitHub-Release ist noch ein Entwurf.' }
    if ($release.prerelease -and $channel -ne 'beta') { throw 'Ein Vorabrelease kann nicht über den stabilen Updatekanal installiert werden.' }
    $expectedNames = @("FabricNavigator-Update-$version.zip", "fabricnavigator-update-$version.zip")
    $asset = $release.assets | Where-Object { $expectedNames -contains $_.name } | Select-Object -First 1
    if (-not $asset) { throw 'Das Release enthält kein FabricNavigator-Updatearchiv.' }
    if ([string]$asset.id -notmatch '^\d+$') { throw 'GitHub liefert keine gültige Asset-ID für das Update.' }
    $digest = [string]$asset.digest
    if ($digest -notmatch '^sha256:([0-9a-fA-F]{64})$') { throw 'GitHub liefert keinen gültigen SHA-256-Digest für das Update.' }
    $expectedHash = $Matches[1].ToLowerInvariant()
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("FabricNavigator-Update-" + [Guid]::NewGuid().ToString('N'))
    $archive = Join-Path $temporaryRoot $asset.name
    $stage = Join-Path $temporaryRoot 'stage'
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
        Write-UpdateStatus -State 'downloading' -Version $version -Message 'Update wird von GitHub geladen.'
        $downloadHeaders = $headers.Clone()
        $downloadHeaders.Accept = 'application/octet-stream'
        $assetApiUrl = "https://api.github.com/repos/$repository/releases/assets/$($asset.id)"
        Invoke-WebRequest -Uri $assetApiUrl -Headers $downloadHeaders -OutFile $archive -UseBasicParsing
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) { throw 'Die SHA-256-Prüfung des Updatearchivs ist fehlgeschlagen.' }
        Test-SafeArchive -Archive $archive
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, $stage)
        $runtime = Join-Path $stage 'runtime'
        $image = Join-Path $runtime "FabricNavigator-Image-$version.tar.gz"
        $coreOverlay = Join-Path $runtime 'core-overlay'
        $newCompose = Join-Path $runtime 'compose.yaml'
        $hasFullImage = Test-Path -LiteralPath $image -PathType Leaf
        $hasCoreOverlay = (Test-Path -LiteralPath (Join-Path $coreOverlay 'Dockerfile') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $coreOverlay 'manifest.properties') -PathType Leaf)
        if ((-not $hasFullImage -and -not $hasCoreOverlay) -or -not (Test-Path -LiteralPath $newCompose)) {
            throw 'Das Updatearchiv enthält nicht die erwartete Runtime-Struktur.'
        }
        $backup = Join-Path $InstallDirectory ('.update-backup\' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Force -Path $backup | Out-Null
        Get-ChildItem -LiteralPath $runtime -File | Where-Object { $_.Name -ne (Split-Path $image -Leaf) } | ForEach-Object {
            $destination = Join-Path $InstallDirectory $_.Name
            if (Test-Path -LiteralPath $destination) { Copy-Item -LiteralPath $destination -Destination (Join-Path $backup $_.Name) }
        }
        $docker = Get-DockerExecutable
        Write-UpdateStatus -State 'installing' -Version $version -Message 'Image und Laufzeitdateien werden installiert.'
        if ($hasFullImage) {
            & $docker load --input $image
            if ($LASTEXITCODE -ne 0) { throw 'docker load ist fehlgeschlagen.' }
        } else {
            $manifest = Get-Content -LiteralPath (Join-Path $coreOverlay 'manifest.properties') -Raw | ConvertFrom-StringData
            if ($manifest.format -ne 'core-overlay-v1' -or $manifest.targetVersion -ne $version) { throw 'Das Core-Update-Manifest ist ungültig.' }
            $baseImage = Resolve-FabricNavigatorBaseImage -Docker $docker
            try {
                Write-UpdateStatus -State 'installing' -Version $version -Message 'Das kleine Core-Update wird lokal auf das vorhandene Image angewendet.'
                & $docker build --build-arg "BASE_IMAGE=$($baseImage.Reference)" --tag "fabricnavigator:$version" $coreOverlay
                if ($LASTEXITCODE -ne 0) { throw 'docker build für das Core-Update ist fehlgeschlagen.' }
            } finally {
                if ($baseImage.TemporaryTag) { & $docker image rm $baseImage.TemporaryTag *> $null }
            }
        }
        Get-ChildItem -LiteralPath $runtime -File | Where-Object { $_.Name -ne (Split-Path $image -Leaf) } | ForEach-Object {
            Copy-Item -Force -LiteralPath $_.FullName -Destination (Join-Path $InstallDirectory $_.Name)
        }
        & $docker compose -f (Join-Path $InstallDirectory 'compose.yaml') up -d --remove-orphans
        if ($LASTEXITCODE -ne 0) { throw 'docker compose up ist fehlgeschlagen.' }
        $healthUrl = if ($settings.FABRICNAVIGATOR_HEALTH_URL) { $settings.FABRICNAVIGATOR_HEALTH_URL } else { 'https://localhost:8443/health.jsp' }
        Wait-FabricNavigatorHealth -HealthUrl $healthUrl
        Write-UpdateStatus -State 'success' -Version $version -Message 'Update wurde erfolgreich installiert.'
    } catch {
        Write-UpdateStatus -State 'rollback' -Version $version -Message $_.Exception.Message
        if ($backup -and (Test-Path -LiteralPath $backup)) {
            Get-ChildItem -LiteralPath $backup -File | ForEach-Object { Copy-Item -Force -LiteralPath $_.FullName -Destination (Join-Path $InstallDirectory $_.Name) }
            try {
                $docker = Get-DockerExecutable
                & $docker compose -f (Join-Path $InstallDirectory 'compose.yaml') up -d --remove-orphans
            } catch {}
        }
        Write-UpdateStatus -State 'error' -Version $version -Message ("Update fehlgeschlagen; vorherige Konfiguration wurde wiederhergestellt. " + $_.Exception.Message)
        throw
    } finally {
        if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -Recurse -Force -LiteralPath $temporaryRoot }
    }
}

function Install-FabricNavigatorOfflineRelease {
    param([hashtable]$Request)
    $version=[string]$Request.version;$name=[string]$Request.file;$digest=[string]$Request.assetDigest
    if($version -notmatch '^\d+\.\d+\.\d+\.\d+$' -or $name -ne "FabricNavigator-Update-$version.zip" -or $digest -notmatch '^sha256:([0-9a-fA-F]{64})$'){throw 'Ungültige Offline-Updateanforderung.'}
    $expectedHash=$Matches[1].ToLowerInvariant();$offlineRoot=[IO.Path]::GetFullPath($OfflineDirectory).TrimEnd('\')+'\';$source=[IO.Path]::GetFullPath((Join-Path $OfflineDirectory $name))
    if(-not $source.StartsWith($offlineRoot,[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath $source -PathType Leaf)){throw 'Das bereitgestellte Offline-Update wurde nicht gefunden.'}
    $temporaryRoot=Join-Path ([IO.Path]::GetTempPath()) ('FabricNavigator-Offline-'+[Guid]::NewGuid().ToString('N'));$archive=Join-Path $temporaryRoot $name;$stage=Join-Path $temporaryRoot 'stage';New-Item -ItemType Directory -Force -Path $stage|Out-Null
    try{
        Write-UpdateStatus -State 'validating' -Version $version -Message 'Das lokale Offline-Update wird geprüft.';Copy-Item -LiteralPath $source -Destination $archive
        if((Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant() -ne $expectedHash){throw 'Die SHA-256-Prüfung des Offline-Updates ist fehlgeschlagen.'}
        Test-SafeArchive -Archive $archive;[IO.Compression.ZipFile]::ExtractToDirectory($archive,$stage);$runtime=Join-Path $stage 'runtime';$image=Join-Path $runtime "FabricNavigator-Image-$version.tar.gz";$coreOverlay=Join-Path $runtime 'core-overlay';$newCompose=Join-Path $runtime 'compose.yaml'
        $hasFullImage=Test-Path -LiteralPath $image -PathType Leaf;$hasCoreOverlay=(Test-Path -LiteralPath (Join-Path $coreOverlay 'Dockerfile') -PathType Leaf)-and(Test-Path -LiteralPath (Join-Path $coreOverlay 'manifest.properties') -PathType Leaf)
        if((-not $hasFullImage -and -not $hasCoreOverlay)-or -not(Test-Path -LiteralPath $newCompose)){throw 'Das Offline-Update enthält nicht die erwartete Runtime-Struktur.'}
        $backup=Join-Path $InstallDirectory ('.update-backup\'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'));New-Item -ItemType Directory -Force -Path $backup|Out-Null
        Get-ChildItem -LiteralPath $runtime -File|Where-Object{$_.Name-ne(Split-Path $image -Leaf)}|ForEach-Object{$destination=Join-Path $InstallDirectory $_.Name;if(Test-Path -LiteralPath $destination){Copy-Item -LiteralPath $destination -Destination (Join-Path $backup $_.Name)}}
        $docker=Get-DockerExecutable
        if($hasFullImage){Write-UpdateStatus -State 'installing' -Version $version -Message 'Das vollständige Offline-Image wird installiert.';&$docker load --input $image;if($LASTEXITCODE-ne 0){throw 'docker load ist fehlgeschlagen.'}}
        else{$manifest=Get-Content -LiteralPath (Join-Path $coreOverlay 'manifest.properties') -Raw|ConvertFrom-StringData;if($manifest.format-ne'core-overlay-v1'-or $manifest.targetVersion-ne$version){throw 'Das Core-Update-Manifest ist ungültig.'};$baseImage=Resolve-FabricNavigatorBaseImage -Docker $docker;try{Write-UpdateStatus -State 'installing' -Version $version -Message 'Das Offline-Core-Update wird lokal angewendet.';&$docker build --build-arg "BASE_IMAGE=$($baseImage.Reference)" --tag "fabricnavigator:$version" $coreOverlay;if($LASTEXITCODE-ne 0){throw 'docker build für das Core-Update ist fehlgeschlagen.'}}finally{if($baseImage.TemporaryTag){&$docker image rm $baseImage.TemporaryTag *> $null}}}
        Get-ChildItem -LiteralPath $runtime -File|Where-Object{$_.Name-ne(Split-Path $image -Leaf)}|ForEach-Object{Copy-Item -Force -LiteralPath $_.FullName -Destination (Join-Path $InstallDirectory $_.Name)}
        &$docker compose -f (Join-Path $InstallDirectory 'compose.yaml') up -d --remove-orphans;if($LASTEXITCODE-ne 0){throw 'docker compose up ist fehlgeschlagen.'};$settings=Read-EnvironmentFile;$healthUrl=if($settings.FABRICNAVIGATOR_HEALTH_URL){$settings.FABRICNAVIGATOR_HEALTH_URL}else{'https://localhost:8443/health.jsp'};Wait-FabricNavigatorHealth -HealthUrl $healthUrl
        Remove-Item -Force -LiteralPath $source,$OfflineStatusFile -ErrorAction SilentlyContinue;Write-UpdateStatus -State 'success' -Version $version -Message 'Offline-Update wurde erfolgreich installiert.'
    }catch{Write-UpdateStatus -State 'rollback' -Version $version -Message $_.Exception.Message;if($backup-and(Test-Path -LiteralPath $backup)){Get-ChildItem -LiteralPath $backup -File|ForEach-Object{Copy-Item -Force -LiteralPath $_.FullName -Destination (Join-Path $InstallDirectory $_.Name)};try{$docker=Get-DockerExecutable;&$docker compose -f (Join-Path $InstallDirectory 'compose.yaml') up -d --remove-orphans}catch{}};Write-UpdateStatus -State 'error' -Version $version -Message ('Offline-Update fehlgeschlagen. '+$_.Exception.Message);throw}finally{if(Test-Path -LiteralPath $temporaryRoot){Remove-Item -Recurse -Force -LiteralPath $temporaryRoot}}
}

function Install-FabricNavigatorRelease { param([hashtable]$Request) if([string]$Request.source -eq 'offline'){Install-FabricNavigatorOfflineRelease -Request $Request}else{Install-FabricNavigatorOnlineRelease -Request $Request} }

function Write-PluginStatus { param([string]$State,[string]$Version='',[string]$Message='') $clean=([string]$Message).Replace("`r",' ').Replace("`n",' ');Write-AtomicText -Path $PluginStatusFile -Content "state=$State`nversion=$Version`nupdatedAt=$([DateTime]::UtcNow.ToString('o'))`nmessage=$clean`n" }
function Invoke-PendingPluginInstall {
    if(-not(Test-Path -LiteralPath $PluginRequestFile -PathType Leaf)){return};$processing="$PluginRequestFile.processing";Move-Item -Force -LiteralPath $PluginRequestFile -Destination $processing
    $request=@{};$work=$null;$backup=$null
    try{
        $request=Read-SimpleProperties -Path $processing;$version=[string]$request.version;$name=[string]$request.file;$digest=[string]$request.digest
        if($version-notmatch'^[A-Za-z0-9._-]{1,64}$'-or$name-ne"FabricNavigator-Extreme-Device-Images-$version.zip"-or$digest-notmatch'^sha256:([0-9a-fA-F]{64})$'){throw 'Ungültige Gerätebilder-Paketanforderung.'};$expected=$Matches[1].ToLowerInvariant();$root=[IO.Path]::GetFullPath($OfflineDirectory).TrimEnd('\')+'\';$source=[IO.Path]::GetFullPath((Join-Path $OfflineDirectory $name));if(-not$source.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)-or-not(Test-Path -LiteralPath $source -PathType Leaf)){throw 'Das Gerätebilder-Paket wurde nicht gefunden.'};if((Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.ToLowerInvariant()-ne$expected){throw 'SHA-256-Prüfung des Gerätebilder-Pakets fehlgeschlagen.'}
        $work=Join-Path ([IO.Path]::GetTempPath()) ('FabricNavigator-Images-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Force -Path $work|Out-Null;Write-PluginStatus 'installing' $version 'Gerätebilder werden installiert.';Test-SafeArchive -Archive $source;[IO.Compression.ZipFile]::ExtractToDirectory($source,$work);$staged=Join-Path $work 'plugin';$manifestFile=Join-Path $staged 'plugin.json';if(-not(Test-Path -LiteralPath $manifestFile -PathType Leaf)){throw 'Plugin-Manifest fehlt.'};$manifest=Get-Content -Raw -LiteralPath $manifestFile|ConvertFrom-Json;if($manifest.id-ne'extreme-device-images'-or[string]$manifest.version-ne$version){throw 'Plugin-Manifest ist ungültig.'};if(-not(Get-ChildItem -LiteralPath $staged -Filter '*.png' -File|Select-Object -First 1)){throw 'Das Paket enthält keine Gerätebilder.'}
        New-Item -ItemType Directory -Force -Path (Split-Path $PluginDestination -Parent)|Out-Null;if(Test-Path -LiteralPath $PluginDestination){$backup=Join-Path $InstallDirectory ('.plugin-backup\'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'));Copy-Item -Recurse -LiteralPath $PluginDestination -Destination $backup;Remove-Item -Recurse -Force -LiteralPath $PluginDestination};Copy-Item -Recurse -LiteralPath $staged -Destination $PluginDestination;Remove-Item -Force -LiteralPath $source;Write-PluginStatus 'installed' $version 'Gerätebilder wurden erfolgreich installiert.'
    }catch{if($backup-and(Test-Path -LiteralPath $backup)){Remove-Item -Recurse -Force -LiteralPath $PluginDestination -ErrorAction SilentlyContinue;Copy-Item -Recurse -LiteralPath $backup -Destination $PluginDestination};Write-PluginStatus 'error' ([string]$request.version) $_.Exception.Message;Write-Warning $_.Exception.Message}finally{if($work-and(Test-Path -LiteralPath $work)){Remove-Item -Recurse -Force -LiteralPath $work};Remove-Item -Force -LiteralPath $processing -ErrorAction SilentlyContinue}
}

function Invoke-PendingUpdate {
    $request = Read-Request
    if (-not $request) { return $false }
    $processing = "$RequestFile.processing"
    Move-Item -Force -LiteralPath $RequestFile -Destination $processing
    try {
        Install-FabricNavigatorRelease -Request $request
    } catch {
        Write-Warning $_.Exception.Message
    } finally {
        if (Test-Path -LiteralPath $processing) { Remove-Item -Force -LiteralPath $processing }
    }
    return $true
}

New-Item -ItemType Directory -Force -Path $StateDirectory | Out-Null
Write-GitHubTokenStatus -State $(if (Test-Path -LiteralPath $GitHubTokenDestination -PathType Leaf) { 'configured' } else { 'not-configured' }) -Configured (Test-Path -LiteralPath $GitHubTokenDestination -PathType Leaf)
Update-HostNetworkSnapshot
if ($Once) { Invoke-GitHubTokenRequest; Invoke-HostNetworkRequest; Invoke-SystemActionRequest; Invoke-HostRouteReconciliation; Invoke-PendingPluginInstall; Invoke-PendingUpdate | Out-Null; exit }
if (-not $Watch) { $Watch = $true }
Write-UpdateStatus -State 'waiting' -Message 'Windows-Updater wartet auf eine freigegebene Aktualisierung.'
while ($Watch) {
    Invoke-GitHubTokenRequest
    Invoke-HostNetworkRequest
    Invoke-SystemActionRequest
    Invoke-HostRouteReconciliation
    if (((Get-Date) - $script:LastHostNetworkSnapshot).TotalSeconds -ge 10) { Update-HostNetworkSnapshot }
    Invoke-PendingPluginInstall
    Invoke-PendingUpdate | Out-Null
    Start-Sleep -Seconds 1
}
