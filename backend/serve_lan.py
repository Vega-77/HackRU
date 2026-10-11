"""Run the backend on this laptop for a phone on the same Wi-Fi.

    python serve_lan.py
    python serve_lan.py --tunnel

It prints the address to type into the app's Settings, then starts the same
server as the Dockerfile. On the same Wi-Fi a frame's round trip is about
20-40 ms, against 100-300 ms to the hosted free-tier server, so the app gets
the full 30 frames a second and keeps up with a fast ball.

The web app is an https page, so it can only reach a wss:// address.
--tunnel also starts a free Cloudflare quick tunnel (needs cloudflared, for
example `winget install Cloudflare.cloudflared`) and prints its wss://
address, which the web app can use. That goes through Cloudflare: about
35 ms on a good connection. The address changes every time it starts.
"""

import argparse
import os
import re
import shutil
import socket
import subprocess
import sys
import threading

import uvicorn

HERE = os.path.dirname(os.path.abspath(__file__))

# What Windows gives itself when it shares a connection as a Mobile Hotspot.
WINDOWS_HOTSPOT = "192.168.137.1"

# Where the winget and MSI installs put cloudflared, for a shell opened before
# the install added it to PATH.
CLOUDFLARED_PATHS = (
    r"C:\Program Files (x86)\cloudflared\cloudflared.exe",
    r"C:\Program Files\cloudflared\cloudflared.exe",
)
TUNNEL_URL = re.compile(r"https://[a-z0-9-]+\.trycloudflare\.com")


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
        print("For the iPhone app on the same Wi-Fi, enter this in its Settings:")
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


def find_cloudflared():
    found = shutil.which("cloudflared")
    if found:
        return found
    return next((path for path in CLOUDFLARED_PATHS if os.path.isfile(path)), None)


def start_tunnel(port):
    """Starts a quick tunnel to the server and prints its address once
    Cloudflare gives one. Returns the process, or None without cloudflared."""
    cloudflared = find_cloudflared()
    if cloudflared is None:
        print("--tunnel needs cloudflared. Install it with")
        print("    winget install Cloudflare.cloudflared")
        print("then open a new terminal and try again.")
        return None
    process = subprocess.Popen(
        [cloudflared, "tunnel", "--no-autoupdate", "--url", f"http://localhost:{port}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        errors="replace",
    )

    def watch():
        shown = False
        # Keep reading even after the address is shown: cloudflared logs to
        # stderr for as long as it runs, and a full pipe would stall it.
        for line in process.stderr:
            match = TUNNEL_URL.search(line)
            if match and not shown:
                shown = True
                address = match.group(0).replace("https://", "wss://", 1) + "/ws/frames"
                print()
                print("For the web app (and the iPhone app anywhere online), enter:")
                print(f"    {address}")
                print("It can take a minute before the address works.")
                print()
            elif " ERR " in line:
                print("cloudflared:", line.rstrip())
        if not shown:
            print("cloudflared stopped before it gave an address.")

    threading.Thread(target=watch, daemon=True).start()
    return process


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--tunnel", action="store_true",
                        help="also give the server a wss:// address through a Cloudflare quick tunnel")
    args = parser.parse_args()

    print_instructions(args.port)
    tunnel = start_tunnel(args.port) if args.tunnel else None
    if args.tunnel and tunnel is None:
        return 1
    try:
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
    finally:
        if tunnel is not None:
            tunnel.terminate()


if __name__ == "__main__":
    sys.exit(main())
