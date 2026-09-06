# FabricNavigator 26.09.10.273

- Changed detected vIST members to use a clear solid cluster frame.
- Added a persistent “vIST clusters” switch to Topology Tools → Link view; cluster frames remain enabled by default.

# FabricNavigator 26.09.10.272

- Added SNMP-based detection of active Fabric Engine Virtual IST clusters, including peer IP and vIST VLAN.
- Added a clearly visible shared-style outline around FabricNodes that form a vIST pair.
- Added vIST partner and VLAN details to the node hover card.
- Added simulated vIST pairs to the configurable demo topology for testing without a live cluster.

# FabricNavigator 26.09.10.271

- Added an explicit maximum-backups-per-device setting with a default of 10 for new configurations.
- Allowed retention values from 1 to 500; older versions are pruned automatically after a successful capture.
- Existing administrator-defined retention values are preserved during upgrades.

# FabricNavigator 26.09.10.270

- Configuration backup progress now survives navigation away from and back to the topology page.
- Pending device backups resume safely after returning, while per-device locking prevents concurrent duplicate captures.
- Completed backup notifications retain their green/error state and remaining auto-hide time across page navigation.

# FabricNavigator 26.09.10.269

- Stored configuration backup groups now show the discovered device name together with the IP address.
- Device names are loaded in the background with bounded concurrency, so opening the backup page remains responsive.

# FabricNavigator 26.09.10.268

- Changed Configuration Backups to the same full-width workspace layout used by the primary FabricNavigator pages.
- Removed the narrow outer content constraint and reduced unused page margins while retaining the individual function cards.

# FabricNavigator 26.09.10.267

- Added a bilingual control to the FabricEngine full-archive configuration viewer for hiding all `#` comment lines.
- Comment filtering is display-only and never changes the stored backup or downloaded configuration.

# FabricNavigator 26.09.10.266

- Added configurable concurrent configuration backups with a safe range of 1 to 10 and a default of 3.
- Applied the concurrency setting to scheduled, all-device, and topology-triggered backup jobs.
- Updated background progress to report completed devices while multiple backups run in parallel.

# FabricNavigator 26.09.10.265

- Positioned topology backup progress above the sticky legend and zoom controls so it no longer covers them.
- Fixed configuration backup initialization in the node context menu, including multi-node selections.

# FabricNavigator 26.09.10.264

- Changed topology configuration backups to non-blocking background operations.
- Added a compact, expandable progress widget in the lower-left corner with per-device results and a manual close action.
- Successful backup jobs turn green, collapse automatically, and disappear after 20 seconds.

# FabricNavigator 26.09.10.263

- Added configuration backup to the topology Actions panel and aligned its availability with the node context menu.
- Fixed backup availability for loaded or older topologies by recognizing an active SSH action even when the stored topology SSH flag is missing.
- Added an in-design help tooltip for the configuration backup action.

# FabricNavigator 26.09.10.262

- Added a protected Delete all backups action with a FabricNavigator confirmation dialog and audit entry.
- Reorganized stored configuration versions by device, with newest backups shown first.
- Added an optional topology level when multiple saved topologies are available, while keeping devices with no clear mapping under Unassigned.

# FabricNavigator 26.09.10.261

- Matched the Updates submenu styling to the Credentials submenu in light and dark mode.
- Aligned ACLI and Discovery cards with the standard administration card border, radius, spacing, and shadow.

# FabricNavigator 26.09.10.260

- Removed the redundant Credentials section heading.
- Moved Device API preferences from System → Features to Credentials → Device API.
- Aligned ACLI and Discovery administration cards with the current administration design.
- Ensured enabled Configuration Backups remains visible in the central navigation.
- Added a localized Configuration Backups tooltip describing backup, comparison, and restore actions.

# FabricNavigator 26.09.10.259

- Moved API administration into Administration → System → API.
- Reworked feature management into a list of enabled features with a Delete action and a permanent unlock field.
- Made the feature-dependent Configuration Backups entry load reliably in the central navigation.

# FabricNavigator 26.09.10.258

- Configuration Backup can now be locked again from Administration → System → Features without deleting stored backups.

