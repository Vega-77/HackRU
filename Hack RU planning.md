# **HandsOn Physics: Real-Time Vector Overlay & Kinematics Debunker**

## **System Overview & Core Concept**

**HandsOn Physics** is an augmented reality (AR) physics assistant that transforms physical tabletop experiments into dynamic, real-time visual simulations. By pointing a smartphone or tablet camera at physical objects in motion—such as a rolling ball down a ramp, a swinging pendulum, or colliding carts—the app tracks object position, computes real-time kinematic metrics, and projects dynamic, color-coded 3D vector overlays (velocity, acceleration, gravity, normal force, friction, and tension) directly onto the live camera stream.

## **Technical Architecture & Data Flow**

\[ Mobile Device Camera \] 

         │ (30–60 FPS RGB Video Stream)

         ▼

\[ Mobile Frame Downsampler & AR Anchor \]

         │ (JSON Payload \+ Lower-Res Image Stream via WebSockets)

         ▼

\[ FastAPI Backend / Computer Vision Engine \]

         ├── 1\. MediaPipe / OpenCV Object Tracking (2D Bounding Boxes / Centroids)

         ├── 2\. Spatial Mapping Engine (Pixel Coords ➔ Real-World Metric World Coords)

         └── 3\. NumPy Kinematics Engine (Noise Filtering ➔ Derivatives ➔ Force Calculations)

         │

         ▼ (Low-Latency Vector & State Coordinates JSON)

\[ Flutter Frontend / AR Renderer \]

         ├── CustomPainter / ARCore / ARKit Vector Overlay Layer

         └── Real-Time Telemetry & Graphing Panel (FlChart)

## **Core Feature Specifications**

### **1\. Multi-Mode Physics Tracker**

* **Free Fall & Projectile Motion**: Tracks a tossed or dropped object, calculating $y(t)$, ${v}_{y}(t)$, and gravity vector validation ($\approx 9.81m/{s}^{2}$).  
* **Inclined Plane / Ramp Dynamics**: Detects ramp angle $\theta$, calculates components of gravitational force (${F}_{g\parallel }=mg\sin \theta$, ${F}_{g\bot }=mg\cos \theta$), normal force (${\vec{F}}_{N}$), and dynamic friction coefficient (${\mu }_{k}$).  
* **Pendulum & Simple Harmonic Motion (SHM)**: Tracks angular displacement $\theta (t)$, tangential velocity (${\vec{v}}_{\theta }$), and restoring tension force ($\vec{T}$).  
* **1D Linear Collisions**: Tracks two colliding objects to calculate momentum conservation ($\Delta p$) and coefficient of restitution ($e$).

### **2\. Dynamic AR Overlay**

* **Velocity Vectors ($\vec{v}$)**: Rendered in **Green**, scaling dynamically with magnitude \$\\vert{}\\vec{v}\\vert{}\$.  
* **Acceleration Vectors ($\vec{a}$)**: Rendered in **Red**, derived from the second derivative of positional displacement.  
* **Force Vectors ($\vec{F}$)**: Rendered in **Blue/Yellow** breakdown arrows showing component forces and net force (${\vec{F}}_{net}$).

### **3\. "Kinematics Debunker" & Live Telemetry Panel**

* **Real-time Graphing**: Split-screen display showing live $x(t)$, $v(t)$, and $a(t)$ plots alongside the camera feed.  
* **Energy Conservation Audit**: Dynamic bar charts tracking kinetic energy ($K=\frac{1}{2}m{v}^{2}$), gravitational potential energy ($U=mgh$), and thermal loss due to friction.

## **Physics Engine & Mathematical Formulation**

To generate smooth vector overlays without jitter caused by camera noise, raw frame-by-frame pixel positions must undergo spatial transformation and low-pass filtering before computing numerical derivatives.

### **1\. Pixel-to-Metric Spatial Transformation**

Let $({x}_{p},{y}_{p})$ be the pixel coordinates of the object centroid. Using a calibration marker of known dimension ${L}_{ref}$ (or AR depth telemetry):

$s=\frac{{L}_{real}}{{L}_{pixel}}(metersperpixel)$

$x(t)=s\cdot {x}_{p}(t),y(t)=s\cdot {y}_{p}(t)$

