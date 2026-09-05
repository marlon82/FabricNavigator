# FabricNavigator API

FabricNavigator exposes a read-only API for authorized management clients such as ACLI Session Manager.

## Authentication

An administrator creates or revokes the API token under **Administration > API**. The plaintext token is displayed once. FabricNavigator stores only its SHA-256 hash.

Send the token in the HTTP `Authorization` header. Do not put it in a URL, log file, or command history.

```http
GET /api/v1/sessions HTTP/1.1
Host: fabricnavigator.example.net:8443
Authorization: Bearer fn_api_REDACTED
Accept: application/json
```

## Response

The response contains only devices with an enabled, assigned SSH profile. Each device includes:

- device name and IP address;
- SSH protocol, port, username, password, private key, and key passphrase;
- device type and detected platform;
- SNMP `sysLocation`, software version, and system description;
- metadata status, allowing the client to distinguish unavailable SNMP metadata from empty values.

```json
{
  "apiVersion": 1,
  "fabricNavigatorVersion": "26.09.10.240",
  "generatedAt": "2026-09-05T21:00:00Z",
  "devices": [
    {
      "id": "device-192.0.2.10",
      "name": "example-switch",
      "host": "192.0.2.10",
      "protocol": "ssh",
      "port": 22,
      "deviceType": "example model",
      "platform": "FabricEngine",
      "sysLocation": "Example location",
      "softwareVersion": "0.0.0.0",
      "sysDescription": "Example system description",
      "metadataStatus": "available",
      "credential": {
        "username": "example-user",
        "password": "REDACTED",
        "privateKey": "",
        "keyPassphrase": ""
      }
    }
  ]
}
```

The endpoint returns `401 Unauthorized` when the bearer token is missing or invalid. Responses are marked `no-store`, and successful exports are recorded in the FabricNavigator audit log without credentials or tokens.
