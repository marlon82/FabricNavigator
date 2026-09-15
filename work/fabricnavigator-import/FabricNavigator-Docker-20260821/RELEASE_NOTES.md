# FabricNavigator 26.09.10.310

- Added built-in, vendor-validated Fabric Engine and VOSS 9.4 upgrade paths for supported switch families.
- Added operating-system-aware policy matching so Fabric Engine rules are never applied to Switch Engine firmware on the same hardware family.
- Upgrade plans now show the validated intermediate release family when a direct upgrade is not supported.
- Access point labels in the demo topology are now positioned below the device icon instead of overlapping it.
- Stabilized the discovery progress view by avoiding full-page backdrop repainting and pausing topology animations while discovery is running.
- Link speed discovery now prefers the physical switch port over a remote management interface such as `mgt0`, preventing gigabit AP links from being shown as 10 Mbit/s.