### **2\. Position Smoothing & Velocity Derivation**

To eliminate discrete differentiation noise, a 5-frame Savitzky-Golay or moving-average filter is applied to the time-series coordinates $(x(t),y(t))$:

$\vec{v}(t)=\left({\frac{dx}{dt},\frac{dy}{dt}}\right)\approx \left({\frac{x(t+\Delta t)-x(t-\Delta t)}{2\Delta t},\frac{y(t+\Delta t)-y(t-\Delta t)}{2\Delta t}}\right)$

$\vec{a}(t)=\frac{d\vec{v}}{dt}\approx \frac{\vec{v}(t+\Delta t)-\vec{v}(t-\Delta t)}{2\Delta t}$

### **3\. Net Force & Component Calculations**

Using user-input mass $m$ (default: $0.1kg$):

${\vec{F}}_{net}=m\cdot \vec{a}$

## **4-Person Hackathon Workload Division**

| Role / Owner | Core Deliverables & Technical Responsibilities | Key Technologies |
| ----- | ----- | ----- |
| **Dev 1: Mobile Architecture, AR & Client Integration Lead** | • Builds the core Flutter application shell, navigation routing, and global state management system • Implements native ARCore/ARKit viewports and spatial anchors to anchor 3D vector graphics to target objects • Develops low-latency WebSocket client engine for continuous video frame streaming and incoming vector coordinate processing • Writes custom 2D/3D canvas rendering engine using `CustomPainter` to draw animated velocity (v![]()), acceleration (a![]()), and force (F![]()) vectors • Integrates live telemetry side-panel with real-time x(t), v(t), and a(t) line plots using `FlChart`  • Builds touch-based calibration UX for camera scaling, object selection, mass input, and experiment mode toggles | Flutter, ARCore, ARKit, Dart, WebSockets, `CustomPainter`, `FlChart`, Riverpod |
| **Dev 2: Computer Vision Engineer** | • Builds real-time object detection and tracking pipeline using OpenCV and MediaPipe • Implements frame downsampling and color-space conversion to optimize frame transmission rates • Handles 2D centroid extraction, bounding box tracking, and perspective transformation matrix calculations | Python, OpenCV, MediaPipe, NumPy |
| **Dev 3: Physics & Kinematics Engine Lead** | • Writes real-time numerical differentiation algorithms with noise-reduction filters (Savitzky-Golay / moving averages) • Implements dynamic vector math solvers for inclined planes, free-fall, pendulums, and 1D collisions • Calculates real-time force decomposition (F![]()net​, F![]()N​, F![]()f​) and system energy states (K, Ug​) | Python, NumPy, SciPy |
| **Dev 4: Backend Infrastructure & Streaming Lead** | • Sets up asynchronous FastAPI WebSocket server for bi-directional frame and vector data streaming • Designs lightweight JSON schemas and binary serialization protocols to maintain \<50ms round-trip latency • Manages server session states, concurrent client connection handling, and deployment environment setup | Python, FastAPI, WebSockets, Uvicorn, Docker |
| **Role / Owner** | **Core Deliverables & Technical Responsibilities** | **Key Technologies** |

## **Hackathon Minimum Viable Product (MVP) Milestones**

### **Phase 1: Core Data Pipeline (Hours 0–8)**

* Flutter app connects to FastAPI WebSocket backend and streams downsampled video frames.  
* Backend successfully runs MediaPipe/OpenCV tracking on a brightly colored sphere (e.g., red tennis ball) and returns $(x,y)$ coordinates.

### **Phase 2: Math & Vector Overlay (Hours 8–18)**

* Implement velocity and acceleration numerical differentiation in NumPy with smoothing filters.  
* Render basic dynamic 2D vector arrows over the video stream in Flutter using CustomPainter.  
* Add basic reference scale calibration (e.g., drawing a line over a known 30cm ruler on screen).

### **Phase 3: Telemetry Panel & Polishing (Hours 18–24)**

* Connect FlChart graphing package in Flutter to display live velocity-time curves alongside the AR feed.  
* Implement a toggle switch for "Ramp Mode" vs. "Free Fall Mode".  
* Prepare target demonstration scenarios (e.g., rolling a ball down an inclined plane) for live judge demonstrations.