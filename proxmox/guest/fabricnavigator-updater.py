#!/usr/bin/env python3
"""Privileged Linux-side installer for updates approved in FabricNavigator."""

import datetime
import hashlib
import ipaddress
import json
import os
import re
import shutil
import ssl
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path("/opt/fabricnavigator")
STATE = ROOT / "update-state"
REQUEST = STATE / "install.request"
STATUS = STATE / "host-status.properties"
OFFLINE = STATE / "offline"
OFFLINE_STATUS = STATE / "offline-update.properties"
PLUGIN_REQUEST = STATE / "plugin-install.request"
PLUGIN_STATUS = STATE / "plugin-status.properties"
PLUGIN_DESTINATION = ROOT / "plugins" / "extreme-device-images"
HOST_ROUTES = STATE / "host-routes.conf"
HOST_ROUTES_MANAGED = STATE / "host-routes-managed.conf"
HOST_ROUTE_STATUS = STATE / "host-route-status.txt"
HOST_ROUTES_ACTIVE = STATE / "host-routes-active.txt"
HOST_ROUTE_GATEWAY = STATE / "host-route-gateway.txt"
GITHUB_TOKEN_REQUEST = STATE / "github-token.request"
GITHUB_TOKEN_STATUS = STATE / "github-token-status.properties"
GITHUB_TOKEN_DESTINATION = ROOT / "secrets" / "github-update-token.txt"
SYSTEM_ACTION_REQUEST = STATE / "system-action.request"
SYSTEM_ACTION_STATUS = STATE / "system-action-status.properties"
HOST_NETWORK_REQUEST = STATE / "host-network.request"
HOST_NETWORK_STATUS = STATE / "host-network-status.properties"
HOST_NETWORK_NETPLAN = Path("/etc/netplan/90-fabricnavigator.yaml")
UPDATER_SERVICE_SOURCE = ROOT / "fabricnavigator-updater.service"
UPDATER_SERVICE_DESTINATION = Path("/etc/systemd/system/fabricnavigator-updater.service")
PROXMOX_COMPOSE = ROOT / "compose.proxmox.yaml"
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+\.\d+$")
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
TOKEN_RE = re.compile(r"^[A-Za-z0-9_]{20,512}$")


def clean(value):
    return str(value or "").replace("\\", "\\\\").replace("\r", "").replace("\n", "\\n")


def compose_up():
    command = ["docker", "compose", "--project-directory", str(ROOT), "-f", str(ROOT / "compose.yaml")]
    if PROXMOX_COMPOSE.is_file():
        command.extend(["-f", str(PROXMOX_COMPOSE)])
    command.extend(["up", "-d", "--remove-orphans"])
    run(*command)


def status(state, version="", message=""):
    STATE.mkdir(parents=True, exist_ok=True)
    content = (
        f"state={clean(state)}\nversion={clean(version)}\n"
        f"updatedAt={datetime.datetime.now(datetime.timezone.utc).isoformat()}\n"
        f"message={clean(message)}\ncapabilities=offline-core,device-images\n"
    )
    temporary = STATUS.with_suffix(".tmp")
    temporary.write_text(content, encoding="utf-8")
    os.replace(temporary, STATUS)


def system_action_status(state, message=""):
    content = (
        f"state={clean(state)}\nupdatedAt={datetime.datetime.now(datetime.timezone.utc).isoformat()}\n"
        f"message={clean(message)}\n"
    )
    temporary = SYSTEM_ACTION_STATUS.with_suffix(".tmp")
    temporary.write_text(content, encoding="utf-8")
    os.replace(temporary, SYSTEM_ACTION_STATUS)


def host_network_status(state, interface="", mode="", address="", prefix="", gateway="", dns="", message=""):
    content = (
        f"state={clean(state)}\nupdatedAt={datetime.datetime.now(datetime.timezone.utc).isoformat()}\n"
        f"interface={clean(interface)}\nmode={clean(mode)}\naddress={clean(address)}\n"
        f"prefix={clean(prefix)}\ngateway={clean(gateway)}\ndns={clean(dns)}\nmessage={clean(message)}\n"
    )
    temporary = HOST_NETWORK_STATUS.with_suffix(".tmp")
    temporary.write_text(content, encoding="utf-8")
    os.replace(temporary, HOST_NETWORK_STATUS)


