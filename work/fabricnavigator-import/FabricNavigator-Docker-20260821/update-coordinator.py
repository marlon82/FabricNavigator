#!/usr/bin/env python3
"""GitHub release checker for FabricNavigator.

The coordinator deliberately cannot control Docker. It retrieves release
metadata and writes a small status file consumed by the admin UI. Private
public repositories are accessed anonymously. An optional read-only token can
be mounted from the Windows host for private forks or authenticated API limits;
the token is never copied into the image or written to status and log output. A
separate Windows host updater performs an independently verified installation.
"""

import base64
import hashlib
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


STATE_DIR = Path(os.environ.get("FABRICNAVIGATOR_UPDATE_DIR", "/opt/fabricnavigator/update"))
REPOSITORY = os.environ.get("FABRICNAVIGATOR_GITHUB_REPOSITORY", "").strip()
TOKEN_FILE = Path(os.environ.get(
    "FABRICNAVIGATOR_GITHUB_TOKEN_FILE",
    "/run/secrets/github-update-token.txt",
))
ALLOW_TOKEN_WRITE = os.environ.get(
    "FABRICNAVIGATOR_ALLOW_TOKEN_WRITE", "false"
).strip().lower() in ("1", "true", "yes")
CURRENT_VERSION = os.environ.get("FABRICNAVIGATOR_VERSION", "0.0.0.0").strip()
CHECK_REQUEST = STATE_DIR / "check.request"
UPDATE_SETTINGS_FILE = STATE_DIR / "update-settings.properties"
TOKEN_REQUEST = STATE_DIR / "github-token.request"
TOKEN_STATUS_FILE = STATE_DIR / "github-token-status.properties"
TLS_REQUEST = STATE_DIR / "tls-certificate.request"
TLS_STATUS_FILE = STATE_DIR / "tls-certificate-status.properties"
TLS_DIR = Path(os.environ.get("FABRICNAVIGATOR_TLS_DIR", "/etc/nginx/tls"))
TLS_CERT_FILE = TLS_DIR / "fabricnavigator.crt"
TLS_KEY_FILE = TLS_DIR / "fabricnavigator.key"
STATUS_FILE = STATE_DIR / "status.properties"
NOTES_FILE = STATE_DIR / "release-notes.txt"
ACLI_CHECK_REQUEST = STATE_DIR / "acli-check.request"
ACLI_INSTALL_REQUEST = STATE_DIR / "acli-install.request"
ACLI_STATUS_FILE = STATE_DIR / "acli-status.properties"
ACLI_SOURCE_DIR = Path(os.environ.get("FABRICNAVIGATOR_ACLI_SOURCE_DIR", "/opt/acli"))
ACLI_COMPONENT_DIR = Path(os.environ.get(
    "FABRICNAVIGATOR_ACLI_COMPONENT_DIR",
    "/opt/fabricnavigator/data/acli-component",
))
ACLI_CURRENT_DIR = ACLI_COMPONENT_DIR / "current"
ACLI_RELEASE_API = "https://api.github.com/repos/lgastevens/ACLI-terminal/releases/tags/updates"
ACLI_RUNTIME_FILES = {
    "acli.pl", "acli.alias", "aftp.pl", "grep.pl", "snmp.run", "cfm-test.pl",
    "acli.ini", "termtest.pl", "acmd.pl", "acli.sed", "spb-ect.pl", "acli.spawn",
    "ERS.dict", "rosetta.pl", "boss.c2j", "boss.j2c", "voss.c2j", "voss-cvlan.j2c",
    "voss-swuni.j2c", "exos.c2j", "exos.j2c", "tunimx.pl",
}
ACLI_VERSION_RE = re.compile(r"(?:our|my)?\s*\$Version\s*=\s*[\"']([0-9]+(?:\.[0-9]+)+(?:_[0-9]+)?)[\"']", re.I)
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
VERSION_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)\.(\d+)$")
TOKEN_RE = re.compile(r"^[A-Za-z0-9_]{20,512}$")
GITHUB_ATTEMPTS = 4
GITHUB_RETRY_DELAYS = (1, 2, 4)
PKCS12_MAX_BYTES = 512 * 1024


def version_tuple(value):
    match = VERSION_RE.fullmatch((value or "").strip())
    return tuple(int(part) for part in match.groups()) if match else None


def read_github_token():
    """Read the host-mounted token without ever exposing its value."""
    try:
        if not TOKEN_FILE.is_file():
            return ""
        token = TOKEN_FILE.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise RuntimeError("The GitHub token file cannot be read: %s" % error)
    if not TOKEN_RE.fullmatch(token):
        raise RuntimeError("The GitHub token file has an invalid format.")
    return token


def atomic_text(path, value):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=str(STATE_DIR))
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(value)
        # These files contain only UI status and public release metadata.
        # Tomcat runs as an unprivileged user and must be able to read them.
        # Secrets use dedicated write paths and remain mode 0600.
        try:
            os.chmod(temporary, 0o644)
        except OSError:
            pass
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def property_value(value):
    return str(value or "").replace("\\", "\\\\").replace("\r", "").replace("\n", "\\n")


