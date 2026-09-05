# FabricNavigator 26.09.10.240

- Fixed the offline-update workflow so every accepted installation immediately opens the full-screen progress dialog and continues live status polling after the page reload.

- Fixed API token creation on existing installations by repairing ownership and permissions of the persistent API token directory during startup.

- Migrated the remaining Java security, topology, and SNMP packages into the `com.fabricnavigator` namespace and removed the obsolete vendor package trees from the runtime and source layout.
- Moved Group selection and Manual link into the Actions toolbox even when no real topology exists.
- Fixed switching from the demo back to an empty real topology so the full topology workspace remains usable.
- Restyled the ACLI settings and session-log cards to match the current Administration design in light and dark mode.
- Fixed ACLI session-log downloads by serving validated log files through the JSP response writer.

- Added a read-only, bearer-token-protected FabricNavigator API for authorized management clients such as ACLI Session Manager.
- The session export includes device name, IP address, SSH port and credentials, device type, platform, `sysLocation`, software version, and system description.
- Added an Administration > API page for creating and revoking the FabricNavigator API token; plaintext tokens are shown only once and are never stored.

- Replaced the legacy empty Discovery card with the current full-canvas topology workspace when no saved or discovered topology exists.
- Automatically opens Topology tools and its Discovery section in the empty topology state so a new discovery can be started immediately.

- Added a bounded parallel SNMP pre-scan for subnet discoveries so non-responsive addresses no longer block the discovery one after another.
- Fixed guided-tour navigation so moving to the next step replaces the previous highlight and card instead of leaving stale tour elements behind.
- Fixed the collapsed Topology tools layout and moved the Name/IP device-label control from the search bar into Topology tools.
- Kept Discovery details, warnings, and failures in the Discovery log without displaying them on the topology page.
- Limited full recursive LLDP discovery to seed addresses that respond to one of the selected SNMP profiles when larger seed ranges are used.
- The Actions toolbox now starts directly below Topology tools while preserving positions moved by the user afterward.
- Device names in the Devices table now retain a high-contrast text color in dark mode.
- Hid the no-longer-needed GitHub update-token panel from the public-repository update interface.
- Prevented the purple Administration navigation tile from shrinking so it stays the same width as Topology and Devices without distorting the icon.
- Restyled and localized the update-channel selector to match the current Administration interface in light and dark mode.
- The Updates page now returns to the Plugins tab after checking or installing ACLI component updates.
- Added a full-page progress indicator while ACLI updates are being checked and made the Plugins return path explicit.
- Increased the compact-navigation spacing so the active purple icon outline no longer overlaps its label.
- Expanded the audit log with explicit success/failure status, readable operation names, affected users/devices/profiles, non-secret configuration values, update-check results, and SSH host-key fingerprints while continuing to exclude all passwords, communities, tokens, and private keys.
- Increased the shared main-navigation button width and icon-to-label spacing so the active purple outline no longer crosses the Administration label.
- Standardized every top-level and nested node context-menu entry to the same typography as Open SSH.
