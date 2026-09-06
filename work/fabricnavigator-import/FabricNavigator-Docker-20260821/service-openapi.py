#!/usr/bin/env python3
"""Read-only Fabric Engine OpenAPI precheck for service provisioning.

The actual configuration transaction remains in service-provision.pl until the
vendor API documents an atomic CVLAN/I-SID mapping operation. Exit 75 tells the
JSP caller to use its verified SSH fallback.
"""
import base64
import json
import re
import ssl
import sys
import urllib.error
import urllib.request


def read_value():
    line = sys.stdin.readline()
    if not line:
        return ""
    return base64.b64decode(line.strip()).decode("utf-8")


def finish(code, **payload):
    print(json.dumps(payload, separators=(",", ":")))
    raise SystemExit(code)


def request(url, method="GET", body=None, token=None, basic=None):
    headers = {"Accept": "application/json", "Content-Type": "application/json"}
    if token:
        headers["X-Auth-Token"] = token
    if basic:
        encoded = base64.b64encode((basic[0] + ":" + basic[1]).encode("utf-8")).decode("ascii")
        headers["Authorization"] = "Basic " + encoded
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen(req, timeout=8, context=context) as response:
        raw = response.read()
        return json.loads(raw.decode("utf-8")) if raw else {}


host, username, password, action, vlan, name, msti, isid, platform = [read_value() for _ in range(9)]
if platform == "switchengine":
    commands = [f"create vlan {name} tag {vlan}", f"configure vlan {name} add isid {isid}"]
    if int(msti or "0") > 0:
        commands.append(f"enable stpd s{msti} auto-bind vlan {name}")
    commands.append("save configuration")
else:
    commands = ["enable", "configure terminal",
                f"vlan create {vlan} name {name} type port-mstprstp {msti}",
                f"vlan i-sid {vlan} {isid}", "exit", "save config"]
if action != "precheck" or not password:
    finish(75, ok=False, fallback=True, host=host,
           error="OpenAPI precheck is not applicable")

if platform == "switchengine":
    def cli(command, identifier):
        result = request(f"http://{host}/jsonrpc", "POST",
                         {"method": "cli", "id": identifier, "jsonrpc": "2.0", "params": [command]},
                         basic=(username, password))
        if "error" in result:
            raise ValueError(str(result["error"]))
        rows = result.get("result", [])
        return "\n".join(str(row.get("CLIoutput", "")) for row in rows if isinstance(row, dict))
    try:
        switch_output = cli("show switch", 1)
        vlan_output = cli("show vlan", 2)
        isid_output = cli("show fabric attach assignments", 3)
        if re.search(r"VOSS|Fabric Engine|Virtual Services Platform", switch_output, re.I):
            raise ValueError("Device platform differs from topology detection")
        if int(msti or "0") > 0:
            stpd_output = cli(f"show stpd s{msti}", 4)
            if re.search(r"invalid|unknown|not found|does not exist|error", stpd_output, re.I):
                raise ValueError(f"MSTI/STPD s{msti} does not exist")
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, ValueError, OSError) as error:
        finish(75, ok=False, fallback=True, host=host, error="SwitchEngine API unavailable: " + str(error))
    vlan_conflict = False
    name_conflict = False
    for line in vlan_output.splitlines():
        match = re.match(r"^\s*(\S+)\s+(\d+)\s+", line)
        if match:
            name_conflict = name_conflict or match.group(1).lower() == name.lower()
            vlan_conflict = vlan_conflict or int(match.group(2)) == int(vlan)
    isid_conflict = bool(re.search(rf"(?:^|\s){re.escape(isid)}(?:\s|$)", isid_output, re.M))
    vlan_conflict = vlan_conflict or bool(re.search(rf"(?:^|\s){re.escape(vlan)}(?:\s|$)", isid_output, re.M))
    name_conflict = name_conflict or bool(re.search(rf"(?:^|\s){re.escape(name)}(?:\s|$)", isid_output, re.I | re.M))
    finish(0, ok=True, host=host, platform=platform, transport="switchengine-jsonrpc",
           vlanConflict=vlan_conflict, nameConflict=name_conflict,
           isidConflict=isid_conflict, vistPartner="", commands=commands)

if platform != "fabricengine":
    finish(75, ok=False, fallback=True, host=host, error="Device API precheck is not applicable")

try:
    auth = request(f"https://{host}:9443/auth/token", "POST",
                   {"username": username, "password": password})
    token = str(auth.get("token", ""))
    if not token:
        finish(75, ok=False, fallback=True, host=host,
               error="OpenAPI authentication returned no token")
    vlans = request(f"https://{host}:9443/rest/openapi/v1/state/vlan", token=token)
    l2vsns = request(f"https://{host}:9443/rest/openapi/v0/configuration/spbm/l2/isid", token=token)
except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, ValueError, OSError) as error:
    finish(75, ok=False, fallback=True, host=host,
           error="OpenAPI unavailable: " + str(error))

vlan_id = int(vlan)
isid_id = int(isid)
vlan_conflict = False
name_conflict = False
isid_conflict = False
for item in vlans if isinstance(vlans, list) else []:
    current_id = item.get("vlanId", item.get("id"))
    try:
        vlan_conflict = vlan_conflict or int(current_id) == vlan_id
    except (TypeError, ValueError):
        pass
    name_conflict = name_conflict or str(item.get("name", "")).lower() == name.lower()
for group in ("cvlan", "suni", "tuni"):
    entries = l2vsns.get(group, []) if isinstance(l2vsns, dict) else []
    for item in entries if isinstance(entries, list) else []:
        try:
            isid_conflict = isid_conflict or int(item.get("isid")) == isid_id
        except (TypeError, ValueError):
            pass
        name_conflict = name_conflict or str(item.get("name", "")).lower() == name.lower()
        for key in ("cvid", "vlanId", "vlan"):
            try:
                vlan_conflict = vlan_conflict or int(item.get(key)) == vlan_id
            except (TypeError, ValueError):
                pass

finish(0, ok=True, host=host, platform=platform, transport="openapi",
       vlanConflict=vlan_conflict, nameConflict=name_conflict,
       isidConflict=isid_conflict, vistPartner="", commands=commands)