def write_status(**values):
    defaults = {
        "state": "idle",
        "repository": REPOSITORY,
        "currentVersion": CURRENT_VERSION,
        "latestVersion": "",
        "updateAvailable": "false",
        "releaseUrl": "",
        "assetName": "",
        "assetUrl": "",
        "assetDigest": "",
        "assetSize": "0",
        "publishedAt": "",
        "checkedAt": str(int(time.time())),
        "checkedAtMillis": str(int(time.time() * 1000)),
        "message": "",
    }
    defaults.update(values)
    content = "".join("%s=%s\n" % (key, property_value(value)) for key, value in defaults.items())
    atomic_text(STATUS_FILE, content)


def write_token_status(state, configured, message=""):
    content = (
        "state=%s\nconfigured=%s\nupdatedAt=%s\nmessage=%s\n"
        % (
            property_value(state),
            "true" if configured else "false",
            time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            property_value(message),
        )
    )
    atomic_text(TOKEN_STATUS_FILE, content)


def decode_java_property(value):
    """Decode the escapes emitted by java.util.Properties.store()."""
    decoded = []
    index = 0
    escapes = {"t": "\t", "n": "\n", "r": "\r", "f": "\f"}
    while index < len(value):
        character = value[index]
        if character != "\\" or index + 1 >= len(value):
            decoded.append(character)
            index += 1
            continue
        escaped = value[index + 1]
        if escaped == "u" and index + 5 < len(value):
            digits = value[index + 2:index + 6]
            if re.fullmatch(r"[0-9A-Fa-f]{4}", digits):
                decoded.append(chr(int(digits, 16)))
                index += 6
                continue
        decoded.append(escapes.get(escaped, escaped))
        index += 2
    return "".join(decoded)


def read_simple_properties(path):
    values = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith(("#", "!")) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[decode_java_property(key.strip())] = decode_java_property(value.strip())
    return values


def automatic_update_check_enabled():
    """Keep the historical six-hour check enabled unless an admin disables it."""
    if not UPDATE_SETTINGS_FILE.is_file():
        return True
    try:
        value = read_simple_properties(UPDATE_SETTINGS_FILE).get("automaticCheck", "true")
        return value.strip().lower() in ("1", "true", "yes", "on")
    except (OSError, UnicodeError):
        return True


def update_channel():
    try:
        value = read_simple_properties(UPDATE_SETTINGS_FILE).get("channel", "stable")
    except (OSError, UnicodeError):
        value = "stable"
    return "beta" if value.strip().lower() == "beta" else "stable"


def process_token_request():
    """Handle token changes only in the explicitly enabled dev deployment."""
    if not ALLOW_TOKEN_WRITE or not TOKEN_REQUEST.is_file():
        return
    processing = TOKEN_REQUEST.with_name(TOKEN_REQUEST.name + ".processing")
    try:
        os.replace(TOKEN_REQUEST, processing)
        request = read_simple_properties(processing)
        action = request.get("action", "")
        if action == "install":
            token = request.get("token", "")
            if not TOKEN_RE.fullmatch(token):
                raise RuntimeError("The GitHub token has an invalid format.")
            TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
            descriptor, temporary = tempfile.mkstemp(
                prefix=TOKEN_FILE.name + ".", dir=str(TOKEN_FILE.parent)
            )
            try:
                with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
                    handle.write(token)
                try:
                    os.chmod(temporary, 0o600)
                except OSError:
                    pass
                os.replace(temporary, TOKEN_FILE)
            finally:
                try:
                    os.unlink(temporary)
                except FileNotFoundError:
                    pass
            write_token_status(
                "configured", True,
                "GitHub token was stored in the local development host bind mount.",
            )
        elif action == "remove":
            try:
                TOKEN_FILE.unlink()
            except FileNotFoundError:
                pass
            write_token_status(
                "removed", False,
                "GitHub token was removed from the local development host bind mount.",
            )
        else:
            raise RuntimeError("Unknown GitHub token action.")
    except Exception as error:
        write_token_status("error", TOKEN_FILE.is_file(), str(error)[:500])
    finally:
        try:
            processing.unlink()
        except FileNotFoundError:
            pass


def write_tls_status(state, configured, message="", details=None):
    values = {
        "state": state,
        "configured": "true" if configured else "false",
        "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "message": message,
    }
    if details:
        values.update(details)
    atomic_text(
        TLS_STATUS_FILE,
        "".join("%s=%s\n" % (key, property_value(value)) for key, value in values.items()),
    )


def run_command(arguments, timeout=20, allow_failure=False):
    completed = subprocess.run(
        arguments,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
        timeout=timeout,
    )
    if completed.returncode and not allow_failure:
        detail = (completed.stderr or completed.stdout or "Command failed.").strip()
        raise RuntimeError(detail[:500])
    return completed