# FabricNavigator 26.09.10.257

- Added preferred Fabric Engine OpenAPI and SwitchEngine JSON-RPC paths for service prechecks with automatic verified SSH fallback.
- Added an administrator setting under System > Features to enable or disable OpenAPI preference.
- Moved Configuration Backups from the Administration tabs into the central navigation between Devices and Administration when the feature is unlocked.
- Fixed the release builder classpath for configuration-backup servlet classes.

# FabricNavigator 26.09.10.256

- Fixed the WebView credential Edit action and prevented duplicate profiles from repeated identical create requests.

- Added a feature-gated Back up configuration action under More Actions in the topology context menu for supported FabricEngine, VSP, VOSS, SwitchEngine, and EXOS devices.

- Prevented the configuration viewer from reopening after a stored backup version is deleted.

- Increased the font size in the full-archive ASCII configuration viewer for improved readability.

- Prevented duplicate Configuration backups entries when the feature is unlocked and the administration shell reloads.
- Simplified the Features description by removing the administrator-password restriction notice.

- Replaced administrator-password re-authentication with a separate developer-managed password for unlocking the configuration backup feature.
- The default configuration backup feature password is `CONFIGBACKUP` and can be overridden with `FABRICNAVIGATOR_CONFIG_BACKUP_UNLOCK_PASSWORD`.

- Added an Administration → System → Features section that protects configuration backup activation with administrator password re-authentication.
- Configuration backups, archive downloads, restores, and scheduled jobs now remain hidden and server-side locked until the feature is enabled.
- Moved the full-archive ASCII configuration viewer to the top of the available browser viewport.

- Added protected local switch configuration backups for FabricEngine, VSP, SwitchEngine, and EXOS devices using assigned SSH credentials and approved host keys.
- FabricEngine, VSP, and VOSS backups now use `backup configure` and retrieve the complete device archive over SCP while retaining a normalized text copy for diffs.
- Added a View action that reads `ASCII_CONFIG` from `info.txt` and displays the referenced configuration from FabricEngine, VSP, and VOSS backup archives.
- Added a protected Delete action for stored configuration versions, including their text configuration, full archive, metadata, and audit record.
- Kept the full-archive viewer within the current browser viewport and added safe syntax highlighting for configuration sections, comments, commands, addresses, numbers, and strings.
- Renamed the archive action to Download and made the Delete action visually red.
- Added command-based platform probing and resilient SSH host-key verification so devices without an explicit operating-system marker can still be backed up reliably.
- Added optional scheduled backups with configurable intervals and per-device retention.
- Added arbitrary version comparison with color-coded added and removed configuration lines.
- Added guarded restoration of older configurations with an automatic pre-restore safety backup and post-restore verification capture.
- Added configuration version metadata for capture time, capture source, FabricNavigator operator, change attribution, platform, and SHA-256 integrity.
- Added a dedicated Administration tab for backups, version history, downloads, comparisons, restore confirmation, and operation progress.

- Added design-consistent hover help to every topology Actions button, explaining its behavior and selection scope in German and English.
- Replaced the demo topology quantity fields with live range sliders, constrained core and distribution device counts to increments of two, and added an option to generate the demo with or without topology groups.
- Limited the topology Actions toolbox to actions supported by every selected node, and restricted tunneled WebView actions to explicitly supported FabricEngine/VSP devices.
- Fixed software updates started from the build-number release-notes dialog so the full-screen installation progress view opens immediately.
- Added live updater-state polling, restart detection, elapsed-time information, and automatic return to the sign-in page to this update path.
- Updated the shared application-shell cache key on every page so the corrected dialog behavior is loaded without retaining an older browser-cached script.
- Kept the Actions toolbox docked directly below Topology tools as Discovery and other tool sections expand or collapse, preventing the two panels from overlapping.
- Preserved freely positioned Actions toolboxes after the user explicitly drags them away from their default docked position.
- Added a styled configuration dialog for selecting the number of 7720 core nodes, paired 7520/7720 distribution nodes, access switches, and distributed clients in the topology demo.
- Generated hierarchical demo links and semantic Core, Distribution, and Access Area groups from the selected topology size.
