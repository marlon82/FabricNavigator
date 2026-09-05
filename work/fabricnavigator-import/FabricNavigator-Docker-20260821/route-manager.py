#!/usr/bin/env python3
"""Synchronize FabricNavigator's desired routes with the privileged host agent."""

import os
import re
import time


ROUTE_FILE = "/opt/fabricnavigator/data/static-routes.conf"
HOST_STATE_DIR = os.environ.get("FABRICNAVIGATOR_UPDATE_DIR", "/opt/fabricnavigator/update")
HOST_ROUTE_FILE = os.path.join(HOST_STATE_DIR, "host-routes.conf")
DESTINATION = re.compile(r"^(?:default|(?:\d{1,3}\.){3}\d{1,3}/(?:[0-9]|[12][0-9]|3[0-2]))$")
GATEWAY = re.compile(r"^(?:\d{1,3}\.){3}\d{1,3}$")


def read_routes():
    routes = []
    try:
        with open(ROUTE_FILE, encoding="utf-8") as handle:
            for raw in handle:
                parts = raw.strip().split("|", 1)
                if len(parts) == 2 and DESTINATION.fullmatch(parts[0]) and GATEWAY.fullmatch(parts[1]):
                    routes.append((parts[0], parts[1]))
    except FileNotFoundError:
        pass
    return routes


def publish(routes):
    os.makedirs(HOST_STATE_DIR, exist_ok=True)
    temporary = HOST_ROUTE_FILE + ".tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        for destination, gateway in routes:
            handle.write("{}|{}\n".format(destination, gateway))
    os.chmod(temporary, 0o666)
    os.replace(temporary, HOST_ROUTE_FILE)


last_signature = None
while True:
    try:
        stat = os.stat(ROUTE_FILE)
        signature = (stat.st_mtime_ns, stat.st_size)
    except FileNotFoundError:
        signature = (0, 0)
    if signature != last_signature:
        routes = read_routes()
        try:
            publish(routes)
            print("Published {} desired host route(s).".format(len(routes)), flush=True)
            last_signature = signature
        except OSError as error:
            print("Publishing desired host routes failed: {}".format(error), flush=True)
    time.sleep(0.25)