def pkcs12_command(arguments):
    completed = run_command(["openssl", "pkcs12"] + arguments, allow_failure=True)
    if completed.returncode:
        completed = run_command(
            ["openssl", "pkcs12", "-legacy"] + arguments,
            allow_failure=True,
        )
    if completed.returncode:
        detail = (completed.stderr or completed.stdout or "PKCS#12 processing failed.").strip()
        raise RuntimeError(detail[:500])


def pem_certificates(path):
    text = path.read_text(encoding="utf-8", errors="replace")
    return re.findall(
        r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
        text,
        flags=re.DOTALL,
    )


def pem_private_keys(path):
    text = path.read_text(encoding="utf-8", errors="replace")
    return re.findall(
        r"-----BEGIN (?:RSA |EC )?PRIVATE KEY-----.*?-----END (?:RSA |EC )?PRIVATE KEY-----",
        text,
        flags=re.DOTALL,
    )


def certificate_details(path):
    def field(option, prefix=""):
        value = run_command(["openssl", "x509", "-in", str(path), "-noout", option]).stdout.strip()
        return value[len(prefix):].strip() if prefix and value.startswith(prefix) else value

    san_result = run_command(
        ["openssl", "x509", "-in", str(path), "-noout", "-ext", "subjectAltName"],
        allow_failure=True,
    )
    sans = ""
    if san_result.returncode == 0:
        sans = " ".join(line.strip() for line in san_result.stdout.splitlines()[1:]).strip()
    fingerprint = run_command(
        ["openssl", "x509", "-in", str(path), "-noout", "-sha256", "-fingerprint"]
    ).stdout.strip()
    return {
        "subject": field("-subject", "subject="),
        "issuer": field("-issuer", "issuer="),
        "notAfter": field("-enddate", "notAfter="),
        "fingerprint": fingerprint.replace("sha256 Fingerprint=", "").replace("SHA256 Fingerprint=", ""),
        "sans": sans,
        "previousAvailable": "true" if (TLS_DIR / "fabricnavigator.crt.previous").is_file() and (TLS_DIR / "fabricnavigator.key.previous").is_file() else "false",
    }


