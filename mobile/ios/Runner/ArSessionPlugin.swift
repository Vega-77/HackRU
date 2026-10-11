import ARKit
import AVFoundation
import CoreImage
import Flutter
import UIKit

/// Runs the ARKit session behind `ArKitFrameSource` (lib/services/camera).
///
/// Channel `handson/arkit`:
/// * `isSupported` -> Bool
/// * `start {width}` -> {width, height} of the frames `capture` will return
/// * `stop`
/// * `capture {width, quality}` -> {jpeg, width, height, timestamp,
///   intrinsics: [fx, fy, cx, cy], camera_to_world: [16, row-major]} or nil
/// * `raycast {x, y, width}` -> {point: [3], normal: [3], vertical} or nil
/// * `setVectors {...}` and `hideVectors`: 3D arrows, see `ArVectorLayer`
///
/// Frames, intrinsics and pose all describe the image as the user sees it
/// (upright for the current interface orientation), scaled to `width`.
/// Camera axes are x right, y up, z towards the viewer; world axes are
/// ARKit's, in metres with +y up against gravity.
///
/// Platform view `handson/arkit_view` shows the same session's camera feed.
final class ArSessionPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "handson/arkit", binaryMessenger: registrar.messenger())
    let instance = ArSessionPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.register(
      ArPreviewFactory(session: instance.session, vectors: instance.vectors), withId: "handson/arkit_view")
  }

  let session = ARSession()
  let vectors = ArVectorLayer()
  private let ciContext = CIContext()
  private let encodeQueue = DispatchQueue(label: "handson.arkit.encode", qos: .userInitiated)
  private var running = false

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let width = args["width"] as? Int ?? 320
    switch call.method {
    case "isSupported":
      result(ARWorldTrackingConfiguration.isSupported)
    case "start":
      start(width: width, result: result)
    case "stop":
      // Pausing (not resetting) keeps the world origin, so a surface picked
      // during setup is still valid when the experiment starts.
      session.pause()
      running = false
      vectors.hide(animated: false)
      result(nil)
    case "capture":
      capture(width: width, quality: args["quality"] as? Double ?? 0.7, result: result)
    case "raycast":
      guard let x = args["x"] as? Double, let y = args["y"] as? Double else {
        result(FlutterError(code: "bad_args", message: "raycast needs x and y", details: nil))
        return
      }
      result(raycast(x: x, y: y, width: width))
    case "setVectors":
      vectors.update(args)
      result(nil)
    case "hideVectors":
      vectors.hide()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Session

  private func start(width: Int, result: @escaping FlutterResult) {
    guard ARWorldTrackingConfiguration.isSupported else {
      result(FlutterError(code: "unsupported", message: "This device has no AR world tracking.", details: nil))
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      run(width: width, result: result)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
          if granted {
            self.run(width: width, result: result)
          } else {
            result(FlutterError(code: "denied", message: nil, details: nil))
          }
        }
      }
    default:
      result(FlutterError(code: "denied", message: nil, details: nil))
    }
  }

  private func run(width: Int, result: FlutterResult) {
    let config = ARWorldTrackingConfiguration()
    config.planeDetection = [.horizontal, .vertical]
    // No people occlusion for now: it adds work on every frame, and the
    // build that had it got replies at about a third of the usual rate.
    if !running {
      session.run(config)
      running = true
    }
    let sensor = config.videoFormat.imageResolution
    let size = OrientedCamera.outputSize(sensor: sensor, orientation: interfaceOrientation, width: width)
    result(["width": Int(size.width), "height": Int(size.height)])
  }

  private var interfaceOrientation: UIInterfaceOrientation {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    return scene?.interfaceOrientation ?? .portrait
  }

  // MARK: - Frames

  private func capture(width: Int, quality: Double, result: @escaping FlutterResult) {
    guard running, let frame = session.currentFrame else {
      result(nil)
      return
    }
    // Skip frames ARKit can't place in the world: their pose would be wrong.
    if case .notAvailable = frame.camera.trackingState {
      result(nil)
      return
    }
    let camera = OrientedCamera(camera: frame.camera, orientation: interfaceOrientation, width: width)
    let pixelBuffer = frame.capturedImage
    let timestamp = frame.timestamp
    encodeQueue.async { [ciContext] in
      var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(camera.imageOrientation)
      image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
      let scale = CGFloat(width) / image.extent.width
      image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      let jpeg = ciContext.jpegRepresentation(
        of: image,
        colorSpace: CGColorSpaceCreateDeviceRGB(),
        options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
      )
      DispatchQueue.main.async {
        guard let jpeg = jpeg else {
          result(nil)
          return
        }
        result([
          "jpeg": FlutterStandardTypedData(bytes: jpeg),
          "width": Int(camera.size.width),
          "height": Int(camera.size.height),
          "timestamp": timestamp,
          "intrinsics": camera.intrinsics,
          "camera_to_world": camera.cameraToWorldRowMajor,
        ])
      }
    }
  }

  // MARK: - Surfaces

  /// The surface under frame pixel (x, y), from the camera's current pose.
  private func raycast(x: Double, y: Double, width: Int) -> [String: Any]? {
    guard running, let frame = session.currentFrame else { return nil }
    let camera = OrientedCamera(camera: frame.camera, orientation: interfaceOrientation, width: width)
    let k = camera.intrinsics
    let inCamera = simd_float4(Float((x - k[2]) / k[0]), Float(-(y - k[3]) / k[1]), -1, 0)
    let m = camera.cameraToWorld
    let direction = simd_normalize(simd_make_float3(m * inCamera))
    let origin = simd_make_float3(m.columns.3)

    // A plane ARKit has already mapped beats a guess from feature points.
    for target in [ARRaycastQuery.Target.existingPlaneGeometry, .estimatedPlane] {
      let query = ARRaycastQuery(origin: origin, direction: direction, allowing: target, alignment: .any)
      guard let hit = session.raycast(query).first else { continue }
      let t = hit.worldTransform
      // A raycast result's y axis is the surface normal.
      let normal = simd_normalize(simd_make_float3(t.columns.1))
      let point = simd_make_float3(t.columns.3)
      let vertical: Bool
      if let plane = hit.anchor as? ARPlaneAnchor {
        vertical = plane.alignment == .vertical
      } else {
        vertical = abs(normal.y) < 0.5
      }
      return [
        "point": [Double(point.x), Double(point.y), Double(point.z)],
        "normal": [Double(normal.x), Double(normal.y), Double(normal.z)],
        "vertical": vertical,
      ]
    }
    return nil
  }
}

