#!/bin/sh
set -eu
INSTALL_DIRECTORY="${1:-/opt/fabricnavigator}"
SOURCE_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/plugin"
DESTINATION="$INSTALL_DIRECTORY/plugins/extreme-device-images"
test -f "$SOURCE_DIRECTORY/plugin.json" || { echo "The Extreme image plugin payload is missing." >&2; exit 1; }
mkdir -p "$DESTINATION"
find "$DESTINATION" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
cp -R "$SOURCE_DIRECTORY"/. "$DESTINATION"/
chmod -R a+rX "$DESTINATION"
echo "Extreme device images installed in $DESTINATION"
echo "Reload the FabricNavigator topology page to use the product images."