def process_tls_request():
    if not TLS_REQUEST.is_file():
        return
    processing = TLS_REQUEST.with_name(TLS_REQUEST.name + ".processing")
    work_directory = None
    previous_cert = TLS_DIR / "fabricnavigator.crt.previous"
    previous_key = TLS_DIR / "fabricnavigator.key.previous"
    replaced = False
    try:
        os.replace(TLS_REQUEST, processing)
        request = read_simple_properties(processing)
        action = request.get("action")
        if action == "factory-reset":
            TLS_DIR.mkdir(parents=True, exist_ok=True)
            work_directory = Path(tempfile.mkdtemp(prefix=".fabricnavigator-tls-reset-", dir=str(TLS_DIR)))
            new_cert = work_directory / "fabricnavigator.crt"
            new_key = work_directory / "fabricnavigator.key"
            openssl_config = work_directory / "openssl.cnf"
            openssl_config.write_text(
                "[req]\n"
                "distinguished_name=subject\n"
                "x509_extensions=extensions\n"
                "prompt=no\n"
                "[subject]\n"
                "CN=FabricNavigator\n"
                "O=FabricNavigator\n"
                "[extensions]\n"
                "subjectAltName=@alternative_names\n"
                "keyUsage=critical,digitalSignature,keyEncipherment\n"
                "extendedKeyUsage=serverAuth\n"
                "basicConstraints=critical,CA:false\n"
                "[alternative_names]\n"
                "DNS.1=localhost\n"
                "DNS.2=fabricnavigator\n"
                "IP.1=127.0.0.1\n",
                encoding="ascii",
            )
            run_command([
                "openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048",
                "-sha256", "-days", "825", "-config", str(openssl_config),
                "-keyout", str(new_key), "-out", str(new_cert),
            ])
            os.chmod(new_cert, 0o644)
            os.chmod(new_key, 0o600)
            current_cert = work_directory / "current.crt"
            current_key = work_directory / "current.key"
            if TLS_CERT_FILE.is_file():
                shutil.copy2(TLS_CERT_FILE, current_cert)
            if TLS_KEY_FILE.is_file():
                shutil.copy2(TLS_KEY_FILE, current_key)
            try:
                os.replace(new_cert, TLS_CERT_FILE)
                os.replace(new_key, TLS_KEY_FILE)
                run_command(["nginx", "-t"])
                run_command(["nginx", "-s", "reload"])
            except Exception:
                if current_cert.is_file():
                    shutil.copy2(current_cert, TLS_CERT_FILE)
                if current_key.is_file():
                    shutil.copy2(current_key, TLS_KEY_FILE)
                raise
            for previous in (previous_cert, previous_key):
                try:
                    previous.unlink()
                except FileNotFoundError:
                    pass
            write_tls_status(
                "active", True, "The factory-default self-signed web server certificate is active.",
                certificate_details(TLS_CERT_FILE),
            )
            return
        if action == "restore":
            if not previous_cert.is_file() or not previous_key.is_file():
                raise RuntimeError("No previous TLS certificate is available.")
            shutil.copy2(previous_cert, TLS_CERT_FILE)
            shutil.copy2(previous_key, TLS_KEY_FILE)
            os.chmod(TLS_CERT_FILE, 0o644)
            os.chmod(TLS_KEY_FILE, 0o600)
            run_command(["nginx", "-t"])
            run_command(["nginx", "-s", "reload"])
            write_tls_status(
                "active", True, "The previous web server certificate was restored.",
                certificate_details(TLS_CERT_FILE),
            )
            return
        if action != "install":
            raise RuntimeError("Unknown TLS certificate action.")
        try:
            bundle = base64.b64decode(request.get("pkcs12", ""), validate=True)
            password = base64.b64decode(request.get("password", ""), validate=True).decode("utf-8")
        except (ValueError, UnicodeError) as error:
            raise RuntimeError("The PKCS#12 upload is not valid Base64 or UTF-8.") from error
        if not bundle or len(bundle) > PKCS12_MAX_BYTES:
            raise RuntimeError("The PKCS#12 file is empty or exceeds 512 KiB.")

        TLS_DIR.mkdir(parents=True, exist_ok=True)
        work_directory = Path(tempfile.mkdtemp(prefix=".fabricnavigator-tls-", dir=str(TLS_DIR)))
        bundle_file = work_directory / "certificate.p12"
        password_file = work_directory / "password.txt"
        raw_cert = work_directory / "certificate.raw.pem"
        raw_key = work_directory / "key.raw.pem"
        raw_chain = work_directory / "chain.raw.pem"
        new_cert = work_directory / "fabricnavigator.crt"
        new_key = work_directory / "fabricnavigator.key"
        bundle_file.write_bytes(bundle)
        password_file.write_text(password, encoding="utf-8")
        os.chmod(bundle_file, 0o600)
        os.chmod(password_file, 0o600)
        passin = "file:" + str(password_file)
        pkcs12_command(["-in", str(bundle_file), "-clcerts", "-nokeys", "-out", str(raw_cert), "-passin", passin])
        pkcs12_command(["-in", str(bundle_file), "-nocerts", "-nodes", "-out", str(raw_key), "-passin", passin])
        chain_result = run_command(
            ["openssl", "pkcs12", "-in", str(bundle_file), "-cacerts", "-nokeys", "-out", str(raw_chain), "-passin", passin],
            allow_failure=True,
        )
        if chain_result.returncode:
            raw_chain.write_text("", encoding="utf-8")

        certificates = pem_certificates(raw_cert)
        keys = pem_private_keys(raw_key)
        if len(certificates) != 1 or len(keys) != 1:
            raise RuntimeError("The PKCS#12 file must contain exactly one leaf certificate and one private key.")
        chain = pem_certificates(raw_chain)
        new_cert.write_text("\n".join(certificates + chain) + "\n", encoding="ascii")
        new_key.write_text(keys[0] + "\n", encoding="ascii")
        os.chmod(new_cert, 0o644)
        os.chmod(new_key, 0o600)

        run_command(["openssl", "x509", "-in", str(new_cert), "-noout", "-checkend", "0"])
        new_certificate_details = certificate_details(new_cert)
        if not new_certificate_details.get("issuer", "").strip():
            raise RuntimeError(
                "The certificate has no issuer and cannot be validated by Windows clients. "
                "Issue the server certificate from the trusted root or intermediate CA."
            )
        cert_public_key = run_command(["openssl", "x509", "-in", str(new_cert), "-pubkey", "-noout"]).stdout.strip()
        private_public_key = run_command(["openssl", "pkey", "-in", str(new_key), "-pubout"]).stdout.strip()
        if cert_public_key != private_public_key:
            raise RuntimeError("The private key does not match the certificate.")

        if TLS_CERT_FILE.is_file():
            shutil.copy2(TLS_CERT_FILE, previous_cert)
        if TLS_KEY_FILE.is_file():
            shutil.copy2(TLS_KEY_FILE, previous_key)
        os.replace(new_cert, TLS_CERT_FILE)
        os.replace(new_key, TLS_KEY_FILE)
        replaced = True
        run_command(["nginx", "-t"])
        run_command(["nginx", "-s", "reload"])
        details = certificate_details(TLS_CERT_FILE)
        write_tls_status("active", True, "The uploaded PKCS#12 certificate is active.", details)
    except Exception as error:
        if replaced:
            try:
                if previous_cert.is_file():
                    shutil.copy2(previous_cert, TLS_CERT_FILE)
                if previous_key.is_file():
                    shutil.copy2(previous_key, TLS_KEY_FILE)
                run_command(["nginx", "-t"])
                run_command(["nginx", "-s", "reload"])
            except Exception:
                pass
        details = certificate_details(TLS_CERT_FILE) if TLS_CERT_FILE.is_file() else {}
        write_tls_status("error", TLS_CERT_FILE.is_file(), str(error)[:500], details)
    finally:
        try:
            processing.unlink()
        except FileNotFoundError:
            pass
        if work_directory:
            shutil.rmtree(str(work_directory), ignore_errors=True)


