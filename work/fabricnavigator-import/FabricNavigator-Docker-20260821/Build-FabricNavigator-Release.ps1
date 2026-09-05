[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string]$Version,

    [string]$SourceImage = 'fabricnavigator:2026-08-21',
    [string]$OutputDirectory = '',

    [ValidateSet('Full', 'CoreOverlay')]
    [string]$UpdateMode = 'Full',

    [switch]$SkipInstaller,

    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string]$MinimumCoreOverlayBaseVersion = '26.08.10.116'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-PortableZipArchive {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$DestinationArchive
    )

    if (Test-Path -LiteralPath $DestinationArchive) {
        Remove-Item -Force -LiteralPath $DestinationArchive
    }
    $sourceRoot = (Resolve-Path -LiteralPath $SourceDirectory).Path.TrimEnd('\', '/')
    $archive = [IO.Compression.ZipFile]::Open($DestinationArchive, [IO.Compression.ZipArchiveMode]::Create)
    try {
        Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File | ForEach-Object {
            $entryName = $_.FullName.Substring($sourceRoot.Length).TrimStart('\', '/').Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive,
                $_.FullName,
                $entryName,
                [IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    } finally {
        $archive.Dispose()
    }
}

if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'dist' }
$releaseTag = "fabricnavigator:$Version"
$composeTemplate = Join-Path $PSScriptRoot 'compose.release.yaml'
$notes = Join-Path $PSScriptRoot 'RELEASE_NOTES.md'
$installer = Join-Path $PSScriptRoot 'Import-FabricNavigator.ps1'
$updater = Join-Path $PSScriptRoot 'FabricNavigator-Updater.ps1'
$linuxUpdater = Join-Path $PSScriptRoot '..\..\..\proxmox\guest\fabricnavigator-updater.py'
$linuxUpdaterService = Join-Path $PSScriptRoot '..\..\..\proxmox\guest\fabricnavigator-updater.service'
$linuxUpdaterMigration = Join-Path $PSScriptRoot '..\..\..\proxmox\guest\migrate-fabricnavigator-updater.sh'
$proxmoxCompose = Join-Path $PSScriptRoot '..\..\..\proxmox\guest\compose.proxmox.yaml'

foreach ($required in @($composeTemplate, $notes, $installer, $updater, $linuxUpdater, $linuxUpdaterService, $linuxUpdaterMigration, $proxmoxCompose)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Erforderliche Datei fehlt: $required" }
}

$releaseNotes = [IO.File]::ReadAllText($notes)
if ($releaseNotes -notmatch ('(?m)^# FabricNavigator ' + [Regex]::Escape($Version) + '\s*$')) {
    throw "RELEASE_NOTES.md enthält nicht die angeforderte Release-Version $Version."
}

$docker = Get-Command docker.exe -ErrorAction SilentlyContinue
if (-not $docker) {
    foreach ($candidate in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Docker\Docker\resources\bin\docker.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\resources\bin\docker.exe')
    )) {
        if (Test-Path -LiteralPath $candidate) { $docker = Get-Item -LiteralPath $candidate; break }
    }
}
if (-not $docker) { throw 'Docker CLI wurde nicht gefunden.' }

& $docker.Source image inspect $SourceImage | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Quellimage wurde nicht gefunden: $SourceImage" }

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("FabricNavigator-Release-" + [Guid]::NewGuid().ToString('N'))
$updateStage = Join-Path $temporaryRoot 'update'
$runtime = Join-Path $updateStage 'runtime'
$installerStage = Join-Path $temporaryRoot 'installer'
$buildContext = Join-Path $temporaryRoot 'build'
$flattenContext = Join-Path $temporaryRoot 'flatten'
$layeredTag = "fabricnavigator:$Version-layered"
$cleanContainer = "fabricnavigator-flatten-" + [Guid]::NewGuid().ToString('N')
New-Item -ItemType Directory -Force -Path $runtime, $installerStage, $buildContext, $flattenContext | Out-Null

try {
    $workspaceRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $webRoot = Join-Path $workspaceRoot 'fabricnavigator-rootfs\opt\apache-tomcat-8.0.36\webapps\ROOT'
    $acliRoot = Join-Path $workspaceRoot 'acli-src\opt'
    $sourceRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')
    $overlay = [ordered]@{
        (Join-Path $PSScriptRoot 'fabricnavigator-nginx.conf.template') = 'etc/nginx/templates/fabricnavigator.conf.template'
        (Join-Path $PSScriptRoot 'fabricnavigator-egress.nft') = 'etc/nftables.d/fabricnavigator-egress.nft'
        (Join-Path $PSScriptRoot 'fabricnavigator-setenv.sh') = 'opt/tomcat/bin/setenv.sh'
        (Join-Path $PSScriptRoot 'fabricnavigator-entrypoint.sh') = 'opt/fabricnavigator/fabricnavigator-entrypoint.sh'
        (Join-Path $PSScriptRoot 'route-manager.py') = 'opt/fabricnavigator/route-manager.py'
        (Join-Path $PSScriptRoot 'webview-proxy.py') = 'opt/fabricnavigator/webview-proxy.py'
        (Join-Path $PSScriptRoot 'update-coordinator.py') = 'opt/fabricnavigator/update-coordinator.py'
        (Join-Path $PSScriptRoot 'ssh-probe.pl') = 'opt/fabricnavigator/ssh-probe.pl'
        (Join-Path $PSScriptRoot 'service-provision.pl') = 'opt/fabricnavigator/service-provision.pl'
        (Join-Path $PSScriptRoot 'acli-launch.pl') = 'opt/acli/acli-launch.pl'
        (Join-Path $PSScriptRoot 'acli-default.ini') = 'opt/acli-web/acli-default.ini'
        (Join-Path $acliRoot 'acli\acli.pl') = 'opt/acli/acli-terminal.pl'
        (Join-Path $acliRoot 'acli\AcliPm\HandleDeviceOutput.pm') = 'opt/acli/AcliPm/HandleDeviceOutput.pm'
        (Join-Path $acliRoot 'acli\AcliPm\ExitHandlers.pm') = 'opt/acli/AcliPm/ExitHandlers.pm'
        (Join-Path $acliRoot 'acli-web\pty_bridge.py') = 'opt/acli-web/pty_bridge.py'
        (Join-Path $sourceRoot 'src\java') = 'opt/fabricnavigator/snmp-src'
        (Join-Path $sourceRoot 'third_party\snmp4j\snmp4j-2.8.18.jar') = 'opt/fabricnavigator/snmp4j-2.8.18.jar'
        (Join-Path $sourceRoot 'third_party\snmp4j\LICENSE-2.0.txt') = 'opt/fabricnavigator/licenses/SNMP4J-LICENSE-2.0.txt'
        (Join-Path $sourceRoot 'third_party\acli\LICENSE-GPL-3.0.txt') = 'opt/fabricnavigator/licenses/ACLI-LICENSE-GPL-3.0.txt'
        (Join-Path $sourceRoot 'third_party\xtermjs\LICENSE-MIT.txt') = 'opt/fabricnavigator/licenses/XTERMJS-LICENSE-MIT.txt'
        (Join-Path $workspaceRoot 'fabricnavigator-security\fabricnavigator-security.jar') = 'opt/tomcat/lib/fabricnavigator-security.jar'
    }
    foreach ($relative in @(
        'terminal\index.jsp', 'webview-ticket.jsp', 'session-info.jsp', 'user-preferences.jsp', 'profile\index.jsp', 'profile\plugin-status.jsp', 'api-sessions.jsp', 'WEB-INF\web.xml',
        'login.jsp', 'setup.jsp', 'setup-credentials.jsp', 'topology\index.jsp', 'topology\service-action.jsp', 'topology\ping-action.jsp', 'snmp\get-variables.jsp', 'devices\index.jsp', 'credits\index.jsp', 'index.jsp', 'admin\index.jsp',
        'admin\webview-profiles.jsp', 'admin\credential-defaults.jsp', 'admin\discovery.jsp', 'admin\acli-settings.jsp', 'admin\api.jsp', 'admin\system.jsp', 'admin\update.jsp', 'admin\update-channel.jsp', 'admin\offline-package.jsp',
        'assets\app-shell.js', 'assets\app-shell.css', 'assets\security.css', 'assets\setup-wizard.js',
        'assets\FabricNavigator_modern_transparent.png', 'assets\FabricNavigator_modern_light.png',
        'assets\switch-front-universal.svg', 'assets\switch-front-fabric.svg',
        'assets\switch-front-switchengine.svg', 'assets\generic-phone.png',
        'assets\generic-switch.png', 'assets\generic-wlan-ap.png', 'assets\generic-firewall.png',
        'assets\topology-group.svg', 'assets\service-ui.js', 'assets\service-ui.css', 'assets\update-channel.js', 'assets\offline-packages.js', 'assets\user-profile.js', 'assets\user-profile.css'
    )) {
        $overlay[(Join-Path $webRoot $relative)] = 'opt/tomcat/webapps/ROOT/' + $relative.Replace('\', '/')
    }
    $dockerfile = [Collections.Generic.List[string]]::new()
    $dockerfile.Add('ARG BASE_IMAGE')
    $dockerfile.Add('FROM ${BASE_IMAGE}')
    $overlayRoot = Join-Path $buildContext 'rootfs'
    foreach ($item in $overlay.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $item.Key)) { throw "Overlay-Datei fehlt: $($item.Key)" }
        $localPath = Join-Path $overlayRoot $item.Value.Replace('/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path $localPath -Parent) | Out-Null
        Copy-Item -LiteralPath $item.Key -Destination $localPath -Recurse -Force
    }
    # Keep every core update to one filesystem layer. Older packages emitted one
    # COPY layer per file and eventually exceeded overlayfs' lowerdir limit.
    $dockerfile.Add('RUN --mount=type=bind,source=rootfs,target=/tmp/fabricnavigator-overlay,ro rm -rf /opt/fabricnavigator/snmp-src && cp -aL /tmp/fabricnavigator-overlay/etc/. /etc/ && cp -aL /tmp/fabricnavigator-overlay/opt/fabricnavigator/. /opt/fabricnavigator/ && cp -aL /tmp/fabricnavigator-overlay/opt/acli/. /opt/acli/ && cp -aL /tmp/fabricnavigator-overlay/opt/acli-web/. /opt/acli-web/ && cp -aL /tmp/fabricnavigator-overlay/opt/tomcat/. "$(readlink -f /opt/tomcat)/"')
    $dockerfile.Add('RUN rm -rf /opt/tomcat/webapps/edm /opt/tomcat/webapps/edm.war /opt/tomcat/webapps/ROOT/WEB-INF/classes/com && rm -f /opt/tomcat/lib/edm-security.jar /etc/nftables.d/edm-egress.nft /etc/systemd/system/edm-egress.service /etc/systemd/system/edm-egress.path /etc/systemd/system/multi-user.target.wants/edm-egress.path /opt/tomcat/webapps/ROOT/community-main.jsp /opt/tomcat/webapps/ROOT/device-main.jsp /opt/tomcat/webapps/ROOT/WEB-INF/lib/snmp4jdm-1.0.jar /opt/tomcat/webapps/ROOT/WEB-INF/classes/mib.dat && if [ -f /usr/local/sbin/refresh-edm-egress.py ]; then sed -i -e ''s/edm-egress/fabricnavigator-egress/g'' -e ''s/edm_egress/fabricnavigator_egress/g'' /usr/local/sbin/refresh-edm-egress.py && mv /usr/local/sbin/refresh-edm-egress.py /usr/local/sbin/refresh-fabricnavigator-egress.py; elif [ -f /usr/local/sbin/refresh-fabricnavigator-egress.py ]; then sed -i -e ''s/edm-egress/fabricnavigator-egress/g'' -e ''s/edm_egress/fabricnavigator_egress/g'' /usr/local/sbin/refresh-fabricnavigator-egress.py; fi && if [ -f /usr/local/bin/docker-entrypoint.sh ]; then sed -i ''s#refresh-edm-egress\.py#refresh-fabricnavigator-egress.py#g'' /usr/local/bin/docker-entrypoint.sh; fi && cp /opt/fabricnavigator/snmp4j-2.8.18.jar /opt/tomcat/webapps/ROOT/WEB-INF/lib/ && mkdir -p /tmp/fn-snmp-classes && /opt/java8/bin/java -cp /opt/tomcat/lib/ecj-4.5.jar org.eclipse.jdt.internal.compiler.batch.Main -1.8 -d /tmp/fn-snmp-classes -classpath /opt/fabricnavigator/snmp4j-2.8.18.jar /opt/fabricnavigator/snmp-src && cp -rf /tmp/fn-snmp-classes/com /opt/tomcat/webapps/ROOT/WEB-INF/classes/ && rm -rf /tmp/fn-snmp-classes')
    # Product photographs are distributed only through the optional external plugin.
    # Remove legacy copies inherited from an older base image so core releases remain redistributable.
    $dockerfile.Add('RUN rm -rf /opt/tomcat/webapps/ROOT/assets/product-switches && rm -f /opt/tomcat/webapps/ROOT/assets/extreme-5320-24p-front.png /opt/tomcat/webapps/ROOT/assets/extreme-5320-16p-front.png /opt/tomcat/webapps/ROOT/assets/product-5320-24p-8xe.png /opt/tomcat/webapps/ROOT/assets/product-5320-16p-2mxt-2x.png')
    $dockerfile.Add("ENV FABRICNAVIGATOR_VERSION=$Version")
    $dockerfile.Add('ENTRYPOINT ["/bin/sh", "/opt/fabricnavigator/fabricnavigator-entrypoint.sh"]')
    [IO.File]::WriteAllLines((Join-Path $buildContext 'Dockerfile'), $dockerfile, [Text.UTF8Encoding]::new($false))
    & $docker.Source build --build-arg "BASE_IMAGE=$SourceImage" --tag $layeredTag $buildContext
    if ($LASTEXITCODE -ne 0) { throw 'Das eigenständige Release-Image konnte nicht gebaut werden.' }

    # Flatten the cleaned filesystem so the former EDM application cannot be
    # recovered from an inherited Docker layer in distributed images.
    $cleanRootfs = Join-Path $flattenContext 'rootfs.tar'
    & $docker.Source create --name $cleanContainer --entrypoint /bin/true $layeredTag | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Der bereinigte Release-Container konnte nicht angelegt werden.' }
    & $docker.Source export --output $cleanRootfs $cleanContainer
    if ($LASTEXITCODE -ne 0) { throw 'Das bereinigte Release-Dateisystem konnte nicht exportiert werden.' }
    & $docker.Source rm $cleanContainer | Out-Null
    $cleanContainer = ''
    $flattenDockerfile = @(
        'FROM scratch'
        'ADD rootfs.tar /'
        'ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin JAVA_HOME=/opt/java8 CATALINA_HOME=/opt/tomcat CATALINA_BASE=/opt/tomcat'
        'WORKDIR /opt/tomcat'
        'EXPOSE 80 443'
        "ENV FABRICNAVIGATOR_VERSION=$Version"
        'ENTRYPOINT ["/bin/sh", "/opt/fabricnavigator/fabricnavigator-entrypoint.sh"]'
        'HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 CMD curl -kfsS https://127.0.0.1/login.jsp >/dev/null || exit 1'
    )
    [IO.File]::WriteAllLines((Join-Path $flattenContext 'Dockerfile'), $flattenDockerfile, [Text.UTF8Encoding]::new($false))
    & $docker.Source build --tag $releaseTag $flattenContext
    if ($LASTEXITCODE -ne 0) { throw 'Das flache, EDM-freie Release-Image konnte nicht gebaut werden.' }
    & $docker.Source image rm $layeredTag | Out-Null

    $imageGzip = $null
    if ($UpdateMode -eq 'Full' -or -not $SkipInstaller) {
        $imageTar = Join-Path $temporaryRoot "FabricNavigator-Image-$Version.tar"
        $imageGzip = Join-Path $temporaryRoot "FabricNavigator-Image-$Version.tar.gz"
        & $docker.Source save --output $imageTar $releaseTag
        if ($LASTEXITCODE -ne 0) { throw 'docker save ist fehlgeschlagen.' }

        $inputStream = [IO.File]::OpenRead($imageTar)
        $outputStream = [IO.File]::Create($imageGzip)
        try {
            $gzipStream = [IO.Compression.GZipStream]::new($outputStream, [IO.Compression.CompressionLevel]::Optimal, $true)
            try { $inputStream.CopyTo($gzipStream) } finally { $gzipStream.Dispose() }
        } finally {
            $inputStream.Dispose()
            $outputStream.Dispose()
        }
    }

    if ($UpdateMode -eq 'Full') {
        Copy-Item -LiteralPath $imageGzip -Destination (Join-Path $runtime "FabricNavigator-Image-$Version.tar.gz")
    } else {
        $coreOverlay = Join-Path $runtime 'core-overlay'
        Copy-Item -LiteralPath $buildContext -Destination $coreOverlay -Recurse
        $manifest = @(
            'format=core-overlay-v1'
            "targetVersion=$Version"
            "minimumBaseVersion=$MinimumCoreOverlayBaseVersion"
        )
        [IO.File]::WriteAllLines((Join-Path $coreOverlay 'manifest.properties'), $manifest, [Text.UTF8Encoding]::new($false))
    }

    $compose = [IO.File]::ReadAllText($composeTemplate).Replace('__VERSION__', $Version)
    [IO.File]::WriteAllText((Join-Path $runtime 'compose.yaml'), $compose, [Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath $updater -Destination (Join-Path $runtime 'FabricNavigator-Updater.ps1')
    Copy-Item -LiteralPath $linuxUpdater -Destination (Join-Path $runtime 'fabricnavigator-updater.py')
    Copy-Item -LiteralPath $linuxUpdaterService -Destination (Join-Path $runtime 'fabricnavigator-updater.service')
    Copy-Item -LiteralPath $linuxUpdaterMigration -Destination (Join-Path $runtime 'migrate-fabricnavigator-updater.sh')
    Copy-Item -LiteralPath $proxmoxCompose -Destination (Join-Path $runtime 'compose.proxmox.yaml')
    [IO.File]::WriteAllText((Join-Path $runtime 'RELEASE_NOTES.md'), $releaseNotes, [Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'THIRD_PARTY_NOTICES.md') -Destination (Join-Path $runtime 'THIRD_PARTY_NOTICES.md')
    $runtimeLicenses = Join-Path $runtime 'licenses'
    New-Item -ItemType Directory -Force -Path $runtimeLicenses | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'third_party\acli\LICENSE-GPL-3.0.txt') -Destination (Join-Path $runtimeLicenses 'ACLI-LICENSE-GPL-3.0.txt')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'third_party\snmp4j\LICENSE-2.0.txt') -Destination (Join-Path $runtimeLicenses 'SNMP4J-LICENSE-2.0.txt')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'third_party\xtermjs\LICENSE-MIT.txt') -Destination (Join-Path $runtimeLicenses 'XTERMJS-LICENSE-MIT.txt')

    $updateArchive = Join-Path $OutputDirectory "FabricNavigator-Update-$Version.zip"
    New-PortableZipArchive -SourceDirectory $updateStage -DestinationArchive $updateArchive

    $releaseArchives = @($updateArchive)
    if (-not $SkipInstaller) {
        Get-ChildItem -LiteralPath $runtime -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $installerStage -Recurse
        }
        if (-not (Test-Path -LiteralPath (Join-Path $installerStage "FabricNavigator-Image-$Version.tar.gz"))) {
            Copy-Item -LiteralPath $imageGzip -Destination (Join-Path $installerStage "FabricNavigator-Image-$Version.tar.gz")
        }
        Copy-Item -LiteralPath $installer -Destination (Join-Path $installerStage 'Import-FabricNavigator.ps1')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README-Windows.md') -Destination (Join-Path $installerStage 'README-Windows.md')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '.env.example') -Destination (Join-Path $installerStage '.env.example')
        New-Item -ItemType Directory -Force -Path (Join-Path $installerStage 'update-state') | Out-Null
        $installerArchive = Join-Path $OutputDirectory "FabricNavigator-Installer-$Version.zip"
        New-PortableZipArchive -SourceDirectory $installerStage -DestinationArchive $installerArchive
        $releaseArchives += $installerArchive
    }

    $manifest = $releaseArchives | ForEach-Object {
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash.ToLowerInvariant()
        "$hash  $([IO.Path]::GetFileName($_))"
    }
    [IO.File]::WriteAllLines((Join-Path $OutputDirectory 'SHA256SUMS'), $manifest, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $OutputDirectory "RELEASE_NOTES-$Version.md"), $releaseNotes, [Text.UTF8Encoding]::new($false))

    Write-Host "Releasepakete wurden unter $OutputDirectory erstellt." -ForegroundColor Green
    $manifest | ForEach-Object { Write-Host $_ }
} finally {
    if ($cleanContainer) { & $docker.Source rm -f $cleanContainer 2>$null | Out-Null }
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -Recurse -Force -LiteralPath $temporaryRoot }
}
