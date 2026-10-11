# Calibration: measurement workspace

## Scope and preservation

The calibration camera, measurement panel, readouts, selection drawing, and their presentation states were redesigned. Calibration controllers, mass calculations, coordinate mapper, camera implementations, acquisition client, session initialization, tracker, backend, physics calculations, and WebSocket protocol were not edited.

Gesture callbacks, endpoint grab offsets, angle snapping, loupe behavior, tap capture, held selection frame, rectangle generation, keyboard adjustment, confirmation callbacks, mass increments, centimetre conversion, and range validation retain their committed implementations. Layout changes alter the available camera viewport; the existing mapper still accounts for that viewport and the same `BoxFit.cover`.

The preexisting local calibration file was broken: it began with `caimport` and referenced removed demo APIs. Its exact contents were saved at `diagnostics/backups/calibration_screen.before_measurement_redesign.dart.txt` before restoring the working committed calibration flow and applying this redesign. That backup remains local. The unrelated iOS project edit is preserved.

This change is isolated on `devFour` in **Redesign calibration as a measurement workspace**. Reverting that commit restores the working committed calibration interface. No push, merge, or deployment accompanies this task.

## Design decisions

Design Read: a camera-led measurement workspace for students, using the Kinetic Laboratory's charcoal, warm orange, and precise typography. **ENERGY 2 / RHYTHM 2 / MOTION 2.**

- The camera occupies the main desktop canvas because students need to see the actual apparatus while making measurements.
- A 360 px panel separates reference distance, object region, and mass without turning them into a grid of settings cards.
- The real three-step flow, or four steps with AR surface finding, is numbered plainly; ruled sections and available-state checks reveal progress.
- Charcoal surrounds the image without applying a tint to it; warm orange identifies active endpoints, accepted selection, and the experiment action.
- Archivo's wide headings establish the instrument identity; condensed tabular readouts make changes in scale and mass easy to compare.
- Short labels, separate units, and source pixel dimensions distinguish measurements from instructions.
- Ruler endpoint centres remain exact; A/B labels and contrasting outlines make those centres visible on dark and bright footage.
- Selection corners emphasize the object's extent without masking the surrounding camera image or placing a crosshair over an accepted object.
- Corner marks describe the rectangle; existing redraw and keyboard adjustment remain its interaction. No new resize-handle behavior is implied.
- Small camera viewports use the status strip instead of an additional region label, preventing collisions with ruler annotations.
- Phone portrait keeps the camera fixed above a scrolling panel and pinned start action; landscape phones use camera and panel side by side.
- Panel heading and count occupy separate lines, and workspace annotations align with the camera edge.
- Available-section surfaces and selection labels transition over 260 ms to acknowledge state changes; reduced motion makes these transitions immediate.
- Selection status derives from existing calibration state. “Region confirmed” means the user approved its extent, not that the backend has verified tracking.
- “Initializing experiment” is only shown for the actual session `starting` phase; acquisition pending is labeled “Finding boundary.”
- Acquisition errors retain their actionable backend message and retry action; camera errors expose the existing camera restart handler.

## Automated verification

Commands run from `mobile`:

```sh
flutter analyze
flutter test
flutter test test/widgets/calibration_measurement_test.dart test/widgets/app_flow_test.dart test/features/object_selection_test.dart test/features/coordinate_mapper_test.dart test/features/mass_steps_test.dart
flutter build web --output /private/tmp/hop-calibration-production --dart-define=BACKEND_URL=ws://127.0.0.1:8000/ws/frames
flutter build web --target tool/calibration_review.dart --output /private/tmp/hop-calibration-web --no-wasm-dry-run
```

Full Flutter suite: **147 passed**, two existing live-backend tests skipped by their environment guard. Following screenshot-driven layout adjustments, the relevant interaction suite passed **34 tests**. Analysis found **no issues**.

Ten new tests cover selection states at 1440×1000, 960×800, 390×844, 320×568, and 844×390; held-frame identity through confirmation; selection error and retry; ruler dragging and exact scale calculation; comma-decimal entry and invalid-value preservation; camera retry; existing mass increments; 1.6× text at 320 px; and a truthful initialization-phase annotation. Existing tests verify manual box selection, keyboard position/size adjustment, coordinate mapping, AR surface finding, navigation, and shared camera lifecycle.