def ensure_updater_service_definition():
    """Install an updated sandbox definition before privileged host actions run."""
    if not UPDATER_SERVICE_SOURCE.is_file():
        return False
    source = UPDATER_SERVICE_SOURCE.read_bytes()
    try:
        current = UPDATER_SERVICE_DESTINATION.read_bytes()
    except OSError:
        current = b""
    if current == source:
        return False
    stamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    subprocess.run([
        "systemd-run", "--quiet", "--wait", "--collect",
        f"--unit=fabricnavigator-updater-unit-{stamp}",
        "/usr/bin/install", "-m", "0644", str(UPDATER_SERVICE_SOURCE), str(UPDATER_SERVICE_DESTINATION),
    ], check=True)
    subprocess.run(["systemctl", "daemon-reload"], check=True)
    subprocess.run([
        "systemd-run", "--quiet", "--collect", "--on-active=1s",
        f"--unit=fabricnavigator-updater-restart-{stamp}",
        "/bin/systemctl", "restart", "fabricnavigator-updater.service",
    ], check=True)
    return True


def primary_network_interface():
    result = subprocess.run(
        ["ip", "-4", "route", "show", "default"], check=True, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ).stdout.split()
    if "dev" not in result:
        raise RuntimeError("The primary IPv4 interface could not be determined.")
    interface = result[result.index("dev") + 1]
    if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,32}", interface) or interface == "lo":
        raise RuntimeError("The detected network interface is not supported.")
    return interface


def current_interface_address(interface):
    result = subprocess.run(
        ["ip", "-4", "-o", "addr", "show", "dev", interface], check=False, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    ).stdout.split()
    if "inet" not in result:
        return "", ""
    address = result[result.index("inet") + 1]
    return tuple(address.split("/", 1)) if "/" in address else (address, "")


def write_host_network_snapshot():
    """Publish the currently active host IPv4 settings for the Admin UI."""
    try:
        if HOST_NETWORK_STATUS.is_file() and properties(HOST_NETWORK_STATUS).get("state") == "error":
            return
        interface = primary_network_interface()
        address, prefix = current_interface_address(interface)
        address_line = subprocess.run(
            ["ip", "-4", "-o", "addr", "show", "dev", interface], check=False,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        ).stdout
        mode = "dhcp" if re.search(r"\bdynamic\b", address_line) else "static"
        route = subprocess.run(
            ["ip", "-4", "route", "show", "default", "dev", interface], check=False,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        ).stdout.split()
        gateway = route[route.index("via") + 1] if "via" in route else ""
        dns_values = []
        if shutil.which("resolvectl"):
            output = subprocess.run(
                ["resolvectl", "dns", interface], check=False, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            ).stdout
            if ":" in output:
                for value in output.split(":", 1)[1].split():
                    try:
                        dns_values.append(str(ipaddress.IPv4Address(value)))
                    except ValueError:
                        pass
        if not dns_values:
            try:
                for line in Path("/etc/resolv.conf").read_text(encoding="utf-8").splitlines():
                    parts = line.split()
                    if len(parts) == 2 and parts[0] == "nameserver":
                        try:
                            dns_values.append(str(ipaddress.IPv4Address(parts[1])))
                        except ValueError:
                            pass
            except OSError:
                pass
        host_network_status("active", interface, mode, address, prefix, gateway, ",".join(dict.fromkeys(dns_values)), "Current host network configuration.")
    except Exception as error:
        if not HOST_NETWORK_STATUS.is_file():
            host_network_status("error", message=str(error))


