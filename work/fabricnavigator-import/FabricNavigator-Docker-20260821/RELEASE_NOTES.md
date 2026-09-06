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
