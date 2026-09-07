# FabricNavigator 26.09.10.298

- Correctly identifies Ethernet Routing Switch (ERS) devices instead of treating them as FabricEngine switches.
- Adds a dedicated generic ERS front-panel icon with a blue ERS identifier while preserving topology and cluster frame colors.
- Preserves resolved Virtual IST peer node identifiers in the topology UI so detected vIST pairs can be rendered correctly.
- Adds optional, comprehensive discovery diagnostics covering SNMP attempts, processing stages, LLDP tables, detected capabilities, links, and error classes without logging credentials or secrets.
- Fixes the discovery settings path so SNMP timeout, retry, and debug settings configured in Administration are applied by the discovery engine.
- Prevents a deliberately closed SSH dialog from being restored when navigating to another page.

## Beta notice

This release is published as a prerelease for validation before it is promoted to the stable channel.
