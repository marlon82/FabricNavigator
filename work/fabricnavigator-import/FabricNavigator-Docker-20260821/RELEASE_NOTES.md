# FabricNavigator 26.09.10.302

- Adds the password-gated Firmware and Lifecycle Management feature with centralized firmware inventory, model and version grouping, deviation detection, compatibility policies, and upgrade sequencing.
- Adds secure firmware-image storage with SHA-256 verification and device-specific deployment previews.
- Supports staging firmware without rebooting devices, with an explicit separate option for an immediate restart.
- Automatically identifies Fabric Engine/VOSS and Switch Engine/EXOS firmware from metadata embedded in `.voss`, `.xos`, and compatible `.xmod` images.
- Reads the firmware version, platform, model family, compatible device models, architecture, and Fabric Engine activation label directly from the image instead of trusting manually entered metadata.
- Blocks a deployment in the web interface when selected device models do not match the compatibility information embedded in the firmware image.
- Repairs feature-state file ownership and permissions during startup so optional features can be enabled reliably on existing installations.
- Improves the main navigation layout when Configuration Backups and Firmware Management are enabled at the same time.
- Updates the application runtime to Apache Tomcat 9.0.121 while preserving update compatibility with existing FabricNavigator installations.

## Beta notice

This release is published as a prerelease for validation before it is promoted to the stable channel. Firmware deployment can interrupt network operation; verify vendor release notes, supported upgrade paths, and maintenance-window requirements before use.
