"""Run the backend on this laptop for a phone on the same Wi-Fi.

    python serve_lan.py

It prints the address to type into the app's Settings, then starts the same
server as the Dockerfile. On the same Wi-Fi a frame's round trip is about
20-40 ms, against 100-300 ms to the hosted free-tier server, so the app gets
the full 30 frames a second and keeps up with a fast ball.
"""

import argparse
import os
import socket
import sys

import uvicorn

HERE = os.path.dirname(os.path.abspath(__file__))

# What Windows gives itself when it shares a connection as a Mobile Hotspot.
WINDOWS_HOTSPOT = "192.168.137.1"


def lan_addresses():
    """This machine's IPv4 addresses that a phone could reach, best first."""
    found = []
    try:
        # Connecting a UDP socket sends nothing; it only picks the interface
        # the default route uses, which is normally the Wi-Fi.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("8.8.8.8", 80))
            found.append(probe.getsockname()[0])
    except OSError:
        pass  # No route out, e.g. a hotspot with no internet behind it.
    try:
        for *_, address in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            found.append(address[0])
    except OSError:
        pass
    usable = []
    for ip in found:
        # Loopback and link-local (no DHCP answer) are not reachable from a phone.
        if ip.startswith(("127.", "169.254.")) or ip in usable:
            continue
        usable.append(ip)
    return usable


def print_instructions(port):
    addresses = lan_addresses()
    print()
    if not addresses:
        print("No network address found. Connect this laptop to Wi-Fi first.")
    else:
        print("In the app, open Settings and enter this backend address:")
        for ip in addresses:
            note = "  (Windows Mobile Hotspot)" if ip == WINDOWS_HOTSPOT else ""
            print(f"    ws://{ip}:{port}/ws/frames{note}")
        if len(addresses) > 1:
            print("Use the one on the same network as the phone.")
        print()
        print("To check the phone can reach this laptop, open this in its browser:")
        print(f"    http://{addresses[0]}:{port}/health")
    print()
    print("If the phone can't connect:")
    print("  - Windows: allow Python through the firewall on private networks,")
    print("    and set this Wi-Fi to Private in Settings > Network & internet.")
    print("  - macOS: allow incoming connections for Python when asked.")
    print("  - Some venue Wi-Fi keeps devices apart. Turn on Mobile Hotspot on")
    print(f"    this laptop, join it from the phone, and use ws://{WINDOWS_HOTSPOT}:{port}/ws/frames.")
    print()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()

    print_instructions(args.port)
    # Same settings as the Dockerfile. One worker, because tracking and
    # calibration state live in the server process.
    uvicorn.run(
        "app:app",
        app_dir=HERE,
        host="0.0.0.0",
        port=args.port,
        workers=1,
        ws_max_size=1048576,
    )


if __name__ == "__main__":
    sys.exit(main())