The ruler regression deliberately crosses the pan threshold before moving to its destination, preserving the existing grab-offset behavior rather than changing gesture logic to suit a simplified test.

The development-only entry point `tool/calibration_review.dart` provides a **labeled synthetic UI camera**, bright/dark fixture variants, a local backend address, and controlled selection/error states. Production `main.dart` does not import it. These fixtures verify presentation and interaction only; they do not establish real-camera acquisition or tracking reliability.

## Browser review and screenshots

Release builds of the actual app and UI fixture succeeded. The existing Cupertino font-family warning remains; the redesigned controls use the bundled Material and Phosphor fonts. Headless Chrome reports CPU rendering because WebGL is unavailable in that environment.

Chrome click-through exercised reference-length editing, invalid-length recovery, mass increase/decrease (100 g → 110 g → 100 g), ruler dragging, tap proposal, manual rectangle drawing, confirmation, selection retry, camera retry, acquisition-error retry, starting the experiment, returning to setup, and returning home. Phone confirmation and mass controls were also exercised. Keyboard selection and region adjustment pass the existing interaction test; AR Find uses its existing tested flow.

The browser review initially exposed a fixture-only missing `Directionality`, crowded header/count composition, misaligned workspace labels, overlapping small-camera annotations, and a cramped landscape-phone camera. All were corrected before delivery. Section semantics now expose controls independently rather than merging the entire measurement into a field or slider.

For physical mouse gestures, the review harness bypassed Chrome's accessibility tap overlay over the camera only; otherwise that overlay substitutes a centre tap for a drag. The application source was not altered by the harness. Measurement controls were exercised through their real rendered controls and semantic nodes.

- [Desktop proposed region](calibration-review/desktop-selected.png)
- [Desktop confirmed region after clicking](calibration-review/desktop-confirm-click.png)
- [960 px workspace](calibration-review/desktop-960.png)
- [Acquisition pending](calibration-review/desktop-pending.png)
- [Acquisition error and retry](calibration-review/desktop-error.png)
- [Invalid length preserves the last valid scale](calibration-review/desktop-invalid-length.png)
- [Manual rectangle after endpoint adjustment](calibration-review/desktop-drag-selection.png)
- [Bright camera background](calibration-review/bright-selected.png)
- [Phone selected object](calibration-review/phone-selected.png)
- [Phone confirmation controls](calibration-review/phone-selection-controls.png)
- [Phone confirmed region and mass](calibration-review/phone-mass-controls.png)
- [320 px phone](calibration-review/small-phone.png)
- [Landscape phone](calibration-review/landscape-phone.png)
- [Camera failure](calibration-review/camera-error.png)
- [Production camera permission state](calibration-review/production-camera-permission.png)

## Local preview

The actual application is served at **http://127.0.0.1:8083** and configured for the existing local backend at port 8000; `/health` returned `status: ok`. Select an experiment, open camera setup, allow camera access, align endpoints A/B with a real reference distance, enter that distance in centimetres, select and confirm the object, and enter its mass. The separate fixture server at 8082 is for layout review only.

## Antislop delivery gate

### Hard gate

- R-02 PASS: the changed calibration sources, review fixture, and test copy contain no em dashes.
- R-03 PASS: five viewport tests and enlarged-text tests pass; desktop, 390 px, 320 px, and landscape screenshots were reviewed and annotation collisions fixed.
- R-17 PASS: displayed scale and pixel dimensions come from calibration state and the selected frame, with no invented statistics.
- R-18 PASS: no testimonials or fabricated people.
- R-23 PASS: the user explicitly requested endpoints, selection marks, and technical annotations; the synthetic screenshot source is visibly labeled UI fixture.
- R-24 PASS: Back and Start experiment retain existing route handlers, exercised in interaction tests and Chrome.
- R-25 PASS: computed contrast is 6.15:1 for muted text on the raised panel, 4.58:1 on a focus surface, 8.49:1 for accent against deep charcoal, and 15.57:1 for camera-label text. Camera marks use paired dark/light outlines; text labels have opaque contrasting backgrounds.
- R-26 PASS: length validation, both mass actions, ruler drag, tap, rectangle drawing, confirmation, retry, camera restart, and navigation retain real handlers and were exercised. Corner marks are not advertised as new resize controls.
- R-27 PASS: incomplete, acquisition pending, proposed, confirmed, acquisition error, camera opening/error, and actual initialization states are represented; failure retries are tested.
- R-28 PASS: no FAQ added.
- R-32 PASS: existing keyboard selection/movement/resize tests pass, controls retain Material keyboard focus behavior, field errors have a visible outline, and independent control semantics were inspected.
- R-33 PASS: all shipped UI is authored as Dart widgets and painters using source patches; browser scripts are review tooling, not injected application features.
- R-34 PASS: the screen deliberately scopes the requested charcoal theme; no theme toggle was added or altered.
- R-35 PASS: analysis, full Flutter tests, final relevant interaction tests, release builds, screenshots, and a recorded control click-through were completed.
- R-36 PASS: no security, compliance, performance, or customer claims added.
- R-37 PASS: the user's scientific measurement direction and the Design Read preceded edits.
- R-38 PASS: actual application states and quantities are used; fixture imagery and proposals are explicitly identified as UI review data.

