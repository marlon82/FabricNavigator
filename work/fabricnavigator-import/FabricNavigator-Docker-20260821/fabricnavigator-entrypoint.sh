#!/bin/sh
UPDATE_DIR="${FABRICNAVIGATOR_UPDATE_DIR:-/opt/fabricnavigator/update}"
DATA_DIR="${FABRICNAVIGATOR_DATA_DIR:-${FABRICNAVIGATOR_SECURITY_DIR:-/opt/fabricnavigator/data}}"
LEGACY_DATA_DIR="/opt/tomcat/conf/edm-security"
if [ "$DATA_DIR" != "$LEGACY_DATA_DIR" ] && [ -d "$LEGACY_DATA_DIR" ] && [ -n "$(find "$LEGACY_DATA_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] && [ -z "$(find "$DATA_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  mkdir -p "$(dirname "$DATA_DIR")"
  if grep -qs " $DATA_DIR " /proc/mounts; then
    mkdir -p "$DATA_DIR"
    cp -a "$LEGACY_DATA_DIR"/. "$DATA_DIR"/
  else
    rm -rf "$DATA_DIR"
    ln -s "$LEGACY_DATA_DIR" "$DATA_DIR"
  fi
fi
ROUTE_FILE="$DATA_DIR/static-routes.conf"
ACLI_CONFIG="$DATA_DIR/acli.ini"
ACLI_LOG_DIR="$DATA_DIR/acli-logs"
API_DATA_DIR="$DATA_DIR/api"
mkdir -p "$UPDATE_DIR"
# The directory contains only update requests and public release metadata. It
# must be writable by Tomcat and readable by the separate Windows host updater.
chmod 0777 "$UPDATE_DIR" 2>/dev/null || true
# Keep the credential directory protected while making only the route request
# file writable by the unprivileged Tomcat process. The privileged Windows or
# Linux host updater consumes the request from the shared update directory.
mkdir -p "$DATA_DIR"
mkdir -p "$ACLI_LOG_DIR"
mkdir -p "$API_DATA_DIR"
if [ ! -f "$ACLI_CONFIG" ]; then
  cp /opt/acli-web/acli-default.ini "$ACLI_CONFIG"
fi
for legacy_path_file in "$ACLI_CONFIG" "$DATA_DIR/acli-component/current/acli-launch.pl"; do
  if [ -f "$legacy_path_file" ] && grep -q '/opt/tomcat/conf/edm-security' "$legacy_path_file"; then
    sed -i 's#/opt/tomcat/conf/edm-security#/opt/fabricnavigator/data#g' "$legacy_path_file"
  fi
done
chown -R tomcat:tomcat "$ACLI_LOG_DIR" "$ACLI_CONFIG" 2>/dev/null || true
chmod 0700 "$ACLI_LOG_DIR" 2>/dev/null || true
chmod 0600 "$ACLI_CONFIG" 2>/dev/null || true
# API tokens are created by the unprivileged Tomcat process. Repair legacy
# directories that earlier builds may have created as root during startup.
chown -R tomcat:tomcat "$API_DATA_DIR" 2>/dev/null || true
chmod 0700 "$API_DATA_DIR" 2>/dev/null || true
if [ -f "$API_DATA_DIR/fabricnavigator-api.properties" ]; then
  chmod 0600 "$API_DATA_DIR/fabricnavigator-api.properties" 2>/dev/null || true
fi
touch "$ROUTE_FILE"
chmod 0666 "$ROUTE_FILE" 2>/dev/null || true
/usr/bin/python3 /opt/fabricnavigator/route-manager.py &
/usr/bin/python3 /opt/fabricnavigator/webview-proxy.py &
/usr/bin/python3 /opt/fabricnavigator/update-coordinator.py &
# Remove the bundled Extreme EDM application and the legacy snmp4jdm runtime.
# The replacement adapter is original FabricNavigator code backed by SNMP4J
# under the Apache License 2.0.
rm -rf /opt/tomcat/webapps/edm /opt/tomcat/webapps/edm.war
rm -f /opt/tomcat/webapps/ROOT/community-main.jsp /opt/tomcat/webapps/ROOT/device-main.jsp
rm -f /opt/tomcat/webapps/ROOT/WEB-INF/lib/snmp4jdm-1.0.jar
rm -f /opt/tomcat/webapps/ROOT/WEB-INF/classes/mib.dat
rm -rf /opt/tomcat/webapps/ROOT/WEB-INF/classes/com
rm -f /opt/tomcat/lib/edm-security.jar
if [ ! -f /opt/fabricnavigator/snmp4j-2.8.18.jar ]; then
  echo "FabricNavigator SNMP4J dependency is missing" >&2
  exit 1
fi
cp -f /opt/fabricnavigator/snmp4j-2.8.18.jar /opt/tomcat/webapps/ROOT/WEB-INF/lib/snmp4j-2.8.18.jar
if [ -d /opt/fabricnavigator/snmp-src ]; then
  snmp_classes=/tmp/fabricnavigator-snmp-classes
  rm -rf "$snmp_classes"
  mkdir -p "$snmp_classes"
  /opt/java8/bin/java -cp /opt/tomcat/lib/ecj-4.5.jar org.eclipse.jdt.internal.compiler.batch.Main \
    -1.8 -d "$snmp_classes" -classpath /opt/fabricnavigator/snmp4j-2.8.18.jar \
    /opt/fabricnavigator/snmp-src
  if [ "$?" -ne 0 ]; then
    echo "FabricNavigator SNMP adapter compilation failed" >&2
    exit 1
  fi
  cp -rf "$snmp_classes"/com /opt/tomcat/webapps/ROOT/WEB-INF/classes/
fi
# JSP compiler failures are cached below Tomcat's work directory. Clear only
# generated ROOT JSP artifacts on startup so updated classes and pages are
# always compiled together after an update or development bind-mount change.
rm -rf /opt/tomcat/work/Catalina/localhost/ROOT/org/apache/jsp 2>/dev/null || true
# Older base images name the FabricNavigator egress rules after the retired
# bundled application. Migrate the nftables include before the base entrypoint
# loads the rules so both updated and freshly installed systems use the current
# FabricNavigator name.
if [ -f /etc/nftables.conf ] && grep -q '/etc/nftables.d/edm-egress.nft' /etc/nftables.conf; then
  sed -i 's#/etc/nftables.d/edm-egress\.nft#/etc/nftables.d/fabricnavigator-egress.nft#g' /etc/nftables.conf
fi
rm -f /etc/nftables.d/edm-egress.nft 2>/dev/null || true
# Migrate the inherited rule refresher and its launcher without changing its
# target-selection behavior. Updated images already contain only the new name;
# this branch keeps development and older base images upgrade-compatible.
if [ -f /usr/local/sbin/refresh-edm-egress.py ] && [ ! -f /usr/local/sbin/refresh-fabricnavigator-egress.py ]; then
  sed -i \
    -e 's/edm-egress/fabricnavigator-egress/g' \
    -e 's/edm_egress/fabricnavigator_egress/g' \
    /usr/local/sbin/refresh-edm-egress.py
  mv /usr/local/sbin/refresh-edm-egress.py /usr/local/sbin/refresh-fabricnavigator-egress.py
fi
if [ -f /usr/local/bin/docker-entrypoint.sh ]; then
  sed -i 's#refresh-edm-egress\.py#refresh-fabricnavigator-egress.py#g' /usr/local/bin/docker-entrypoint.sh
fi
exec /usr/local/bin/docker-entrypoint.sh "$@"