/// ARKit's camera, re-expressed for the upright image the user sees.
///
/// ARKit captures in the sensor's landscape orientation (home button on the
/// right). For other interface orientations the image is rotated, so the
/// intrinsics are rotated with it, and the pose comes from
/// `viewMatrix(for:)`, which rotates the camera axes the same way.
struct OrientedCamera {
  let size: CGSize
  let imageOrientation: CGImagePropertyOrientation
  /// fx, fy, cx, cy in output pixels.
  let intrinsics: [Double]
  let cameraToWorld: simd_float4x4

  init(camera: ARCamera, orientation: UIInterfaceOrientation, width: Int) {
    let sensor = camera.imageResolution
    let w = Double(sensor.width), h = Double(sensor.height)
    let k = camera.intrinsics
    let fx = Double(k[0][0]), fy = Double(k[1][1]), cx = Double(k[2][0]), cy = Double(k[2][1])

    // Where pixel (u, v) of the sensor image lands in the upright image.
    var rotated: [Double]
    switch orientation {
    case .portrait:
      imageOrientation = .right  // (u, v) -> (h - v, u)
      rotated = [fy, fx, h - cy, cx]
    case .portraitUpsideDown:
      imageOrientation = .left  // (u, v) -> (v, w - u)
      rotated = [fy, fx, cy, w - cx]
    case .landscapeLeft:
      imageOrientation = .down  // (u, v) -> (w - u, h - v)
      rotated = [fx, fy, w - cx, h - cy]
    default:
      imageOrientation = .up
      rotated = [fx, fy, cx, cy]
    }
    size = OrientedCamera.outputSize(sensor: sensor, orientation: orientation, width: width)
    let scale = Double(size.width) / (imageOrientation == .up || imageOrientation == .down ? w : h)
    intrinsics = rotated.map { $0 * scale }
    cameraToWorld = camera.viewMatrix(for: orientation).inverse
  }

  static func outputSize(sensor: CGSize, orientation: UIInterfaceOrientation, width: Int) -> CGSize {
    let upright = orientation.isPortrait ? CGSize(width: sensor.height, height: sensor.width) : sensor
    let height = (Double(width) * Double(upright.height) / Double(upright.width)).rounded()
    return CGSize(width: CGFloat(width), height: CGFloat(height))
  }

  var cameraToWorldRowMajor: [Double] {
    let m = cameraToWorld
    return (0..<4).flatMap { row in (0..<4).map { col in Double(m[col][row]) } }
  }
}

final class ArPreviewFactory: NSObject, FlutterPlatformViewFactory {
  private let session: ARSession
  private let vectors: ArVectorLayer

  init(session: ARSession, vectors: ArVectorLayer) {
    self.session = session
    self.vectors = vectors
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    ArPreview(frame: frame, session: session, vectors: vectors)
  }
}

/// The live camera feed. ARSCNView fills its bounds like BoxFit.cover, which
/// is what the Flutter overlay assumes when it maps frame pixels to screen.
/// The same view draws the 3D arrows, from the session's live camera pose.
final class ArPreview: NSObject, FlutterPlatformView, ARSCNViewDelegate {
  private let sceneView: ARSCNView
  private let vectors: ArVectorLayer

  init(frame: CGRect, session: ARSession, vectors: ArVectorLayer) {
    sceneView = ARSCNView(frame: frame)
    self.vectors = vectors
    sceneView.session = session
    sceneView.scene = SCNScene()
    sceneView.automaticallyUpdatesLighting = false
    sceneView.antialiasingMode = .multisampling4X
    vectors.attach(to: sceneView.scene)
    super.init()
    sceneView.delegate = self
  }

  func view() -> UIView {
    sceneView
  }

  func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
    vectors.keepScreenSize(camera: renderer.pointOfView)
  }
}
