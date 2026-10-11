# Kinetic Laboratory: home and investigation selection

## Scope and rollback

Home composition, investigation index, illustrative diagrams, and home controls only. Experiment settings and existing routes are reused. Tracking, physics calculations, backend services, WebSocket messages, calibration, and live experiment code were not edited for this task.

The UI is isolated in one commit on `devFour`, titled **Redesign home as the Kinetic Laboratory**. Revert that commit to restore the original home layout. No merge or deployment is part of this change.

## Design decisions

- Two unequal columns connect choosing an investigation with seeing its physics, using the desktop canvas rather than a 560 px column.
- Archivo's wide display cut gives the introduction an editorial voice; condensed tabular figures distinguish model readouts from prose.
- Charcoal keeps attention on apparatus and vectors, matching the approved scientific instrument identity.
- Warm orange identifies selection and the camera setup action; green, red, blue, and yellow retain their existing physics meanings.
- Indexed rows support comparison without a repeated card grid; the four drawn symbols depict each investigation's actual apparatus or motion.
- The measured span, hatched surfaces, angle arcs, and equations are scientific annotations with a purpose, rather than page wallpaper.
- Motion and force views separate quantities that would otherwise obscure one another. Ramp weight projections replace the weight arrow rather than double counting it.
- Pause preserves elapsed model time. Replay resets a running model, or shows a representative static pose under reduced motion.
- A 260 ms mode transition connects selection with a new diagram; reduced motion disables the model ticker and mode transition.
- Readouts reflow with width and text scaling so labels and units remain readable on small phones.
- The metadata strip communicates selected concepts, measurement method, and the configured backend. It makes no connection-success claim.
- The existing backend and calibration actions retain their routes. Home remains usable before camera permission or a backend connection.

Design Read: an interactive laboratory for students, using editorial typography and scientific diagrams. **ENERGY 2 / RHYTHM 3 / MOTION 2.**

## Model provenance

`PreviewPhysics.sample` and `PreviewPhysics.scenery` supply the existing model positions, velocities, accelerations, forces, and moving apparatus. Their implementations were not changed. Readouts use a model mass of 0.10 kg and SI units. Vector categories use separate stated display scales; the scale bar measures diagram geometry.

- Free fall depicts an upward launch with horizontal velocity and no air resistance, not a stationary release. Gravity is constant during flight; supported landing gives zero net acceleration.
- Ramp depicts a 25 degree incline with friction coefficient 0.15 and an end stop.
- Pendulum uses the existing nonlinear integrated model at a 35 degree release and 0.45 m length. Total acceleration includes its radial component.
- Collision uses the existing idealized elastic impact between masses m and 2m, with rolling friction between impacts. The second body's velocity arrow follows its scenery motion. Readouts describe the first body. The finite contact interval is an illustrative approximation; the equation describes momentum across the ideal impact.

These are explicitly labeled **Illustrative model**. They are not camera measurements or evidence about real-object tracking reliability.

## Verification environment

The workspace already contained unrelated, uncommitted calibration changes that cannot compile (`caimport` and references to removed demo APIs). Those edits and the preexisting iOS project change were preserved.

Verification used `/private/tmp/hop-home-ui-review`, a detached checkout of `ba68d28`, with the exact home and test changes copied in. A directory comparison confirmed matching home sources. The checkout uses the committed calibration screen. The locally served preview therefore uses committed calibration, not those pending calibration edits.

Commands run from that checkout's `mobile` directory:

```sh
flutter analyze
flutter test
flutter build web --dart-define=BACKEND_URL=ws://127.0.0.1:8000/ws/frames
```

Analysis: **no issues**. Full Flutter suite: **137 passed**, two live-backend tests skipped by their existing environment guard. Web release build: **succeeded**. The existing build warning about a Cupertino font family remains; the new controls use bundled Material icons, inspected in the screenshots.

Nine new home regression tests cover all four selections and both vector views at 1440, 960, 844, 390, and 320 px; pause/resume/replay; reduced motion; 1.6x text; and Tab/Enter selection. Existing camera, calibration, settings, protocol, and physics preview tests also pass. Existing flow tests now scroll to the setup action on phones.

Chrome click-through exercised all four investigation rows, both vector layers for each, pause, play, replay, Settings, the backend link, and camera setup. Camera setup showed the existing permission-error/retry state in headless Chrome. No uncaught browser exceptions were recorded. Browser reduced-motion emulation held model time at 0.42 s across an 800 ms observation; both system color-scheme preferences retained the scoped charcoal design. Physical camera testing is not established by this UI review.

## Screenshots

- [Desktop free fall](home-review/desktop-free-fall.png)
- [Desktop ramp with force components](home-review/desktop-ramp-forces.png)
- [Desktop pendulum](home-review/desktop-pendulum.png)
- [Desktop collision](home-review/desktop-collision.png)
- [Desktop focus state](home-review/desktop-focus.png)
- [Phone investigation index](home-review/mobile-index.png)
- [Phone pendulum force view](home-review/mobile-pendulum-forces.png)
- [320 px phone exhibit](home-review/small-phone-exhibit.png)
- [960 px desktop](home-review/desktop-960.png)
- [Reduced motion under a light system preference](home-review/desktop-reduced-light-system.png)

