"""Generate printable ArUco markers for automatic plane calibration.

    python make_markers.py                      # markers/marker_0..3.png, one per page
    python make_markers.py --sheet 0.18 0.12    # also a one-page sheet with a 18 x 12 cm rectangle

Setup: tape markers 0-3 at the corners of a rectangle on the plane your object moves in
(0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left, as the camera sees them), measure
the width and height between marker *centers*, and send
    {"type": "calibrate", "method": "aruco", "width_m": <width>, "height_m": <height>}
The printed marker size does not matter; only the center-to-center distances do.
For the one-page sheet, print at 100% / "actual size" and the rectangle is exact.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import cv2

from cv_engine.calibration import make_marker, make_marker_sheet


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out", default="markers", help="output folder")
    p.add_argument("--ids", type=int, nargs=4, default=[0, 1, 2, 3], metavar="ID")
    p.add_argument("--sheet", type=float, nargs=2, metavar=("WIDTH_M", "HEIGHT_M"),
                   help="also make a single sheet with markers on a rectangle of this size")
    p.add_argument("--dpi", type=int, default=300)
    args = p.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for mid in args.ids:
        cv2.imwrite(str(out / f"marker_{mid}.png"), make_marker(mid))
    print(f"wrote {len(args.ids)} markers to {out}/")

    if args.sheet:
        w, h = args.sheet
        sheet = make_marker_sheet(w, h, marker_size_m=min(0.04, w / 4, h / 4), dpi=args.dpi, marker_ids=tuple(args.ids))
        png = out / f"sheet_{w:g}x{h:g}m.png"
        cv2.imwrite(str(png), sheet)
        try:  # A PDF keeps the physical size when printed.
            from PIL import Image

            pdf = png.with_suffix(".pdf")
            Image.fromarray(sheet).save(pdf, resolution=args.dpi)
            print(f"wrote {png} and {pdf} (print at 100%)")
        except ImportError:
            print(f"wrote {png} (print at {args.dpi} dpi, 100%; pip install pillow for a PDF)")


if __name__ == "__main__":
    main()