def acli_version_tuple(value):
    parts = re.split(r"[._]", str(value or ""))
    return tuple(int(part) for part in parts) if parts and all(part.isdigit() for part in parts) else None


def acli_local_path(root, filename, remote_path=""):
    if filename == "acli.pl":
        return root / "acli-terminal.pl"
    if remote_path.replace("\\", "/").strip("/") == "AcliPm":
        return root / "AcliPm" / filename
    return root / filename


def acli_file_version(path):
    try:
        text = path.read_text(encoding="utf-8", errors="replace")[:65536]
    except OSError:
        return ""
    match = ACLI_VERSION_RE.search(text)
    if match:
        return match.group(1)
    for pattern in (
        r"(?im)^\s*\$Version\s*=\s*([0-9]+(?:\.[0-9]+)+(?:_[0-9]+)?)\s*$",
        r"(?im)^\s*[#;']\s*VERSION\s*=\s*([0-9]+(?:\.[0-9]+)+(?:_[0-9]+)?)\s*$",
        r"(?im)^\s*#\s*Version\s+([0-9]+(?:\.[0-9]+)+(?:_[0-9]+)?)\s*$",
    ):
        match = re.search(pattern, text)
        if match:
            return match.group(1)
    return "unknown" if path.is_file() else ""


def acli_runtime_entry(filename, remote_path):
    normalized = remote_path.replace("\\", "/").strip("/")
    return (normalized == "AcliPm" and filename.endswith(".pm")) or (
        not normalized and filename in ACLI_RUNTIME_FILES
    )


def parse_acli_digest(text):
    if isinstance(text, bytes):
        text = text.decode("utf-8", errors="replace")
    entries = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line in ("UPDATES-ARE-ZIPPED",):
            continue
        if line.startswith(("ACLI-Install", "Strawberry Perl", "DISTRIBUTION VERSION DIGEST")):
            continue
        match = re.match(r"^(\S+)\s+([0-9]+(?:\.[0-9]+)+(?:_[0-9]+)?)(?:\s+(.+?))?\s*$", line)
        if not match:
            continue
        filename, version, remote_path = match.group(1), match.group(2), (match.group(3) or "").strip()
        if Path(filename).name != filename or not re.fullmatch(r"[A-Za-z0-9_.-]+", filename):
            raise RuntimeError("The ACLI update digest contains an unsafe filename.")
        if acli_runtime_entry(filename, remote_path):
            entries.append({"file": filename, "version": version, "path": remote_path})
    if not any(entry["file"] == "acli.pl" for entry in entries):
        raise RuntimeError("The ACLI update digest contains no ACLI runtime entry.")
    return entries


def acli_headers():
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "FabricNavigator-ACLI-Updater/%s" % CURRENT_VERSION,
        "X-GitHub-Api-Version": "2022-11-28",
    }
    token = read_github_token()
    if token:
        headers["Authorization"] = "Bearer " + token
    return headers


def acli_download(url, headers, maximum=4 * 1024 * 1024):
    last_error = None
    for attempt in range(GITHUB_ATTEMPTS):
        try:
            request = urllib.request.Request(url, headers=headers)
            context = ssl.create_default_context()
            with urllib.request.urlopen(request, timeout=45, context=context) as response:
                data = response.read(maximum + 1)
            if len(data) > maximum:
                raise RuntimeError("An ACLI update asset exceeds the permitted size.")
            return data
        except urllib.error.HTTPError as error:
            if error.code in (401, 403, 404):
                raise RuntimeError("The ACLI update asset is unavailable (HTTP %s)." % error.code)
            last_error = "GitHub returned HTTP %s for an ACLI asset." % error.code
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            last_error = "The ACLI asset download failed: %s" % error
        if attempt < GITHUB_ATTEMPTS - 1:
            time.sleep(GITHUB_RETRY_DELAYS[attempt])
    raise RuntimeError("%s Retried %s times." % (last_error, GITHUB_ATTEMPTS))


def verified_acli_asset(asset, headers, maximum=4 * 1024 * 1024):
    digest = str(asset.get("digest") or "")
    match = re.fullmatch(r"sha256:([0-9a-fA-F]{64})", digest)
    if not match:
        raise RuntimeError("GitHub provides no SHA-256 digest for %s." % asset.get("name", "asset"))
    data = acli_download(str(asset.get("browser_download_url") or ""), headers, maximum)
    if hashlib.sha256(data).hexdigest().lower() != match.group(1).lower():
        raise RuntimeError("The SHA-256 validation failed for %s." % asset.get("name", "asset"))
    return data


