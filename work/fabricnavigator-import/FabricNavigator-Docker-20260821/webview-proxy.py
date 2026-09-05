#!/usr/bin/env python3
import http.client
import base64
import gzip
import ipaddress
import re
import ssl
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN = ("127.0.0.1", 8082)
PREFIX = "/webview-tunnel/"
HOP_HEADERS = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade"}
TEXT_TYPES = ("text/html", "text/css", "application/javascript", "text/javascript")
TICKET_DIR = "/opt/fabricnavigator/data/webview-tickets"
LOCAL_COOKIE_NAMES = {"FNWebTicket", "EDM_AUTH"}
DEVICE_COOKIE_NAMES = {}
DEVICE_COOKIE_LOCK = threading.Lock()
AUTO_LOGIN_ATTEMPTS = set()
AUTO_LOGIN_LOCK = threading.Lock()


def authenticated(cookie):
    connection = http.client.HTTPConnection("127.0.0.1", 8081, timeout=8)
    try:
        connection.request("GET", "/topology/", headers={"Cookie": cookie or ""})
        response = connection.getresponse()
        response.read()
        return response.status == 200
    except Exception:
        return False
    finally:
        connection.close()


def ticket_data(token, device):
    if not token or not re.fullmatch(r"[0-9a-f]{48}", token):
        return None
    try:
        with open(TICKET_DIR + "/" + token, "r", encoding="utf-8") as stream:
            lines = stream.read(8192).splitlines()
        if len(lines) < 2 or lines[0] != device or int(lines[1]) < int(time.time() * 1000):
            return None
        result = {"device": lines[0], "expires": int(lines[1]), "username": "", "password": ""}
        if len(lines) >= 4:
            result["username"] = base64.b64decode(lines[2]).decode("utf-8") if lines[2] else ""
            result["password"] = base64.b64decode(lines[3]).decode("utf-8") if lines[3] else ""
        return result
    except (OSError, ValueError, UnicodeError):
        return None


def valid_ticket(token, device):
    return ticket_data(token, device) is not None


def claim_autologin(token, device):
    key = (token, device)
    with AUTO_LOGIN_LOCK:
        if key in AUTO_LOGIN_ATTEMPTS:
            return False
        AUTO_LOGIN_ATTEMPTS.add(key)
        return True


def response_payload(response):
    try:
        payload = response.read()
    except http.client.IncompleteRead as incomplete:
        payload = incomplete.partial
    if payload and response.getheader("Content-Encoding", "").lower() == "gzip" and payload.startswith(b"\x1f\x8b"):
        try:
            return gzip.decompress(payload)
        except (OSError, EOFError):
            pass
    return payload


def cookie_header(current, response_headers):
    values = {}
    for item in (current or "").split(";"):
        name, separator, value = item.strip().partition("=")
        if separator and name:
            values[name] = value
    for name, value in response_headers:
        if name.lower() != "set-cookie":
            continue
        key, separator, content = value.split(";", 1)[0].partition("=")
        if separator and key:
            values[key.strip()] = content
    return "; ".join(name + "=" + value for name, value in values.items())


def login_form(html):
    for found in re.finditer(r"(?is)<form\b([^>]*)>(.*?)</form\s*>", html):
        attributes, contents = found.group(1), found.group(2)
        form_attributes = {key.lower(): (double or single or bare or "") for key, double, single, bare in re.findall(r"([:\w-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))", attributes)}
        inputs = []
        for field in re.finditer(r"(?is)<input\b([^>]*)>", contents):
            attrs = {key.lower(): (double or single or bare or "") for key, double, single, bare in re.findall(r"([:\w-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))", field.group(1))}
            if attrs.get("name"):
                inputs.append(attrs)
        if any(item.get("type", "text").lower() == "password" for item in inputs):
            return form_attributes.get("action", ""), inputs, form_attributes
    return None


