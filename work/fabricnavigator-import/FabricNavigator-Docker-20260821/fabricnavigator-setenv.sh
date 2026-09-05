#!/bin/sh
umask 0077
CATALINA_OPTS="$CATALINA_OPTS -Dedm.public.baseUrl=https://localhost:8443 -Dfabricnavigator.data.dir=/opt/fabricnavigator/data -Dedm.security.dir=/opt/fabricnavigator/data -Dedm.devices.dir=/opt/tomcat/conf/edm-devices -Dedm.acli.script=/opt/acli/acli-launch.pl -Dedm.acli.config=/opt/fabricnavigator/data/acli.ini -Dedm.pty.bridge=/opt/acli-web/pty_bridge.py -Dedm.terminal.runDir=/opt/tomcat/run/edm-terminal"
export CATALINA_OPTS

ROUTE_FILE=/opt/fabricnavigator/data/static-routes.conf
if command -v ip >/dev/null 2>&1 && [ -r "$ROUTE_FILE" ]; then
  while IFS='|' read -r destination gateway; do
    [ -n "$destination" ] && [ -n "$gateway" ] && ip route replace "$destination" via "$gateway" >/dev/null 2>&1 || true
  done < "$ROUTE_FILE"
fi