def acli_release_metadata():
    headers = acli_headers()
    request = urllib.request.Request(ACLI_RELEASE_API, headers=headers)
    release = load_github_json(request, ssl.create_default_context())
    assets = {str(asset.get("name") or ""): asset for asset in release.get("assets") or []}
    digest_asset = assets.get("update.digest")
    if not digest_asset:
        raise RuntimeError("The ACLI updates release contains no update.digest asset.")
    digest_text = verified_acli_asset(digest_asset, headers, 512 * 1024).decode("utf-8")
    return release, assets, parse_acli_digest(digest_text), headers


def acli_installed_root():
    marker = ACLI_CURRENT_DIR / "component.properties"
    return ACLI_CURRENT_DIR if marker.is_file() else ACLI_SOURCE_DIR


def acli_pending(entries, root=None):
    root = root or acli_installed_root()
    pending = []
    for entry in entries:
        installed = acli_file_version(acli_local_path(root, entry["file"], entry["path"]))
        installed_version = acli_version_tuple(installed)
        available_version = acli_version_tuple(entry["version"])
        if available_version and (installed_version is None or installed_version < available_version):
            item = dict(entry)
            item["installed"] = installed
            pending.append(item)
    return pending


def write_acli_status(state="idle", message="", entries=None, release=None):
    entries = entries or []
    installed_root = acli_installed_root()
    installed_main = acli_file_version(acli_local_path(installed_root, "acli.pl"))
    available_main = installed_main
    for entry in entries:
        if entry.get("file") == "acli.pl":
            available_main = entry.get("version", installed_main)
            break
    serialized = ";".join(
        "%s|%s|%s" % (entry.get("file", ""), entry.get("installed", ""), entry.get("version", ""))
        for entry in entries
    )
    values = {
        "state": state,
        "installedVersion": installed_main,
        "availableVersion": available_main,
        "updateAvailable": "true" if entries else "false",
        "updateCount": str(len(entries)),
        "updates": serialized,
        "releaseUrl": str((release or {}).get("html_url") or ""),
        "publishedAt": str((release or {}).get("published_at") or ""),
        "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "message": message,
    }
    atomic_text(ACLI_STATUS_FILE, "".join(
        "%s=%s\n" % (key, property_value(value)) for key, value in values.items()
    ))


def check_acli_updates():
    release, _assets, entries, _headers = acli_release_metadata()
    pending = acli_pending(entries)
    message = (
        "%s ACLI runtime file(s) can be updated." % len(pending)
        if pending else "The installed ACLI runtime files are current."
    )
    write_acli_status("available" if pending else "current", message, pending, release)


def extract_single_acli_file(archive_data, filename):
    temporary = tempfile.SpooledTemporaryFile(max_size=4 * 1024 * 1024)
    temporary.write(archive_data)
    temporary.seek(0)
    with zipfile.ZipFile(temporary) as archive:
        candidates = []
        for info in archive.infolist():
            normalized = info.filename.replace("\\", "/")
            if normalized.startswith("/") or ".." in Path(normalized).parts:
                raise RuntimeError("The ACLI archive contains an unsafe path.")
            if not info.is_dir() and Path(normalized).name == filename:
                candidates.append(info)
        if len(candidates) != 1:
            raise RuntimeError("The ACLI archive for %s has an unexpected structure." % filename)
        if candidates[0].file_size > 2 * 1024 * 1024:
            raise RuntimeError("The ACLI file %s is unexpectedly large." % filename)
        return archive.read(candidates[0])


def apply_fabricnavigator_acli_compatibility(stage):
    main = stage / "acli-terminal.pl"
    text = main.read_text(encoding="utf-8")
    if "AutoDetect\t=> !$opt_n," in text:
        text = text.replace("AutoDetect\t=> !$opt_n,", "AutoDetect\t=> 1,", 1)
    elif "AutoDetect\t=> 1," not in text:
        raise RuntimeError("The ACLI auto-detection compatibility patch no longer applies.")
    main.write_text(text, encoding="utf-8", newline="\n")

    output_module = stage / "AcliPm" / "HandleDeviceOutput.pm"
    text = output_module.read_text(encoding="utf-8")
    call = "\t\tloadVarFile($db, defined $host_io->{BaseMAC} && $host_io->{PreviousMAC} eq $host_io->{BaseMAC}); # Read in stored variables if a new device"
    guarded = (
        "\t\teval {\n\t\t\tloadVarFile($db, defined $host_io->{BaseMAC} && "
        "$host_io->{PreviousMAC} eq $host_io->{BaseMAC}); # Read in stored variables if a new device\n"
        "\t\t};\n\t\tif ($@) {\n\t\t\tdebugMsg(1, \"Unable to load optional variable profile after discovery\\n\");\n\t\t}"
    )
    if call in text:
        text = text.replace(call, guarded, 1)
    elif "Unable to load optional variable profile after discovery" not in text:
        raise RuntimeError("The ACLI variable-profile compatibility patch no longer applies.")
    output_module.write_text(text, encoding="utf-8", newline="\n")