def build_login_body(form, username, password, device, cookie=""):
    action, inputs, form_attributes = form
    onsubmit = form_attributes.get("onsubmit", "").lower()
    input_names = {item.get("name", "").lower() for item in inputs}
    # Extreme EDM/Rapid Logic does not submit the visible username/password
    # controls. Its onsubmit handler disables them and sends a derived
    # ``encoded`` field plus the nonce from the device's ``auth`` cookie.
    # Reproduce that browser-side transformation on the server so credentials
    # remain outside the iframe DOM while the device receives its native login
    # payload.
    if "encoded" in input_names and "nonce" in input_names and "encode_vrf" in onsubmit:
        nonce = cookie_value(cookie, "auth")
        values = []
        for item in inputs:
            name = item.get("name", "")
            lower = name.lower()
            kind = item.get("type", "text").lower()
            if lower == "encoded":
                values.append((name, str(len(username)) + ":" + username + ":" + password))
            elif lower == "nonce":
                values.append((name, nonce))
            elif lower in {"username", "password", "goto"}:
                continue
            elif kind not in {"button", "file", "reset", "submit"}:
                values.append((name, item.get("value", "")))
        return action, urllib.parse.urlencode(values).encode("utf-8")
    if "encoded" in input_names and "nonce" in input_names and re.search(r"\bencode\s*\(", onsubmit):
        nonce = cookie_value(cookie, "auth")
        values = []
        for item in inputs:
            name = item.get("name", "")
            lower = name.lower()
            kind = item.get("type", "text").lower()
            if lower == "encoded":
                values.append((name, username + ":" + username + ":" + password + ":" + nonce))
            elif lower == "nonce":
                values.append((name, nonce))
            elif lower in {"username", "password", "goto"}:
                continue
            elif kind not in {"button", "file", "reset", "submit"}:
                values.append((name, item.get("value", "")))
        return action, urllib.parse.urlencode(values).encode("utf-8")
    values = []
    user_set = password_set = False
    for item in inputs:
        name, kind, value = item.get("name", ""), item.get("type", "text").lower(), item.get("value", "")
        lower = name.lower()
        if kind == "password" and not password_set:
            value, password_set = password, True
        elif not user_set and kind in {"text", "email"} and re.search(r"user|login|account|name", lower):
            value, user_set = username, True
        elif lower in {"ipaddr", "ipaddress", "host", "device"}:
            value = device
        elif kind in {"button", "file", "reset"}:
            continue
        elif kind in {"checkbox", "radio"} and "checked" not in item:
            continue
        values.append((name, value))
    if not user_set:
        for index, item in enumerate(inputs):
            if item.get("type", "text").lower() in {"text", "email"}:
                name = item.get("name", "")
                values = [(key, username if key == name else value) for key, value in values]
                user_set = True
                break
    return action, urllib.parse.urlencode(values).encode("utf-8") if user_set and password_set else None


def cookie_value(header, name):
    for item in (header or "").split(";"):
        key, separator, value = item.strip().partition("=")
        if separator and key == name:
            return value
    return ""


def remember_device_cookie(device, set_cookie):
    first = (set_cookie or "").split(";", 1)[0]
    name, separator, unused_value = first.partition("=")
    name = name.strip()
    if not separator or not name:
        return
    with DEVICE_COOKIE_LOCK:
        DEVICE_COOKIE_NAMES.setdefault(device, set()).add(name)


def device_cookie_names(device):
    with DEVICE_COOKIE_LOCK:
        return set(DEVICE_COOKIE_NAMES.get(device, set()))


def upstream_cookie(header, allowed_names=None):
    """Forward device cookies without exposing FabricNavigator credentials.

    Browsers order cookies with the most specific Path first. Keeping the
    first duplicate therefore selects the device's tunnel-scoped session
    cookie over a same-named application cookie such as JSESSIONID.
    """
    result = []
    seen = set()
    for item in (header or "").split(";"):
        key, separator, value = item.strip().partition("=")
        if not separator or not key or key in LOCAL_COOKIE_NAMES or key in seen:
            continue
        if allowed_names is not None and key not in allowed_names:
            continue
        seen.add(key)
        result.append(key + "=" + value)
    return "; ".join(result)


def device_cookie_prefix(device):
    return "FNDEV_" + device.replace(".", "_") + "__"


def upstream_device_cookie(header, device):
    """Forward cookies belonging to this path-isolated device session.

    EDM reads several login cookies from JavaScript. Renaming those cookies in
    the browser breaks its own session detection ("Logged in as: undefined").
    Device cookies therefore keep their original names and are isolated by the
    device-specific tunnel Path. Cookies prefixed by older builds are ignored;
    restoring them would revive the broken EDM session that reports an
    undefined user.
    """
    prefix = device_cookie_prefix(device)
    remembered = device_cookie_names(device)
    result = []
    seen = set()
    for item in (header or "").split(";"):
        key, separator, value = item.strip().partition("=")
        if not separator or not key:
            continue
        if key.startswith(prefix):
            continue
        original = key
        if original in LOCAL_COOKIE_NAMES:
            continue
        # Never leak FabricNavigator's root Tomcat session to a device. A
        # device-owned JSESSIONID is allowed once its Set-Cookie header has
        # been observed for this target.
        if original == "JSESSIONID" and original not in remembered:
            continue
        if not original or original in seen:
            continue
        seen.add(original)
        result.append(original + "=" + value)
    return "; ".join(result)


