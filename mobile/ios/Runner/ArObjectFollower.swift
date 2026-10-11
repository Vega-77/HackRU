import ARKit
import Vision

/// Follows the tracked object on every camera frame, between backend replies.
///
/// The backend finds the object about 15 times a second, and each reply
/// lands several frames after the picture it describes. Arrows anchored
/// there trail the ball and sit off its centre. Vision's object tracker runs
/// here on every frame ARKit delivers instead, started from the backend's
/// box on the frame that box came from, so the arrows and the occluder stay
/// on the ball the user sees.
///
/// The backend stays in charge. A reply whose box disagrees with where the
/// tracker had the object on that frame restarts the tracker there, and a
/// tracker that loses the object hands the arrows back to the backend's
/// position until the next reply.
///
/// Boxes are normalized to the upright frame with a top-left origin, the
/// same frame the backend sees. Everything but `offer` runs on one serial
/// queue. Live frames that arrive while one is being tracked replace each
/// other, so the tracker always works on the newest frame and never falls
/// behind.
final class ArObjectFollower {
  /// Where the object is on one camera frame.
  struct Fix {
    let box: CGRect
    let timestamp: TimeInterval
    let confidence: Float
    /// The box centre at the backend position's depth, ARKit world metres.
    let point: simd_float3
    /// The object's radius at that depth, metres.
    let radius: Float
    /// The first fix after the tracker started from a backend box.
    let restarted: Bool
  }

  private struct Frame {
    let buffer: CVPixelBuffer
    let camera: OrientedCamera
    let timestamp: TimeInterval
  }

  /// Called on the main queue for each followed frame.
  var onFix: ((Fix) -> Void)?
  /// Called on the main queue when the tracker gives up, with why.
  var onLost: ((String) -> Void)?

  private let queue = DispatchQueue(label: "handson.arkit.follow", qos: .userInteractive)
  private let lock = NSLock()
  private var newest: Frame?
  private var draining = false

  // The rest is only touched on `queue`.
  private var handler: VNSequenceRequestHandler?
  private var request: VNTrackObjectRequest?
  private var restarted = false
  /// Frames sent to the backend, oldest first.
  private var sent: [Frame] = []
  /// Where the tracker had the object, oldest first.
  private var history: [(timestamp: TimeInterval, box: CGRect)] = []
  private var lastFix: TimeInterval = 0
  /// The backend's newest position. Its depth places the box in the world.
  private var reference = simd_float3.zero
  private var radiusFactor: Float = 1

  /// More frames can await a reply on a slow connection (the window grows
  /// with the round trip), but on Wi-Fi a reply is back within a frame or
  /// two, so three cover it.
  /// Keeping more of ARKit's buffers risks it stopping delivering frames.
  /// A reply for an older frame starts the tracker on the next live frame.
  private static let keepSent = 3
  private static let historySeconds: TimeInterval = 1
  /// Below this Vision is guessing.
  private static let minConfidence: Float = 0.3

  /// Keeps a frame sent to the backend, so its reply can start the tracker
  /// on the picture it describes.
  func remember(_ buffer: CVPixelBuffer, camera: OrientedCamera, timestamp: TimeInterval) {
    let frame = Frame(buffer: buffer, camera: camera, timestamp: timestamp)
    queue.async {
      self.sent.append(frame)
      if self.sent.count > Self.keepSent { self.sent.removeFirst() }
    }
  }

  /// A live camera frame. Dropped unless the tracker is running.
  func offer(_ buffer: CVPixelBuffer, camera: OrientedCamera, timestamp: TimeInterval) {
    lock.lock()
    newest = Frame(buffer: buffer, camera: camera, timestamp: timestamp)
    let start = !draining
    draining = true
    lock.unlock()
    if start { queue.async { self.drainOne() } }
  }

  /// Checks a backend reply against the tracker, and starts the tracker
  /// from `box` when it isn't running or disagrees. `box` is on the frame
  /// taken at `capturedAt`; `origin` is the backend's position for it.
  func check(box: CGRect, capturedAt: TimeInterval, origin: simd_float3, radiusFactor: Float) {
    let clamped = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard !clamped.isNull, clamped.width > 0.002, clamped.height > 0.002 else { return }
    queue.async {
      self.reference = origin
      self.radiusFactor = radiusFactor
      if self.request != nil, let seen = self.trackedBox(near: capturedAt), Self.agree(seen, clamped) {
        return
      }
      self.restart(from: clamped, capturedAt: capturedAt)
    }
  }

  /// Stops tracking until the next `check`.
  func stop(forgetFrames: Bool = false) {
    queue.async {
      self.reset()
      if forgetFrames { self.sent.removeAll() }
    }
  }