def install_acli_updates():
    release, assets, entries, headers = acli_release_metadata()
    pending = acli_pending(entries)
    if not pending:
        write_acli_status("current", "The installed ACLI runtime files are current.", [], release)
        return
    write_acli_status("downloading", "Downloading and validating ACLI component files.", pending, release)
    ACLI_COMPONENT_DIR.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix="acli-stage-", dir=str(ACLI_COMPONENT_DIR)))
    backup = ACLI_COMPONENT_DIR / "previous"
    old_current = None
    try:
        source = acli_installed_root()
        shutil.copytree(str(source), str(stage), dirs_exist_ok=True, symlinks=False)
        for entry in pending:
            asset_name = entry["file"].replace(".", "_") + ".zip"
            asset = assets.get(asset_name)
            if not asset:
                raise RuntimeError("The ACLI updates release contains no %s asset." % asset_name)
            content = extract_single_acli_file(verified_acli_asset(asset, headers), entry["file"])
            destination = acli_local_path(stage, entry["file"], entry["path"])
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(content)
        write_acli_status("validating", "Applying FabricNavigator compatibility patches and validating Perl syntax.", pending, release)
        apply_fabricnavigator_acli_compatibility(stage)
        completed = subprocess.run(
            ["/usr/bin/perl", "-I", str(stage), "-c", str(stage / "acli-terminal.pl")],
            cwd=str(stage), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, timeout=45, check=False,
        )
        if completed.returncode != 0:
            raise RuntimeError("ACLI Perl validation failed: %s" % completed.stdout.strip()[-600:])
        marker = stage / "component.properties"
        marker.write_text(
            "source=lgastevens/ACLI-terminal\nchannel=updates\ninstalledAt=%s\nfabricNavigatorVersion=%s\n"
            % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), CURRENT_VERSION),
            encoding="utf-8", newline="\n",
        )
        if backup.exists():
            shutil.rmtree(str(backup))
        if ACLI_CURRENT_DIR.exists():
            old_current = ACLI_CURRENT_DIR
            os.replace(str(ACLI_CURRENT_DIR), str(backup))
        os.replace(str(stage), str(ACLI_CURRENT_DIR))
        stage = None
        write_acli_status(
            "installed",
            "ACLI was updated successfully. New SSH sessions use the updated component.",
            [], release,
        )
    except Exception:
        if old_current is not None and not ACLI_CURRENT_DIR.exists() and backup.exists():
            os.replace(str(backup), str(ACLI_CURRENT_DIR))
        raise
    finally:
        if stage is not None:
            shutil.rmtree(str(stage), ignore_errors=True)


def process_acli_requests():
    if ACLI_CHECK_REQUEST.is_file():
        processing = ACLI_CHECK_REQUEST.with_name(ACLI_CHECK_REQUEST.name + ".processing")
        try:
            os.replace(str(ACLI_CHECK_REQUEST), str(processing))
            write_acli_status("checking", "Checking the ACLI component update manifest.")
            check_acli_updates()
        except Exception as error:
            write_acli_status("error", str(error)[:500])
        finally:
            try:
                processing.unlink()
            except FileNotFoundError:
                pass
    if ACLI_INSTALL_REQUEST.is_file():
        processing = ACLI_INSTALL_REQUEST.with_name(ACLI_INSTALL_REQUEST.name + ".processing")
        try:
            os.replace(str(ACLI_INSTALL_REQUEST), str(processing))
            write_acli_status("installing", "Preparing the ACLI component update.")
            install_acli_updates()
        except Exception as error:
            write_acli_status("error", str(error)[:500])
        finally:
            try:
                processing.unlink()
            except FileNotFoundError:
                pass


def release_asset(release, version):
    expected = {
        "FabricNavigator-Update-%s.zip" % version,
        "fabricnavigator-update-%s.zip" % version,
    }
    for asset in release.get("assets") or []:
        if asset.get("name") in expected:
            return asset
    return None


def load_github_json(request, context):
    """Load GitHub metadata and tolerate short DNS/network interruptions."""
    last_error = None
    for attempt in range(GITHUB_ATTEMPTS):
        try:
            with urllib.request.urlopen(request, timeout=20, context=context) as response:
                return json.loads(response.read(2 * 1024 * 1024).decode("utf-8"))
        except urllib.error.HTTPError as error:
            # Authentication and missing-repository errors cannot be healed by
            # retrying. Rate limits and GitHub server errors often can.
            if error.code in (401, 403, 404):
                raise RuntimeError(
                    "GitHub access failed, the API limit was reached, or the repository is not accessible (HTTP %s)."
                    % error.code
                )
            if error.code != 429 and error.code < 500:
                raise RuntimeError("GitHub returned HTTP %s." % error.code)
            last_error = "GitHub returned HTTP %s." % error.code
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            last_error = "GitHub release check failed: %s" % error
        except (ValueError, UnicodeError) as error:
            raise RuntimeError("GitHub returned invalid release metadata: %s" % error)
        if attempt < GITHUB_ATTEMPTS - 1:
            time.sleep(GITHUB_RETRY_DELAYS[attempt])
    raise RuntimeError("%s Retried %s times." % (last_error, GITHUB_ATTEMPTS))


