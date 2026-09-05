# FabricNavigator online installer for Ubuntu

This small installer targets an existing Ubuntu Server 22.04 LTS or newer on
amd64. It does not contain the FabricNavigator container image or Ubuntu
packages. During installation it:

1. updates the configured Ubuntu package indexes;
2. installs the required host tools and, when necessary, Docker Engine;
3. resolves the latest stable FabricNavigator GitHub release;
4. downloads `FabricNavigator-Installer-VERSION.zip` through the GitHub API;
5. verifies the release asset against GitHub's SHA-256 digest; and
6. imports and starts the FabricNavigator container.

Extract and start it with tools already present on Ubuntu:

```bash
tar -xzf FabricNavigator-Linux-Online-Installer.tar.gz
cd FabricNavigator-Linux-Online-Installer
chmod +x install-fabricnavigator.sh
sudo ./install-fabricnavigator.sh
```

No token is required for the public FabricNavigator repository. For a private
fork or higher authenticated API limits, add `--token-file PATH`. The optional
token is installed securely for future updates, is not included in the
installer archive, and is never printed.

GitHub's `latest release` endpoint intentionally ignores prereleases. The
online installer therefore scans stable releases and installs the newest one
that contains a complete FabricNavigator installer, not an update-only or beta build.