def process_host_network_request():
    if not HOST_NETWORK_REQUEST.is_file():
        return
    pending = properties(HOST_NETWORK_REQUEST, java_escaped=True)
    try:
        if int(pending.get("notBefore", "0") or "0") > int(time.time() * 1000):
            return
    except ValueError:
        pass
    processing = HOST_NETWORK_REQUEST.with_suffix(".processing")
    os.replace(HOST_NETWORK_REQUEST, processing)
    request = {}
    try:
        request = properties(processing, java_escaped=True)
        mode = request.get("mode", "").lower()
        if mode not in ("dhcp", "static"):
            raise RuntimeError("Network mode must be dhcp or static.")
        interface = request.get("interface", "").strip() or primary_network_interface()
        if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,32}", interface) or interface == "lo" or not (Path("/sys/class/net") / interface).exists():
            raise RuntimeError("The selected host interface is not valid.")
        if shutil.which("netplan") is None:
            raise RuntimeError("Netplan is required to configure the FabricNavigator VM network.")
        address = prefix = gateway = ""
        dns_values = []
        for item in request.get("dns", "").split(","):
            if item.strip():
                dns_values.append(str(ipaddress.IPv4Address(item.strip())))
        if len(dns_values) > 3:
            raise RuntimeError("At most three IPv4 DNS servers are supported.")
        if mode == "static":
            address = str(ipaddress.IPv4Address(request.get("address", "")))
            prefix = str(int(request.get("prefix", "")))
            configured = ipaddress.IPv4Interface(f"{address}/{prefix}")
            gateway = str(ipaddress.IPv4Address(request.get("gateway", "")))
            if ipaddress.IPv4Address(gateway) not in configured.network:
                raise RuntimeError("The IPv4 gateway must be inside the configured subnet.")
        lines = [
            "network:", "  version: 2", "  ethernets:", f"    {interface}:",
            f"      dhcp4: {'true' if mode == 'dhcp' else 'false'}", "      dhcp6: false",
        ]
        if mode == "static":
            lines.extend([f"      addresses: [{address}/{prefix}]", f"      routes: [{{to: default, via: {gateway}}}]"])
        elif dns_values:
            lines.extend(["      dhcp4-overrides:", "        use-dns: false"])
        if dns_values:
            lines.extend(["      nameservers:", "        addresses: [" + ", ".join(dns_values) + "]"])
        temporary = STATE / "host-network-netplan.tmp"
        temporary.write_text("\n".join(lines) + "\n", encoding="utf-8")
        os.chmod(temporary, 0o600)
        stamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
        subprocess.run([
            "systemd-run", "--quiet", "--wait", "--collect",
            f"--unit=fabricnavigator-network-write-{stamp}",
            "/usr/bin/install", "-m", "0600", str(temporary), str(HOST_NETWORK_NETPLAN),
        ], check=True)
        subprocess.run([
            "systemd-run", "--quiet", "--wait", "--collect",
            f"--unit=fabricnavigator-network-generate-{stamp}",
            shutil.which("netplan"), "generate",
        ], check=True)
        temporary.unlink(missing_ok=True)
        unit = "fabricnavigator-network-" + stamp
        subprocess.run(["systemd-run", f"--unit={unit}", "--on-active=10s", "/usr/sbin/netplan", "apply"], check=True)
        host_network_status("scheduled", interface, mode, address, prefix, gateway, ",".join(dns_values), "The host IPv4 configuration will be applied in approximately 10 seconds.")
    except Exception as error:
        host_network_status("error", request.get("interface", ""), request.get("mode", ""), message=str(error))
        raise
    finally:
        (STATE / "host-network-netplan.tmp").unlink(missing_ok=True)
        processing.unlink(missing_ok=True)


def process_system_action_request():
    if not SYSTEM_ACTION_REQUEST.is_file():
        return
    processing = SYSTEM_ACTION_REQUEST.with_suffix(".processing")
    os.replace(SYSTEM_ACTION_REQUEST, processing)
    try:
        request = properties(processing, java_escaped=True)
        if request.get("action") != "restart":
            raise RuntimeError("Unsupported system action.")
        unit = "fabricnavigator-reboot-" + datetime.datetime.now().strftime("%Y%m%d%H%M%S")
        subprocess.run(
            ["systemd-run", f"--unit={unit}", "--on-active=10s", "/usr/bin/systemctl", "reboot"],
            check=True,
        )
        system_action_status("scheduled", "The FabricNavigator host will restart in approximately 10 seconds.")
    except Exception as error:
        system_action_status("error", str(error))
        raise
    finally:
        processing.unlink(missing_ok=True)