def check_release():
    if not REPO_RE.fullmatch(REPOSITORY):
        write_status(state="not-configured", message="GitHub repository is not configured.")
        atomic_text(NOTES_FILE, "")
        return
    current = version_tuple(CURRENT_VERSION)
    if current is None:
        write_status(state="error", message="The installed version has an invalid format.")
        return
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "FabricNavigator-Updater/%s" % CURRENT_VERSION,
        "X-GitHub-Api-Version": "2026-03-10",
    }
    token = read_github_token()
    if token:
        headers["Authorization"] = "Bearer " + token
    channel = update_channel()
    request = urllib.request.Request(
        "https://api.github.com/repos/%s/releases?per_page=30" % REPOSITORY,
        headers=headers,
    )
    context = ssl.create_default_context()
    releases = load_github_json(request, context)
    candidates = []
    for candidate in releases if isinstance(releases, list) else []:
        if candidate.get("draft") or (channel == "stable" and candidate.get("prerelease")):
            continue
        parsed = version_tuple(str(candidate.get("tag_name") or ""))
        if parsed is not None:
            candidates.append((parsed, candidate))
    if not candidates:
        raise RuntimeError("No eligible GitHub release was found for the %s channel." % channel)
    release = max(candidates, key=lambda item: item[0])[1]
    tag = str(release.get("tag_name") or "").strip()
    latest = version_tuple(tag)
    if latest is None:
        raise RuntimeError("The latest GitHub release tag does not use the required version format.")
    # Keep the release tag's original zero padding. Asset names use the exact
    # externally visible version (for example 26.08.10.90), while integer
    # tuples are used only for version ordering.
    normalized = tag[1:] if tag.startswith("v") else tag
    asset = release_asset(release, normalized)
    digest = str((asset or {}).get("digest") or "")
    installable = bool(asset and re.fullmatch(r"sha256:[0-9a-fA-F]{64}", digest))
    available = latest > current
    message = ""
    if available and not installable:
        message = "The release has no installable update asset with a SHA-256 digest."
    atomic_text(NOTES_FILE, str(release.get("body") or "No release notes were provided.")[:200000])
    write_status(
        state="available" if available else "current",
        latestVersion=normalized,
        updateAvailable="true" if available and installable else "false",
        releaseUrl=str(release.get("html_url") or ""),
        assetName=str((asset or {}).get("name") or ""),
        assetUrl=str((asset or {}).get("browser_download_url") or ""),
        assetDigest=digest,
        assetSize=str((asset or {}).get("size") or 0),
        publishedAt=str(release.get("published_at") or ""),
        message=message,
        channel=channel,
        prerelease="true" if release.get("prerelease") else "false",
    )


def main():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(STATE_DIR, 0o777)
    except OSError:
        pass
    # Repair status files created by older builds with mkstemp's mode 0600.
    for readable_file in (
        STATUS_FILE, TOKEN_STATUS_FILE, TLS_STATUS_FILE, ACLI_STATUS_FILE, NOTES_FILE,
    ):
        if readable_file.is_file():
            try:
                os.chmod(readable_file, 0o644)
            except OSError:
                pass
    last_request = CHECK_REQUEST.stat().st_mtime_ns if CHECK_REQUEST.exists() else 0
    next_periodic = 0
    # Preserve the last completed result across coordinator/container restarts.
    # Replacing an existing result with "idle" creates a short race in which
    # the web UI can incorrectly report the installed version as current.
    if not STATUS_FILE.exists():
        write_status(state="idle" if REPOSITORY else "not-configured",
                     message="" if REPOSITORY else "GitHub repository is not configured.")
    if not ACLI_STATUS_FILE.exists():
        write_acli_status("idle", "ACLI has not been checked yet.")
    if not TLS_STATUS_FILE.exists() and TLS_CERT_FILE.is_file():
        try:
            write_tls_status(
                "active", True, "The current web server certificate is active.",
                certificate_details(TLS_CERT_FILE),
            )
        except Exception as error:
            write_tls_status("error", True, str(error)[:500])
    while True:
        try:
            process_token_request()
            process_tls_request()
            process_acli_requests()
            request_time = CHECK_REQUEST.stat().st_mtime_ns if CHECK_REQUEST.exists() else 0
            now = time.time()
            automatic_check = automatic_update_check_enabled()
            if not automatic_check:
                next_periodic = 0
            if request_time != last_request or (REPOSITORY and automatic_check and now >= next_periodic):
                last_request = request_time
                next_periodic = now + 21600
                write_status(state="checking")
                try:
                    check_release()
                except Exception as error:
                    write_status(state="error", updateAvailable="", message=str(error)[:500])
        except Exception as error:
            write_status(state="error", updateAvailable="", message=str(error)[:500])
        time.sleep(1)


if __name__ == "__main__":
    main()
