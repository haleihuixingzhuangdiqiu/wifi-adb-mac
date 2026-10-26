#!/usr/bin/python3
"""Isolated acceptance fixture. No real ADB/device/network calls; fake PIN only."""
import json
import os
import pathlib
import sys
import time

root = pathlib.Path(os.environ.get("WIFIADB_MOCK_DIR", "/tmp/wifiadb-mock"))
root.mkdir(parents=True, exist_ok=True)
path = root / "state.json"
default = {
    "ports": {"vivo-demo-001": 37123, "xiaomi-demo-002": 37124},
    "connected": [], "hidden": [], "pairing": ["vivo-demo-001", "xiaomi-demo-002"],
    "models": {"vivo-demo-001": "vivo_X100", "xiaomi-demo-002": "Xiaomi_14"},
    "hosts": {"vivo-demo-001": "192.168.50.21", "xiaomi-demo-002": "192.168.50.22"},
}
state = json.loads(path.read_text()) if path.exists() else default

def save():
    temporary = root / ("state-%s.tmp" % os.getpid())
    temporary.write_text(json.dumps(state, ensure_ascii=False, indent=2))
    temporary.replace(path)

def endpoint(serial):
    return "%s:%s" % (state["hosts"][serial], state["ports"][serial])

def service_name(serial):
    return state.get("service_names", {}).get(serial, "adb-%s-XYZ" % serial)

def transport_name(serial):
    return state.get("transport_names", {}).get(serial, endpoint(serial))

def get_serial(transport):
    for serial in state["ports"]:
        if transport in (endpoint(serial), service_name(serial) + "._adb-tls-connect._tcp", transport_name(serial), serial):
            return serial
    return None

args = sys.argv[1:]
if not args:
    sys.exit(1)
# Never persist stdin or pair argument payloads; only public fixture operations.
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps({"action": args[0], "args": args[:2] if args[0] == "pair" else args}) + "\n")
if state.get("delay"):
    time.sleep(float(state["delay"]))
if args[0] == "version":
    print("Android Debug Bridge version 1.0.41\nVersion 36.0.0-fixture\nInstalled as " + __file__)
elif args[0] == "devices":
    print("List of devices attached")
    for serial in state["connected"]:
        status = state.get("status", {}).get(serial, "device")
        print("%-22s %s product:fixture model:%s device:fixture transport_id:1" % (transport_name(serial), status, state["models"][serial]))
    for line in state.get("extra_transports", []):
        print(line)
elif args[:2] == ["mdns", "services"]:
    if state.get("mdns_error"):
        print("error: mDNS backend unavailable", file=sys.stderr)
        sys.exit(1)
    print("List of discovered mdns services")
    for serial in state["ports"]:
        if serial not in state["hidden"]:
            print("%s\t_adb-tls-connect._tcp.\t%s" % (service_name(serial), endpoint(serial)))
            if serial in state["pairing"]:
                print("adb-%s-XYZ\t_adb-tls-pairing._tcp.\t%s:%d" % (serial, state["hosts"][serial], state["ports"][serial] + 1000))
    for line in state.get("extra_services", []):
        print(line)
elif args[0] == "connect":
    serial = get_serial(args[1])
    if serial and serial not in state.get("unreachable", []):
        if serial not in state["connected"]:
            state["connected"].append(serial)
        save()
        print("connected to " + args[1])
    else:
        print("failed to connect to '%s': Connection refused" % args[1])
elif args[0] == "disconnect" and len(args) == 2:
    serial = next((item for item in state["connected"] if transport_name(item) == args[1]), None)
    if serial is None or state.get("disconnect_error"):
        print("error: no such device", file=sys.stderr)
        sys.exit(1)
    state["connected"].remove(serial)
    save()
    print("disconnected " + args[1])
elif args[0] == "pair":
    pin = sys.stdin.readline().strip()
    if pin == "123456":
        print("Successfully paired to %s [guid=adb-demo]" % args[1])
    else:
        print("error: protocol fault (couldn't read status message): Undefined error: 0", file=sys.stderr)
        sys.exit(1)
elif len(args) >= 5 and args[0] == "-s" and args[2:4] == ["shell", "getprop"]:
    serial = get_serial(args[1])
    if not serial or serial not in state["connected"]:
        print("error: device offline", file=sys.stderr)
        sys.exit(1)
    props = {"ro.serialno": serial, "ro.boot.serialno": serial, "ro.product.model": state["models"][serial].replace("_", " ")}
    print(props.get(args[4], ""))
else:
    print("unsupported fixture command", file=sys.stderr)
    sys.exit(1)
if not path.exists():
    save()
