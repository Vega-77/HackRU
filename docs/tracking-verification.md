# Tracking change verification

Scope: the object-selection additions in calibration and the tracking recovery
change. This report does not claim a fresh audit of unrelated application screens.
The direction is the existing scientific instrument interface: ENERGY 1,
RHYTHM 2, MOTION 1. Rectangles describe the actual selected pixels; neutral marks
use the existing vellum/ink palette to avoid implying a physical force. Holding
the captured image lets the user check what the backend will initialize from.
Keyboard focus uses light and dark borders to remain visible over camera images.

Validation: 133 backend/physics tests and 122 Flutter tests passed; two optional
live-backend tests were skipped. Dart formatting and Flutter analysis passed.
The release web build completed. The widget tests exercise box drawing, frozen
selection, clearing, keyboard movement and resizing. The socket test checks the
first image bytes, original timestamp and ROI. The app-flow tests exercise setup,
experiment, settings, error handling, log copying and landscape layout.

## Antislop delivery gate

| Item | Status and evidence for this change |
| --- | --- |
| R-02 | PASS: new copy and comments use ordinary punctuation. |
| R-03 | PASS: existing wrapping step body and scroll layout retained; landscape app-flow test passed. |
| R-17 | PASS: copy contains no statistics or marketing metrics. |
| R-18 | PASS: no testimonials. |
| R-23 | PASS: selected image comes from the user's camera; no fabricated assets or navigation. |
| R-24 | PASS: no navigation links added. |
| R-25 | PASS: instructional text inherits the existing themed text style; image marks have a contrasting halo. |
| R-26 | PASS: drag, clear, Enter, arrows and resize keys are exercised in widget tests. |
| R-27 | PASS: existing camera loading/error states retained; failed capture is logged; Clear restores live preview. |
| R-28 | PASS: no FAQ. |
| R-32 | PASS: selection supports focus, Enter, arrows and resize keys; visible focus border and keyboard test added. |
| R-33 | PASS: changes written as source patches. |
| R-34 | PASS: theme behavior retained; added marks use established calibration colors. |
| R-35 | PASS: release web build and app-flow tests passed; new selection interactions exercised by widget tests. |
| R-36 | PASS: no fabricated security, customer or real-world tracking claims. |
| R-37 | PASS: existing scientific instrument direction retained; dials stated above. |
| R-38 | PASS: copy describes actual selection actions and their implemented behavior. |
| R-01 | PASS: no new gradients or glows. |
| R-04 | PASS: no new icons. |
| R-06 | PASS: typography inherits existing calibration styles for consistent measurement instructions. |
| R-07 | PASS: no decorative background patterns. |
| R-08 | PASS: no decorative button arrows. |
| R-09 | PASS: no badges. |
| R-10 | PASS: no blur or glass effects added. |
| R-12 | PASS: no shadows added. |
| R-13 | PASS: no glows added. |
| R-14 | PASS: no feature cards added. |
| R-19 | PASS: no new animations; picture holding serves selection accuracy. |
| R-22 | PASS: actual selected camera image provides the relevant visual. |
| Dials | PASS: calm measurement workflow retained; no new page composition or animation. |
| Focal point | PASS: selected object box is drawn over the captured measurement image. |
| Whitespace | PASS: existing calibration step spacing and scroll layout retained. |
| Accent | PASS: existing theme accent remains; object marks use neutral calibration colors. |
| Motif | PASS: box and focus marks extend the existing ruler/crosshair language. |
| Design read | PASS: scientific measurement setup for experiment users, using the existing instrument interface. |
| C-1 | PASS: selection rectangle, snapshot and focus borders each have functional reasons stated above. |
| C-2 | PASS: selection/clear/keyboard actions are implemented and tested. |
| C-3 | PASS: selection fits the existing calibration step; no filler sections. |
| C-4 | PASS: app-flow, landscape, selection and keyboard tests passed. |
| C-5 | PASS: generated sequences are explicitly synthetic; real experiments require validation. |
| R-05 | PASS: actual calibration content dictates the existing layout. |
| R-11 | PASS: ROI is rectangular to match frame coordinates; panel radii retained. |
| R-15 | PASS: Clear and Start experiment retain their specific actions. |
| R-16 | PASS: instructions name concrete gestures and expected behavior. |
| R-20 | PASS: existing instrument identity retained through calibration marks and typography. |
| R-21 | PASS: existing theme controls retained; no theme feature added or deferred. |
| R-29 | PASS: existing neutral calibration palette retained. |
| R-30 | PASS: no product imitation or external visual template introduced. |
| R-31 | PASS: major added UI decisions have reasons in the opening paragraph. |

## Limits

There are no real bottle/ball recordings in the supplied diagnostic package.
Replay and synthetic regressions verify the reproduced mechanisms, not tracking
recall under arbitrary clutter, lighting, rotation or indistinguishable objects.
The replay tool reports processing throughput; it cannot measure live network
delay or capture-to-overlay age from offline images.