  // MARK: - Queue

  private func drainOne() {
    lock.lock()
    guard let frame = newest else {
      draining = false
      lock.unlock()
      return
    }
    newest = nil
    lock.unlock()
    track(frame)
    // One frame per block, so a waiting `check` runs between frames.
    queue.async { self.drainOne() }
  }

  private func restart(from box: CGRect, capturedAt: TimeInterval) {
    let request = VNTrackObjectRequest(
      detectedObjectObservation: VNDetectedObjectObservation(boundingBox: Self.flipped(box)))
    request.trackingLevel = .accurate
    handler = VNSequenceRequestHandler()
    self.request = request
    history.removeAll()
    restarted = true
    // The first frame a tracker sees is the one it learns the object from,
    // so give it the picture the box describes, not whatever is there now.
    if let frame = sent.last(where: { abs($0.timestamp - capturedAt) < 0.002 }) {
      track(frame)
    }
  }

  private func track(_ frame: Frame) {
    guard let handler = handler, let request = request else { return }
    do {
      try handler.perform([request], on: frame.buffer, orientation: frame.camera.imageOrientation)
    } catch {
      lose("Vision could not track it: \(error.localizedDescription)")
      return
    }
    guard let observation = (request.results as [VNObservation]?)?.first as? VNDetectedObjectObservation
    else {
      lose("Vision returned no box")
      return
    }
    guard observation.confidence >= Self.minConfidence else {
      lose(String(format: "confidence fell to %.2f", observation.confidence))
      return
    }
    request.inputObservation = observation

    let box = Self.flipped(observation.boundingBox)
    history.append((frame.timestamp, box))
    while let first = history.first, frame.timestamp - first.timestamp > Self.historySeconds {
      history.removeFirst()
    }

    // The frame a restart learns from is older than the live ones already
    // shown; moving the arrows back to it would make them jump.
    guard frame.timestamp > lastFix, let fix = place(box, on: frame, confidence: observation.confidence)
    else { return }
    lastFix = frame.timestamp
    restarted = false
    DispatchQueue.main.async { self.onFix?(fix) }
  }

  /// Puts the box in the world: on the ray through its centre, as deep as
  /// the backend's position. The arrows keep a constant size on screen, so
  /// only the direction of that ray shows.
  private func place(_ box: CGRect, on frame: Frame, confidence: Float) -> Fix? {
    let camera = frame.camera
    let k = camera.intrinsics
    let toWorld = camera.cameraToWorld
    let depth = -(toWorld.inverse * simd_float4(reference, 1)).z
    guard depth > 0.05 else { return nil }
    let width = Double(camera.size.width), height = Double(camera.size.height)
    let u = Double(box.midX) * width, v = Double(box.midY) * height
    let d = Double(depth)
    let inCamera = simd_float4(Float((u - k[2]) / k[0] * d), Float(-(v - k[3]) / k[1] * d), -depth, 1)
    let side = min(Double(box.width) * width, Double(box.height) * height)
    return Fix(
      box: box,
      timestamp: frame.timestamp,
      confidence: confidence,
      point: simd_make_float3(toWorld * inCamera),
      radius: Float(side / 2 / k[0] * d) * radiusFactor,
      restarted: restarted)
  }

  private func lose(_ reason: String) {
    reset()
    DispatchQueue.main.async { self.onLost?(reason) }
  }

  private func reset() {
    handler = nil
    request = nil
    history.removeAll()
  }

  /// Where the tracker had the object on the frame taken at `timestamp`,
  /// or on one within a few frames of it if it skipped that one.
  private func trackedBox(near timestamp: TimeInterval) -> CGRect? {
    guard let nearest = history.min(by: { abs($0.timestamp - timestamp) < abs($1.timestamp - timestamp) }),
      abs(nearest.timestamp - timestamp) < 0.05
    else { return nil }
    return nearest.box
  }

  /// Same object: centres within half a box of each other, sizes within
  /// half again. Measured per axis, since normalized x and y differ in scale.
  private static func agree(_ tracked: CGRect, _ backend: CGRect) -> Bool {
    abs(tracked.midX - backend.midX) < backend.width / 2
      && abs(tracked.midY - backend.midY) < backend.height / 2
      && (0.67...1.5).contains(tracked.width / backend.width)
      && (0.67...1.5).contains(tracked.height / backend.height)
  }

  /// Vision's origin is the bottom left; ours is the top left. Its own inverse.
  private static func flipped(_ box: CGRect) -> CGRect {
    CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
  }
}