### Purpose gate

- R-01 PASS: no gradients added.
- R-04 PASS: checks mean available measurement state; plus/minus change mass; Back returns along existing navigation.
- R-06 PASS: Archivo preserves the laboratory identity, with tabular figures for quantities and sentence-case labels for legibility.
- R-07 PASS: no decorative background grid or fake HUD.
- R-08 PASS: only the functional Back arrow remains; no decorative CTA arrows.
- R-09 PASS: status is plain text describing actual state, with no promotional badges.
- R-10 PASS: no glassmorphism or camera blur added.
- R-12 PASS: the existing loupe shadow separates a magnified endpoint from the image; panels and controls do not float on decorative shadows.
- R-13 PASS: no glows added.
- R-14 PASS: ruled measurement sections follow the real sequence; field, selection actions, and mass stepper differ according to their task.
- R-19 PASS: 260 ms surface/status transitions acknowledge acceptance and become immediate under reduced motion; no decorative animation obscures the camera.
- R-22 PASS: no generic illustrations; the synthetic camera image exists only in the labeled development fixture.

### Liveliness

- Dials PASS: ENERGY 2 / RHYTHM 2 / MOTION 2 are explicit and expressed through the camera-led composition, instrument typography, different measurement controls, and restrained acceptance transitions.
- Focal point PASS: the camera and marked object remain the dominant workspace.
- Whitespace PASS: panel gutters separate instructions from controls, while camera margins leave space for actual apparatus.
- Accent PASS: orange marks acceptance and the experiment action; the surrounding UI is neutral.
- Motif PASS: A/B dimension endpoints, indexed measurements, tabular values, and object corner brackets repeat the precision-instrument vocabulary.
- Design Read PASS: declared before implementation and recorded above.

### Craftsmanship and quality locks

- C-1 PASS: major decisions have one-line reasons above.
- C-2 PASS: controls preserve tested handlers and failure recovery.
- C-3 PASS: camera, scale, object, and mass are the actual preparation tasks.
- C-4 PASS: phone, desktop, landscape, enlarged text, camera failure, selection failure, and keyboard cases are covered by review or interaction tests.
- C-5 PASS: confirmed region is distinguished from verified tracking; synthetic success is not presented as real-camera reliability.
- R-05 PASS: content drives a camera workspace with a measurement panel, not a landing-page or dashboard template.
- R-11 PASS: camera annotations use small rectangular corners, controls reuse token radii, and sections use rules instead of pills.
- R-15 PASS: Confirm object, Retry selection, and Start experiment describe their actions.
- R-16 PASS: copy names measurements and recovery actions without marketing buzzwords.
- R-20 PASS: camera dimensions, exact ruler centres, region brackets, and large unit-aware values give the screen a scientific instrument identity.
- R-21 PASS: charcoal and orange are the explicitly approved brand foundations; camera imagery remains unfiltered.
- R-29 PASS: neutral surfaces plus one orange accent; semantic physics colors were preserved and not repurposed.
- R-30 PASS: the design follows the HandsOnPhysics measurement brief, with no named-product clone.
- R-31 PASS: layout, typography, palette, spacing, annotation, selection, and transition reasons are documented above.
