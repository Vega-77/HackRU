# Tap acquisition and initialization verification

Work is on devFour. Main and deployment require the user's real gray-ball verification.

## Method selection

`backend/benchmark_acquisition.py` compares 12 labeled synthetic fixtures:
gray, white, black and red balls tapped at their center and near their edge,
a brightness gradient, a bottle silhouette, an empty image and insufficient contrast.
Images with objects pass through JPEG encoding/decoding. A correct proposal must
have bounding-box intersection-over-union of at least 0.7 against the labeled object;
the two negative fixtures must return no region. These are fixture results,
not estimates of camera accuracy. Timings are local single-thread measurements.

| Method | Correct fixtures | Median processing time |
| --- | --- | --- |
| Stable Lab region growing with contour fallback and ambiguity checks | 12/12 | 3.62 ms |
| Enclosing contours alone | 10/12 | 3.01 ms |
| Fixed-range seed flood fill alone | 12/12 | 0.79 ms |
| Tap-seeded GrabCut, three iterations | 2/12 | 34.66 ms |

The selected method grows only the connected region containing the tapped pixel.
It checks stability across Lab tolerances 8, 12 and 18, and rejects border leakage,
regions smaller than 8 pixels per side or larger than 35% of the image, and strongly
nested competing boundaries. Contours use all Lab channels rather than named HSV
colors. JPEG edge rims within three pixels are grouped; distinct nested regions
request a manual box. The proposal includes the object's boundary transition for
the unchanged appearance tracker. The user confirms the box before an experiment.

GrabCut was tested with tap-based foreground seeds and background at the image
border; no object box was supplied. Its weak results apply to that initialization,
not to GrabCut with a useful user-supplied rectangle. Region growing was selected
because it was simpler, faster and more reliable on this fixture set. Other scenes
may need a manual box; no universal segmentation claim is made.

OpenCV references: [flood fill and GrabCut](https://docs.opencv.org/4.13.0/d7/d1b/group__imgproc__misc.html),
[contour extraction](https://docs.opencv.org/4.x/d4/d73/tutorial_py_contours_begin.html).

## Handshake and tests

Acquisition and initialization bypass the latest-frame mailbox. The initialization
image is decoded and processed under the pipeline lock before the receiver accepts
more image messages. Initialization echoes the selection ID, frame ID and capture
timestamp, and always reports `tracked: false`. The frontend waits for a matching
acknowledgment before capturing or sending live frames. The server rejects ordinary
frames until required initialization succeeds. Failure allows another initialization
request. Regular live frames still use the replaceable mailbox.

153 backend/physics tests passed, including neutral/red acquisition, near-edge taps,
empty/ambiguous scenes, incorrect image dimensions, rapid initialization/live frames,
same-connection retry and vertical/horizontal identity checks. The identity tests
assert target coordinates, source, bounds and unchanged original reference data.

128 Flutter tests passed; two optional live-backend tests were skipped. Analysis and
formatting passed. Tests exercise confirmation, retry, manual fallback on the same
held image, original JPEG/timestamp transport, gating until acknowledgment, rejection
of unrelated acknowledgments, initialization failure and a new attempt after failure.
Phone layout tests caught and resolved a confirmation-control overflow.

## Real gray-ball test

1. Open the local app and select Pendulum.
2. Hold the gray ball still and visible, then tap its center in calibration.
3. Inspect the proposed box on the frozen image. Confirm object only if it contains
   the whole ball with little background. Otherwise draw a better box, or choose
   Retry selection to return to the live image and tap again.
4. Start experiment, keep the ball visible until a later image confirms detection,
   then test vertical and horizontal motion and the pendulum swing.
5. Copy the diagnostic log, noting whether automatic proposal and subsequent
   detection succeeded. A manual fallback must be recorded separately from success
   of automatic acquisition. Log messages contain numeric decisions, not saved images.

No real camera images or ball recording were available for automated verification.
Boundaries under blur, clutter, hand contact, weak contrast and indistinguishable
objects still require live testing. Synthetic success does not establish reliability.