def rewrite_location(value, device):
    try:
        parsed = urllib.parse.urlsplit(value)
        if parsed.hostname == device:
            path = parsed.path or "/"
            rewritten = PREFIX + device + (path if path.startswith("/") else "/" + path)
            if parsed.query:
                rewritten += "?" + parsed.query
            if parsed.fragment:
                rewritten += "#" + parsed.fragment
            return rewritten
    except ValueError:
        pass
    if value.startswith("/") and not value.startswith(PREFIX):
        return PREFIX + device + value
    return value


def rewrite_request_url(value, device):
    """Translate the public tunnel URL back to the device origin."""
    if not value:
        return value
    try:
        parsed = urllib.parse.urlsplit(value)
        tunnel_prefix = PREFIX + device
        if parsed.path == tunnel_prefix or parsed.path.startswith(tunnel_prefix + "/"):
            path = parsed.path[len(tunnel_prefix):] or "/"
            rewritten = "https://" + device + path
            if parsed.query:
                rewritten += "?" + parsed.query
            if parsed.fragment:
                rewritten += "#" + parsed.fragment
            return rewritten
    except ValueError:
        pass
    return "https://" + device + "/"


def rewrite_set_cookie(value, device):
    # Keep the original cookie name because EDM reads its login state through
    # document.cookie. The device-specific Path below provides isolation.
    value = re.sub(r"(?i);\s*Domain=[^;]*", "", value)
    tunnel_path = PREFIX + device + "/"
    if re.search(r"(?i);\s*Path=", value):
        def replace_path(match):
            original = (match.group(1) or "").lstrip("/")
            return "; Path=" + tunnel_path + original
        value = re.sub(r"(?i);\s*Path=([^;]*)", replace_path, value, count=1)
    else:
        value += "; Path=" + tunnel_path
    return value


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self): self.proxy()
    def do_HEAD(self): self.proxy()
    def do_POST(self): self.proxy()
    def do_PUT(self): self.proxy()
    def do_PATCH(self): self.proxy()
    def do_DELETE(self): self.proxy()

    def proxy(self):
        parsed = urllib.parse.urlsplit(self.path)
        match = re.match(r"^/webview-tunnel/([^/]+)(/.*)?$", parsed.path)
        if not match:
            self.send_error(404)
            return
        device = match.group(1)
        try:
            address = ipaddress.ip_address(device)
            if address.version != 4 or not (address.is_private or address.is_link_local):
                raise ValueError("target must be a private IPv4 address")
        except ValueError:
            self.send_error(400, "Invalid device address")
            return
        query = urllib.parse.parse_qs(parsed.query)
        supplied_ticket = (query.get("ticket") or [""])[0]
        cookie_ticket = cookie_value(self.headers.get("Cookie", ""), "FNWebTicket")
        ticket = supplied_ticket if valid_ticket(supplied_ticket, device) else cookie_ticket
        ticket_info = ticket_data(ticket, device)
        ticket_authenticated = ticket_info is not None
        if not ticket_authenticated and not authenticated(self.headers.get("Cookie", "")):
            self.send_error(401, "FabricNavigator login or valid tunnel ticket required")
            return
        target_path = match.group(2) or "/"
        forwarded_query = [(key, value) for key, values in query.items() if key != "ticket" for value in values]
        forwarded_query = [(key, value) for key, value in forwarded_query if key != "__fn_auth_retry"]
        if forwarded_query:
            target_path += "?" + urllib.parse.urlencode(forwarded_query)
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else None
        content_type_header = self.headers.get("Content-Type", "")
        if body and content_type_header.lower().startswith("application/x-www-form-urlencoded"):
            try:
                form = urllib.parse.parse_qsl(body.decode("utf-8"), keep_blank_values=True)
                if any(key == "ipAddr" for key, _ in form):
                    form = [(key, device if key == "ipAddr" else value) for key, value in form]
                    body = urllib.parse.urlencode(form).encode("utf-8")
            except (UnicodeDecodeError, ValueError):
                pass
        headers = {}
        for name, value in self.headers.items():
            lower = name.lower()
            if lower not in HOP_HEADERS and lower not in {"host", "content-length", "accept-encoding", "origin", "referer", "cookie"}:
                headers[name] = value
        headers["Host"] = device
        headers["Accept-Encoding"] = "identity"
        device_cookie = upstream_device_cookie(self.headers.get("Cookie", ""), device)
        if device_cookie:
            headers["Cookie"] = device_cookie
        # EDM validates the browser origin on authentication requests.  The
        # public localhost origin must therefore be translated back to the
        # switch origin instead of being removed by the reverse proxy.
        if self.headers.get("Origin"):
            headers["Origin"] = "https://" + device
        if self.headers.get("Referer"):
            headers["Referer"] = rewrite_request_url(self.headers.get("Referer"), device)
        # Rapid Logic drops the response body when HTTP/1.1 connection closure
        # is requested (notably the 3846-byte EDM login page). Its declared
        # Content-Length lets http.client finish the read safely on keep-alive.
        headers["Connection"] = "keep-alive"
        if body is not None:
            headers["Content-Length"] = str(len(body))
        context = ssl._create_unverified_context()
        try:
            context.minimum_version = ssl.TLSVersion.TLSv1
            context.set_ciphers("ALL:@SECLEVEL=0")
        except (AttributeError, ssl.SSLError):
            pass
        connection = http.client.HTTPSConnection(device, 443, timeout=30, context=context)
        try:
            connection.request(self.command, target_path, body=body, headers=headers)
            upstream = connection.getresponse()
            response_status, response_reason, response_headers = upstream.status, upstream.reason, upstream.getheaders()
            try:
                payload = upstream.read()
            except http.client.IncompleteRead as incomplete:
                # Keep usable partial content instead of replacing it with a
                # tunnel-level 502 response.
                payload = incomplete.partial
            content_type = upstream.getheader("Content-Type", "")
            content_encoding = upstream.getheader("Content-Encoding", "").lower()
            decoded_content = False
            if payload and content_encoding == "gzip":
                if payload.startswith(b"\x1f\x8b"):
                    try:
                        payload = gzip.decompress(payload)
                        decoded_content = True
                    except (OSError, EOFError):
                        pass
                else:
                    # Some EDM releases return an already uncompressed script
                    # while retaining the upstream gzip header. Forwarding that
                    # header makes browsers reject the otherwise valid script
                    # with ERR_CONTENT_DECODING_FAILED.
                    decoded_content = True
            # When an assigned WebView profile exists, submit a conventional
            # HTML login form from the server. The clear-text password never
            # appears in the iframe DOM, browser storage, query string, or
            # FabricNavigator logs. Firmware using a non-HTML challenge simply
            # falls back to its regular manual login page.
            auto_credentials = ticket_info or {}
            can_auto_login = (self.command == "GET" and body is None and
                              auto_credentials.get("username") and auto_credentials.get("password") and
                              content_type.lower().startswith("text/html"))
            parsed_login = login_form(payload.decode("utf-8", errors="replace")) if can_auto_login else None
            if parsed_login and claim_autologin(ticket, device):
                combined_cookie = cookie_header(device_cookie, response_headers)
                action, login_body = build_login_body(parsed_login, auto_credentials["username"], auto_credentials["password"], device, combined_cookie)
                if login_body:
                    absolute_action = urllib.parse.urljoin("https://" + device + target_path, action or target_path)
                    action_parts = urllib.parse.urlsplit(absolute_action)
                    action_path = action_parts.path or "/"
                    if action_parts.query:
                        action_path += "?" + action_parts.query
                    login_headers = {"Host": device, "Accept": "text/html,application/xhtml+xml,*/*", "Accept-Encoding": "identity", "Content-Type": "application/x-www-form-urlencoded", "Content-Length": str(len(login_body)), "Origin": "https://" + device, "Referer": "https://" + device + target_path, "Connection": "keep-alive"}
                    if combined_cookie:
                        login_headers["Cookie"] = combined_cookie
                    login_connection = http.client.HTTPSConnection(device, 443, timeout=30, context=context)
                    try:
                        login_connection.request("POST", action_path, body=login_body, headers=login_headers)
                        login_response = login_connection.getresponse()
                        login_payload = response_payload(login_response)
                        login_headers_out = login_response.getheaders()
                        # Preserve bootstrap cookies as well as cookies issued
                        # by the successful authentication response.
                        response_headers = response_headers + login_headers_out
                        response_status, response_reason = login_response.status, login_response.reason
                        payload = login_payload
                        content_type = login_response.getheader("Content-Type", "")
                        content_encoding = login_response.getheader("Content-Encoding", "").lower()
                        decoded_content = content_encoding == "gzip"
                    finally:
                        login_connection.close()
            if self.command != "HEAD" and any(content_type.lower().startswith(kind) for kind in TEXT_TYPES):
                charset = "utf-8"
                found = re.search(r"charset=([^;\s]+)", content_type, re.I)
                if found:
                    charset = found.group(1).strip('"\'')
                try:
                    text = payload.decode(charset, errors="replace")
                    base = PREFIX + device + "/"
                    type_lower = content_type.lower()
                    text = re.sub(r"https?://" + re.escape(device) + r"(?::\d+)?/", base, text, flags=re.I)
                    if type_lower.startswith("text/html"):
                        text = re.sub(r'(?i)(href|src|action)=("|\')/(?!webview-tunnel/)', lambda m: m.group(1) + "=" + m.group(2) + base, text)
                        text = re.sub(r'(?i)url\(("|\')?/(?!webview-tunnel/)', lambda m: "url(" + (m.group(1) or "") + base, text)
                        text = re.sub(r'(?i)((?:window\.)?location(?:\.href)?\s*=\s*["\'])/(?!/|webview-tunnel/)', lambda m: m.group(1) + base, text)
                    elif type_lower.startswith("text/css"):
                        text = re.sub(r'(?i)url\(("|\')?/(?!webview-tunnel/)', lambda m: "url(" + (m.group(1) or "") + base, text)
                    payload = text.encode(charset, errors="replace")
                except LookupError:
                    pass
            # Rapid Logic first answers an unauthenticated EDM request with an
            # empty 401 while issuing its authSec bootstrap cookie. Browsers do
            # not retry such a document automatically, leaving the iframe
            # blank. Perform exactly one public redirect so the next request
            # carries the new, tunnel-scoped device cookie.
            bootstrap_cookie = any(name.lower() == "set-cookie" and value.lower().startswith("authsec=") for name, value in response_headers)
            bootstrap_retry = self.command in {"GET", "HEAD"} and response_status == 401 and not payload and bootstrap_cookie and "__fn_auth_retry" not in query
            if bootstrap_retry:
                self.send_response(302, "Device authentication bootstrap")
                for name, value in response_headers:
                    if name.lower() == "set-cookie":
                        remember_device_cookie(device, value)
                        self.send_header("Set-Cookie", rewrite_set_cookie(value, device))
                if supplied_ticket and ticket_authenticated:
                    self.send_header("Set-Cookie", "FNWebTicket=" + supplied_ticket + "; Path=" + PREFIX + device + "/; Max-Age=600; HttpOnly; Secure; SameSite=Strict")
                retry_query = list(forwarded_query)
                retry_query.append(("__fn_auth_retry", "1"))
                retry_url = PREFIX + device + (match.group(2) or "/") + "?" + urllib.parse.urlencode(retry_query)
                self.send_header("Location", retry_url)
                self.send_header("Content-Length", "0")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                return
            self.send_response(response_status, response_reason)
            for name, value in response_headers:
                lower = name.lower()
                if lower in HOP_HEADERS or lower in {"content-length", "content-security-policy", "x-frame-options"}:
                    continue
                if lower == "content-encoding" and decoded_content:
                    continue
                if lower == "location":
                    value = rewrite_location(value, device)
                elif lower == "refresh":
                    value = re.sub(r'(?i)(url\s*=\s*)/', lambda m: m.group(1) + PREFIX + device + "/", value)
                elif lower == "set-cookie":
                    remember_device_cookie(device, value)
                    value = rewrite_set_cookie(value, device)
                self.send_header(name, value)
            if supplied_ticket and ticket_authenticated:
                self.send_header("Set-Cookie", "FNWebTicket=" + supplied_ticket + "; Path=" + PREFIX + device + "/; Max-Age=600; HttpOnly; Secure; SameSite=Strict")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(payload)
        except Exception as error:
            self.send_error(502, "Device web interface unavailable: " + str(error))
        finally:
            connection.close()

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    ThreadingHTTPServer(LISTEN, ProxyHandler).serve_forever()
