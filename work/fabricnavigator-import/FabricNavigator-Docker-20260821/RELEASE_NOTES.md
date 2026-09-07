# FabricNavigator 26.09.10.301

- Adds a configurable application time zone under Administration → System while continuing to store canonical timestamps in UTC.
- Displays configuration-backup timestamps in the compact `YYYY-MM-DD HH:mm:ss` format using the configured time zone.
- Sorts stored configuration versions by the user's global device-name or IP-address preference.
- Adds per-device selection for scheduled automatic configuration backups without changing the manual “Back up all devices now” action.
- Adds a sortable serial-number column to the Devices table, populated from the standard ENTITY-MIB when supported.
- Allows a selected topology group object to act as the drag handle for an entire multi-selection instead of unexpectedly opening the group.

## Beta notice

This release is published as a prerelease for validation before it is promoted to the stable channel.