The screenshot review caught and corrected a missing subscript-y glyph, a force-legend overflow, crowded small-phone readouts, insufficient diagram space on phones, and a metadata rule that did not span the desktop layout.

## Antislop delivery gate

### Hard gate

- R-02 PASS: source scan found no em dashes in new home copy or comments.
- R-03 PASS: all modes and vector layers pass layout tests at five viewport sizes; inspected 390 and 320 px browser screenshots.
- R-17 PASS: no invented statistics; model numbers come from the existing calculations and are labeled illustrative.
- R-18 PASS: no testimonials or fabricated people.
- R-23 PASS: the user explicitly requested scientific symbols, diagrams, layout, and interactions; no fabricated logos, photos, or social proof were added.
- R-24 PASS: Settings and setup use existing routes; both were clicked in Chrome and existing flow tests pass.
- R-25 PASS: token contrast was calculated against page, diagram, and focus surfaces; normal text's lowest ratio is 4.58:1 (muted text on focus surface), accent button text is 8.49:1. Physics colors are strokes, not small text.
- R-26 PASS: all index rows, vector selectors, play/pause, replay, Settings, setup, and backend link have real handlers and were exercised.
- R-27 PASS: home uses a complete local model catalog without an asynchronous loading state; existing camera permission error/retry was observed and calibration acquisition failure tests pass.
- R-28 PASS: no FAQ added.
- R-32 PASS: Tab/Enter selection passes; focus uses a light edge and distinct surface, captured in Chrome. Controls have labels and standard keyboard actions.
- R-33 PASS: features are Dart widgets and painters in source; vector-layer rendering was authored directly in the painter. No injected styles or runtime source-rewriting dependency is shipped.
- R-34 PASS: home intentionally uses the approved charcoal theme even under the surrounding light theme; no theme toggle was added or broken.
- R-35 PASS: analysis, full tests, and web build succeeded; Chrome ran the application and exercised every home control.
- R-36 PASS: no security, compliance, customer, or performance claims added.
- R-37 PASS: approved direction and dials were declared before implementation.
- R-38 PASS: investigation names, routes, quantities, and capabilities come from the existing application; illustrations are explicitly models.

### Purpose gate

- R-01 PASS: no gradients added.
- R-04 PASS: symbols depict each investigation; tuning, transport, and replay icons describe their controls.
- R-06 PASS: Archivo's width and tabular figures serve editorial headings and measured values; no terminal aesthetic or widely tracked labels.
- R-07 PASS: no page background grid; scale bars and apparatus lines communicate geometry.
- R-08 PASS: no decorative CTA arrows.
- R-09 PASS: no promotional badges.
- R-10 PASS: no glassmorphism.
- R-12 PASS: no decorative elevation shadows.
- R-13 PASS: no glow effects.
- R-14 PASS: indexed rows replace feature cards; the large diagram is the selected investigation's distinct presentation.
- R-19 PASS: motion explains physical behavior and selection; pause and reduced-motion tests pass.
- R-22 PASS: illustrations are sourced from the four existing physics models, with requested scientific symbols.

### Liveliness

- Dials PASS: ENERGY 2 / RHYTHM 3 / MOTION 2 stated and reflected in the headline, unequal columns, index, model motion, and metadata strip.
- Focal point PASS: the large headline anchors the initial composition; the diagram becomes the active investigation focus.
- Whitespace PASS: gutters divide selection from visualization; intervals separate explanation, controls, and camera setup.
- Accent PASS: warm orange marks active selection and the primary action; other colors mean physical quantities.
- Motif PASS: measured spans, drafting surfaces, numbered investigations, and equations repeat across scenes.
- Design Read PASS: declared before source edits and recorded above.

### Craftsmanship and quality locks

- C-1 PASS: major decisions have reasons recorded above.
- C-2 PASS: every home control has tested behavior.
- C-3 PASS: sections support choosing, understanding, or starting a physics investigation.
- C-4 PASS: responsive, enlarged-text, reduced-motion, and keyboard cases pass; home does not depend on camera/backend availability.
- C-5 PASS: displayed values are identified as illustrative model results.
- R-05 PASS: unequal editorial columns, indexed selection, one scientific stage, and a metadata strip implement the user's content-specific composition.
- R-11 PASS: control radii reuse tokens; the diagram and index use ruled surfaces, not repeated rounded cards or pills.
- R-15 PASS: the primary action names the selected experiment and opens camera setup.
- R-16 PASS: copy describes motion, selection, and measurement without marketing buzzwords.
- R-20 PASS: scientific apparatus, equations, projections, and variable-width typography establish the requested identity.
- R-21 PASS: charcoal is explicitly requested for the laboratory and supports quantity-color diagrams; other screens' themes were not edited.
- R-29 PASS: neutral chrome and warm orange form the brand palette; the existing four quantity colors retain semantic use.
- R-30 PASS: composition follows the user's scientific laboratory brief rather than a named product clone.
- R-31 PASS: color, layout, type, spacing, row selection, symbols, scientific drawing, and motion reasons are documented above.
