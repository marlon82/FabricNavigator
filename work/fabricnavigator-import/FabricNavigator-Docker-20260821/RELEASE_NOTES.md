# FabricNavigator 26.09.10.305

- Expired web sessions now return users to the full-page login screen.
- Background requests receive an explicit session-expired response instead of embedding the login page inside the current view.
- The browser follows the configured web session timeout and refreshes the authentication screen automatically.
- Compatibility policies can now be derived from user-provided vendor release-notes PDFs.
- Validated source releases are evaluated per device family from the upgrade-path matrix before deployment.
- Imported policies retain their source document, checksum, and optional official URL for traceability.
- Official VOSS, FabricEngine, SwitchEngine, and EXOS release-note archives are linked from firmware management.
- Firmware inventory is grouped by device family instead of individual model variants.

This release is published as a prerelease for validation before it is promoted to the stable channel. Firmware deployment can interrupt network operation; verify vendor release notes, supported upgrade paths, and maintenance-window requirements before use.
