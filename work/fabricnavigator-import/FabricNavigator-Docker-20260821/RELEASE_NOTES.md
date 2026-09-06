# FabricNavigator 26.09.10.245

- Replaced the demo topology quantity fields with live range sliders, constrained core and distribution device counts to increments of two, and added an option to generate the demo with or without topology groups.
- Limited the topology Actions toolbox to actions supported by every selected node, and restricted tunneled WebView actions to explicitly supported FabricEngine/VSP devices.
- Fixed software updates started from the build-number release-notes dialog so the full-screen installation progress view opens immediately.
- Added live updater-state polling, restart detection, elapsed-time information, and automatic return to the sign-in page to this update path.
- Updated the shared application-shell cache key on every page so the corrected dialog behavior is loaded without retaining an older browser-cached script.
- Kept the Actions toolbox docked directly below Topology tools as Discovery and other tool sections expand or collapse, preventing the two panels from overlapping.
- Preserved freely positioned Actions toolboxes after the user explicitly drags them away from their default docked position.
- Added a styled configuration dialog for selecting the number of 7720 core nodes, paired 7520/7720 distribution nodes, access switches, and distributed clients in the topology demo.
- Generated hierarchical demo links and semantic Core, Distribution, and Access Area groups from the selected topology size.
