# FabricNavigator 26.09.10.300

- Adds per-port Auto-Sense state to topology link details for FabricEngine, VOSS, and VSP devices, including UNI, NNI, IS-IS, Fabric Attach, and disabled states.
- Removes the browser-generated rectangular focus outline shown after selecting a topology link.
- Prevents stale “session closed” content from flashing while an SSH session reconnects.
- Adds the captured switch software version to stored configuration backup versions and audit details.
- Adds configuration viewing for SwitchEngine and EXOS backups, and improves the movable and resizable configuration viewer.
- Keeps configuration backups in the background, preserves progress across page navigation, and identifies failed devices with their error details.
- Improves configuration comment filtering by removing the resulting empty lines.
- Uses the global device name/IP preference consistently in configuration backup device selectors and clarifies the related profile setting.
- Prevents the first login attempt after an update from being rejected solely because the previous server session was replaced.

## Beta notice

This release is published as a prerelease for validation before it is promoted to the stable channel.