def java_property_unescape(value):
    """Decode the escaping emitted by java.util.Properties.store()."""
    result = []
    index = 0
    translations = {"t": "\t", "n": "\n", "r": "\r", "f": "\f"}
    while index < len(value):
        character = value[index]
        if character != "\\" or index + 1 >= len(value):
            result.append(character)
            index += 1
            continue
        index += 1
        escaped = value[index]
        if escaped == "u" and index + 4 < len(value):
            codepoint = value[index + 1:index + 5]
            if re.fullmatch(r"[0-9a-fA-F]{4}", codepoint):
                result.append(chr(int(codepoint, 16)))
                index += 5
                continue
        result.append(translations.get(escaped, escaped))
        index += 1
    return "".join(result)


def properties(path, java_escaped=False):
    result = {}
    if not path.is_file():
        return result
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith(("#", "!")) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip("\"'")
        if java_escaped:
            key = java_property_unescape(key)
            value = java_property_unescape(value)
        result[key] = value
    return result


def token(settings):
    relative = settings.get("FABRICNAVIGATOR_GITHUB_TOKEN_FILE", "secrets/github-update-token.txt")
    candidate = (ROOT / relative).resolve()
    if ROOT.resolve() not in candidate.parents:
        raise RuntimeError("The GitHub token path leaves the installation directory.")
    if not candidate.is_file():
        return ""
    value = candidate.read_text(encoding="utf-8").strip()
    if not TOKEN_RE.fullmatch(value):
        raise RuntimeError("The GitHub token file has an invalid format.")
    return value


def github_json(url, auth):
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "FabricNavigator-Linux-Updater",
        "X-GitHub-Api-Version": "2026-03-10",
    }
    if auth:
        headers["Authorization"] = "Bearer " + auth
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=30, context=ssl.create_default_context()) as response:
        return json.loads(response.read(4 * 1024 * 1024).decode("utf-8"))


def download_asset(url, destination, auth):
    headers = {
        "Accept": "application/octet-stream",
        "User-Agent": "FabricNavigator-Linux-Updater",
        "X-GitHub-Api-Version": "2026-03-10",
    }
    if auth:
        headers["Authorization"] = "Bearer " + auth
    request = urllib.request.Request(url, headers=headers)
    digest = hashlib.sha256()
    with urllib.request.urlopen(request, timeout=120, context=ssl.create_default_context()) as response, destination.open("wb") as out:
        while True:
            block = response.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
            out.write(block)
    return digest.hexdigest()


def safe_extract(archive, destination):
    root = destination.resolve()
    with zipfile.ZipFile(archive) as bundle:
        for member in bundle.infolist():
            target = (destination / member.filename).resolve()
            if target != root and root not in target.parents:
                raise RuntimeError(f"Unsafe path in update archive: {member.filename}")
        bundle.extractall(destination)


def run(*args):
    subprocess.run(args, check=True)


def atomic_text(path, content):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(content, encoding="utf-8")
    os.replace(temporary, path)


def github_token_status(state, configured, message=""):
    message = " ".join(str(message).split())
    atomic_text(
        GITHUB_TOKEN_STATUS,
        f"state={state}\nconfigured={'true' if configured else 'false'}\n"
        f"updatedAt={datetime.datetime.now(datetime.timezone.utc).isoformat()}\nmessage={message}\n",
    )


def container_root_host_uid():
    """Return the host uid mapped to uid 0 in the application container."""
    inspected = subprocess.run(
        ("docker", "inspect", "--format", "{{.State.Pid}}", "fabricnavigator"),
        check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    pid = inspected.stdout.strip()
    if inspected.returncode or not pid.isdigit():
        return 0
    try:
        for line in Path("/proc").joinpath(pid, "uid_map").read_text(encoding="ascii").splitlines():
            inside, outside, length = (int(value) for value in line.split())
            if inside <= 0 < inside + length:
                return outside - inside
    except (OSError, ValueError):
        pass
    return 0


def process_github_token_request():
    if not GITHUB_TOKEN_REQUEST.is_file():
        return
    processing = GITHUB_TOKEN_REQUEST.with_suffix(".processing")
    os.replace(GITHUB_TOKEN_REQUEST, processing)
    token_value = ""
    try:
        request = properties(processing, java_escaped=True)
        action = request.get("action", "")
        if action == "install":
            token_value = request.get("token", "")
            if not TOKEN_RE.fullmatch(token_value):
                raise RuntimeError("The GitHub token has an invalid format.")
            GITHUB_TOKEN_DESTINATION.parent.mkdir(parents=True, exist_ok=True)
            temporary = GITHUB_TOKEN_DESTINATION.with_suffix(".tmp")
            temporary.write_text(token_value, encoding="utf-8")
            # Docker may remap container uid 0. Give only that mapped uid read
            # access; guest users still cannot read an optionally configured repository token.
            os.chown(temporary, container_root_host_uid(), 0)
            os.chmod(temporary, 0o400)
            os.replace(temporary, GITHUB_TOKEN_DESTINATION)
            github_token_status("configured", True, "GitHub token was stored securely on the Docker host.")
        elif action == "remove":
            GITHUB_TOKEN_DESTINATION.unlink(missing_ok=True)
            github_token_status("removed", False, "GitHub token was removed from the Docker host.")
        else:
            raise RuntimeError("Unknown GitHub token action.")
    except Exception as error:
        github_token_status("error", GITHUB_TOKEN_DESTINATION.is_file(), error)
    finally:
        token_value = ""
        processing.unlink(missing_ok=True)


def route_status(destination, gateway, state, message=""):
    message = " ".join(str(message).replace("|", "/").split())
    atomic_text(HOST_ROUTE_STATUS, f"{destination}|{gateway}|{state}|{message}\n")


def read_desired_routes():
    result = {}
    if not HOST_ROUTES.is_file():
        return result
    for line in HOST_ROUTES.read_text(encoding="utf-8").splitlines():
        parts = line.strip().split("|", 1)
        if len(parts) != 2:
            continue
        destination, gateway = parts
        try:
            if destination != "default":
                ipaddress.ip_network(destination, strict=False)
            ipaddress.ip_address(gateway)
        except ValueError:
            continue
        result[destination] = gateway
    return result


def read_managed_routes():
    result = {}
    if not HOST_ROUTES_MANAGED.is_file():
        return result
    for line in HOST_ROUTES_MANAGED.read_text(encoding="utf-8").splitlines():
        parts = line.strip().split("|", 2)
        if len(parts) == 3:
            result[parts[0]] = {"gateway": parts[1], "owned": parts[2] == "1"}
    return result


def save_managed_routes(routes):
    content = "".join(
        f"{destination}|{routes[destination]['gateway']}|{'1' if routes[destination]['owned'] else '0'}\n"
        for destination in sorted(routes)
    )
    atomic_text(HOST_ROUTES_MANAGED, content)


def linux_destination(destination):
    return "default" if destination == "default" else str(ipaddress.ip_network(destination, strict=False))


def route_output(*args):
    return subprocess.run(
        ("ip", "-4", "route", *args), check=False, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )


def add_host_route(destination, gateway):
    destination = linux_destination(destination)
    current = route_output("show", destination).stdout
    if f"via {gateway}" in current:
        return False
    if current.strip():
        raise RuntimeError(f"A different route for {destination} already exists on the Docker host.")
    result = route_output("add", destination, "via", gateway)
    if result.returncode:
        raise RuntimeError(result.stdout.strip() or "ip route add failed")
    return True


def remove_host_route(destination, gateway):
    result = route_output("del", linux_destination(destination), "via", gateway)
    if result.returncode and "No such process" not in result.stdout:
        raise RuntimeError(result.stdout.strip() or "ip route del failed")


def write_host_route_snapshot():
    active = route_output("show")
    atomic_text(HOST_ROUTES_ACTIVE, active.stdout)
    default = route_output("show", "default").stdout.split()
    gateway = default[default.index("via") + 1] if "via" in default else ""
    atomic_text(HOST_ROUTE_GATEWAY, gateway + "\n")


def reconcile_host_routes():
    if not HOST_ROUTES.is_file():
        return None
    signature = (HOST_ROUTES.stat().st_mtime_ns, HOST_ROUTES.stat().st_size)
    desired = read_desired_routes()
    managed = read_managed_routes()
    for destination in list(managed):
        entry = managed[destination]
        if destination not in desired or desired[destination] != entry["gateway"]:
            try:
                if entry["owned"]:
                    remove_host_route(destination, entry["gateway"])
                del managed[destination]
                route_status(destination, entry["gateway"], "deleted")
            except Exception as error:
                route_status(destination, entry["gateway"], "error", error)
                save_managed_routes(managed)
                write_host_route_snapshot()
                return signature
    for destination, gateway in desired.items():
        if destination in managed and managed[destination]["gateway"] == gateway:
            try:
                if add_host_route(destination, gateway):
                    managed[destination]["owned"] = True
            except Exception as error:
                route_status(destination, gateway, "error", error)
                save_managed_routes(managed)
                write_host_route_snapshot()
                return signature
            route_status(destination, gateway, "ok")
            continue
        try:
            owned = add_host_route(destination, gateway)
            managed[destination] = {"gateway": gateway, "owned": owned}
            route_status(destination, gateway, "ok")
        except Exception as error:
            route_status(destination, gateway, "error", error)
            save_managed_routes(managed)
            write_host_route_snapshot()
            return signature
    save_managed_routes(managed)
    write_host_route_snapshot()
    write_host_network_snapshot()
    return signature


def healthcheck():
    context = ssl._create_unverified_context()
    for _ in range(45):
        try:
            with urllib.request.urlopen("https://127.0.0.1:8443/health.jsp", timeout=4, context=context) as response:
                if response.status == 200:
                    return
        except Exception:
            time.sleep(2)
    raise RuntimeError("The updated application did not pass its health check.")


def install(request):
    requested = request.get("version", "")
    if not VERSION_RE.fullmatch(requested):
        raise RuntimeError("Invalid requested version.")
    channel = request.get("channel", "stable")
    if channel not in ("stable", "beta"):
        raise RuntimeError("Invalid update channel.")
    work = Path(tempfile.mkdtemp(prefix="fabricnavigator-update-", dir="/var/tmp"))
    backup = ROOT / ".update-backup" / datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backed_up = []
    temporary_base_tag = ""
    try:
        expected_name = f"FabricNavigator-Update-{requested}.zip"
        archive = work / expected_name
        if request.get("source") == "offline":
            supplied_name = request.get("file", "")
            digest_match = re.fullmatch(r"sha256:([0-9a-fA-F]{64})", request.get("assetDigest", ""))
            if supplied_name != expected_name or not digest_match:
                raise RuntimeError("The offline update request is invalid.")
            source = (OFFLINE / supplied_name).resolve()
            if OFFLINE.resolve() not in source.parents or not source.is_file():
                raise RuntimeError("The staged offline update was not found.")
            status("validating", requested, "The local offline update is being verified.")
            shutil.copy2(source, archive)
            expected_hash = digest_match.group(1).lower()
            actual = hashlib.sha256(archive.read_bytes()).hexdigest()
        else:
            settings = properties(ROOT / ".env")
            repository = settings.get("FABRICNAVIGATOR_GITHUB_REPOSITORY", "")
            if not REPOSITORY_RE.fullmatch(repository):
                raise RuntimeError("FABRICNAVIGATOR_GITHUB_REPOSITORY is not configured.")
            auth = token(settings)
            release = github_json(
                f"https://api.github.com/repos/{repository}/releases/tags/v{requested}", auth
            )
            release_version = str(release.get("tag_name", "")).lstrip("v")
            if release_version != requested:
                raise RuntimeError(f"GitHub returned version {release_version}, not {requested}.")
            if release.get("draft"):
                raise RuntimeError("The requested GitHub release is still a draft.")
            if release.get("prerelease") and channel != "beta":
                raise RuntimeError("A prerelease cannot be installed from the stable update channel.")
            expected_names = {expected_name, f"fabricnavigator-update-{requested}.zip"}
            asset = next((item for item in release.get("assets", []) if item.get("name") in expected_names), None)
            if not asset or not str(asset.get("id", "")).isdigit():
                raise RuntimeError("The release has no FabricNavigator update archive.")
            digest_match = re.fullmatch(r"sha256:([0-9a-fA-F]{64})", str(asset.get("digest", "")))
            if not digest_match:
                raise RuntimeError("GitHub did not provide a valid SHA-256 digest.")
            expected_hash = digest_match.group(1).lower()
            status("downloading", requested, "Update is being downloaded from GitHub.")
            actual = download_asset(f"https://api.github.com/repos/{repository}/releases/assets/{asset['id']}", archive, auth)
        if actual.lower() != expected_hash:
            raise RuntimeError("The update archive SHA-256 verification failed.")
        stage = work / "stage"
        stage.mkdir()
        safe_extract(archive, stage)
        runtime = stage / "runtime"
        image = runtime / f"FabricNavigator-Image-{requested}.tar.gz"
        core_overlay = runtime / "core-overlay"
        compose = runtime / "compose.yaml"
        has_full_image = image.is_file()
        has_core_overlay = (core_overlay / "Dockerfile").is_file() and (core_overlay / "manifest.properties").is_file()
        if (not has_full_image and not has_core_overlay) or not compose.is_file():
            raise RuntimeError("The update archive does not contain the expected runtime structure.")

        backup.mkdir(parents=True)
        for source in runtime.iterdir():
            if source.is_file() and source != image:
                destination = ROOT / source.name
                if destination.exists():
                    shutil.copy2(destination, backup / source.name)
                    backed_up.append(source.name)
        if has_full_image:
            status("installing", requested, "The full image and runtime files are being installed.")
            run("docker", "load", "--input", str(image))
        else:
            manifest = properties(core_overlay / "manifest.properties")
            if manifest.get("format") != "core-overlay-v1" or manifest.get("targetVersion") != requested:
                raise RuntimeError("The core update manifest is invalid.")
            current_image = subprocess.run(
                ["docker", "inspect", "fabricnavigator", "--format", "{{.Config.Image}}"],
                check=True,
                text=True,
                stdout=subprocess.PIPE,
            ).stdout.strip()
            if not current_image:
                raise RuntimeError("The currently running FabricNavigator image could not be determined.")
            image_available = subprocess.run(
                ["docker", "image", "inspect", current_image],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ).returncode == 0
            if not image_available:
                image_id = subprocess.run(
                    ["docker", "inspect", "fabricnavigator", "--format", "{{.Image}}"],
                    check=True,
                    text=True,
                    stdout=subprocess.PIPE,
                ).stdout.strip()
                if not image_id:
                    raise RuntimeError("The running FabricNavigator image ID could not be determined.")
                temporary_base_tag = f"fabricnavigator:update-base-{os.getpid()}"
                run("docker", "tag", image_id, temporary_base_tag)
                current_image = temporary_base_tag
            status("installing", requested, "The small core update is being applied to the existing image locally.")
            run(
                "docker", "build",
                "--build-arg", f"BASE_IMAGE={current_image}",
                "--tag", f"fabricnavigator:{requested}",
                str(core_overlay),
            )
        for source in runtime.iterdir():
            if source.is_file() and source != image:
                shutil.copy2(source, ROOT / source.name)
        compose_up()
        healthcheck()
        if request.get("source") == "offline":
            (OFFLINE / expected_name).unlink(missing_ok=True)
            OFFLINE_STATUS.unlink(missing_ok=True)
        status("success", requested, "Update installed successfully.")
        return (ROOT / "fabricnavigator-updater.py").is_file()
    except Exception as error:
        status("rollback", requested, str(error))
        for name in backed_up:
            shutil.copy2(backup / name, ROOT / name)
        try:
            compose_up()
        except Exception:
            pass
        status("error", requested, "Update failed; the previous runtime configuration was restored. " + str(error))
        raise
    finally:
        if temporary_base_tag:
            subprocess.run(
                ["docker", "image", "rm", temporary_base_tag],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        shutil.rmtree(work, ignore_errors=True)


def plugin_status(state, version="", message=""):
    atomic_text(
        PLUGIN_STATUS,
        f"state={clean(state)}\nversion={clean(version)}\n"
        f"updatedAt={datetime.datetime.now(datetime.timezone.utc).isoformat()}\nmessage={clean(message)}\n",
    )


def install_plugin(request):
    version = request.get("version", "")
    filename = request.get("file", "")
    digest_match = re.fullmatch(r"sha256:([0-9a-fA-F]{64})", request.get("digest", ""))
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", version) or filename != f"FabricNavigator-Extreme-Device-Images-{version}.zip" or not digest_match:
        raise RuntimeError("The device-image package request is invalid.")
    source = (OFFLINE / filename).resolve()
    if OFFLINE.resolve() not in source.parents or not source.is_file():
        raise RuntimeError("The staged device-image package was not found.")
    if hashlib.sha256(source.read_bytes()).hexdigest().lower() != digest_match.group(1).lower():
        raise RuntimeError("The device-image package SHA-256 verification failed.")
    work = Path(tempfile.mkdtemp(prefix="fabricnavigator-images-", dir="/var/tmp"))
    backup = ROOT / ".plugin-backup" / datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    try:
        plugin_status("installing", version, "Device images are being installed.")
        safe_extract(source, work)
        staged = work / "plugin"
        manifest_path = staged / "plugin.json"
        if not manifest_path.is_file():
            raise RuntimeError("The device-image package has no plugin manifest.")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if manifest.get("id") != "extreme-device-images" or str(manifest.get("version", "")) != version:
            raise RuntimeError("The device-image plugin manifest is invalid.")
        if not any(staged.glob("*.png")):
            raise RuntimeError("The package contains no device images.")
        PLUGIN_DESTINATION.parent.mkdir(parents=True, exist_ok=True)
        if PLUGIN_DESTINATION.exists():
            backup.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(PLUGIN_DESTINATION, backup)
            shutil.rmtree(PLUGIN_DESTINATION)
        shutil.copytree(staged, PLUGIN_DESTINATION)
        source.unlink(missing_ok=True)
        plugin_status("installed", version, "Device images installed successfully.")
    except Exception:
        if backup.exists():
            shutil.rmtree(PLUGIN_DESTINATION, ignore_errors=True)
            shutil.copytree(backup, PLUGIN_DESTINATION)
        raise
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main():
    STATE.mkdir(parents=True, exist_ok=True)
    if ensure_updater_service_definition():
        return
    # os.execv() replaces the updater process after a successful self-update,
    # so the old process cannot run its finally block. Remove the processing
    # marker left by that controlled restart before publishing "waiting".
    REQUEST.with_suffix(".processing").unlink(missing_ok=True)
    # Docker may remap container uid 0. Permit creation of known request files
    # without allowing unprivileged guest users to list the directory. Status
    # files remain readable, while the final token is stored elsewhere as 0600.
    os.chmod(STATE, 0o733)
    status("waiting", message="Linux updater is waiting for an approved update.")
    github_token_status("configured" if GITHUB_TOKEN_DESTINATION.is_file() else "not-configured", GITHUB_TOKEN_DESTINATION.is_file())
    write_host_route_snapshot()
    last_route_signature = None
    last_snapshot = time.monotonic()
    while True:
        process_github_token_request()
        if HOST_NETWORK_REQUEST.is_file():
            try:
                process_host_network_request()
            except Exception as error:
                print(f"FabricNavigator host network action failed: {error}", flush=True)
        if SYSTEM_ACTION_REQUEST.is_file():
            try:
                process_system_action_request()
            except Exception as error:
                print(f"FabricNavigator system action failed: {error}", flush=True)
        if HOST_ROUTES.is_file():
            route_signature = (HOST_ROUTES.stat().st_mtime_ns, HOST_ROUTES.stat().st_size)
            if route_signature != last_route_signature:
                last_route_signature = reconcile_host_routes()
        if time.monotonic() - last_snapshot >= 10:
            write_host_route_snapshot()
            write_host_network_snapshot()
            last_snapshot = time.monotonic()
        if REQUEST.is_file():
            processing = REQUEST.with_suffix(".processing")
            try:
                os.replace(REQUEST, processing)
                restart_updater = install(properties(processing, java_escaped=True))
                if restart_updater:
                    processing.unlink(missing_ok=True)
                    os.execv(
                        "/usr/bin/python3",
                        ["/usr/bin/python3", str(ROOT / "fabricnavigator-updater.py")],
                    )
            except Exception as error:
                print(f"FabricNavigator update failed: {error}", flush=True)
            finally:
                processing.unlink(missing_ok=True)
        if PLUGIN_REQUEST.is_file():
            processing = PLUGIN_REQUEST.with_suffix(".processing")
            try:
                os.replace(PLUGIN_REQUEST, processing)
                request = properties(processing, java_escaped=True)
                install_plugin(request)
            except Exception as error:
                plugin_status("error", request.get("version", "") if 'request' in locals() else "", error)
                print(f"FabricNavigator device-image installation failed: {error}", flush=True)
            finally:
                processing.unlink(missing_ok=True)
        time.sleep(1)


if __name__ == "__main__":
    main()
