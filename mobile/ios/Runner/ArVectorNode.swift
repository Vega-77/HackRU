import SceneKit
import UIKit

/// The 3D arrows behind `ArKitFrameSource.showArVectors` (lib/services/camera),
/// built by `ArVectorSceneBuilder` (lib/features/experiment/widgets).
///
/// Channel `handson/arkit`:
/// * `setVectors {origin: [3], ease_s, labels, halo (ARGB), arrows: [{id,
///   direction: [3], length, radius, color (ARGB), symbol, subscript, dashed}]}`
/// * `hideVectors`
///
/// Positions are ARKit world metres, so SceneKit redraws the arrows from the
/// live camera pose every screen refresh and they stay on the object while
/// the phone moves. One layer is shared by every AR preview; the newest
/// preview shows it.
final class ArVectorLayer {
  let root = SCNNode()
  private var arrows: [String: ArrowNode] = [:]
  private let labels = LabelImages()

  init() {
    root.name = "handson.vectors"
    root.opacity = 0
  }

  func attach(to scene: SCNScene) {
    root.removeFromParentNode()
    scene.rootNode.addChildNode(root)
  }

  func update(_ args: [String: Any]) {
    guard let origin = vector3(args["origin"]) else { return }
    let ease = number(args["ease_s"]) ?? 0
    let showLabels = args["labels"] as? Bool ?? true
    let halo = UIColor(argb: args["halo"])
    let specs = (args["arrows"] as? [[String: Any]] ?? []).compactMap(ArrowSpec.init)
    let ids = Set(specs.map(\.id))

    for (id, node) in arrows where !ids.contains(id) {
      node.removeFromParentNode()
      arrows[id] = nil
    }

    // New arrows appear where they belong instead of sliding in from the origin.
    SCNTransaction.begin()
    SCNTransaction.disableActions = true
    for spec in specs where arrows[spec.id] == nil {
      let node = ArrowNode(halo: halo)
      root.addChildNode(node)
      arrows[spec.id] = node
      node.apply(spec, origin: origin, label: showLabels ? labels.image(for: spec, halo: halo) : nil)
    }
    SCNTransaction.commit()

    SCNTransaction.begin()
    SCNTransaction.animationDuration = ease
    root.opacity = 1
    for spec in specs {
      arrows[spec.id]?.apply(spec, origin: origin, label: showLabels ? labels.image(for: spec, halo: halo) : nil)
    }
    SCNTransaction.commit()
  }

  /// Fades the arrows out. They stay in the scene, so the next update fades
  /// them back in place.
  func hide(animated: Bool = true) {
    SCNTransaction.begin()
    SCNTransaction.animationDuration = animated ? 0.25 : 0
    root.opacity = 0
    SCNTransaction.commit()
  }
}

/// One arrow as the Dart side describes it.
struct ArrowSpec {
  let id: String
  let direction: simd_float3
  let length: Float
  let radius: Float
  let color: UIColor
  let symbol: String
  let subscriptText: String
  let dashed: Bool

  init?(_ map: [String: Any]) {
    guard let id = map["id"] as? String,
      let direction = vector3(map["direction"]),
      let length = number(map["length"]), length > 0,
      let radius = number(map["radius"]), radius > 0
    else { return nil }
    self.id = id
    self.direction = simd_length(direction) > 0 ? simd_normalize(direction) : simd_float3(0, 1, 0)
    self.length = Float(length)
    self.radius = Float(radius)
    color = UIColor(argb: map["color"])
    symbol = map["symbol"] as? String ?? ""
    subscriptText = map["subscript"] as? String ?? ""
    dashed = map["dashed"] as? Bool ?? false
  }
}

/// A shaft and a cone along the node's +y axis, a dark outline around both,
/// and a label that always faces the camera.
///
/// The shaft is a unit-height cylinder scaled to length, so SceneKit can
/// animate length changes between backend replies.
final class ArrowNode: SCNNode {
  private let shaft = SCNNode()
  private let shaftHalo = SCNNode()
  private let head = SCNNode()
  private let headHalo = SCNNode()
  private let label = SCNNode()
  private let shaftMaterial = ArrowNode.flat()
  private let headMaterial = ArrowNode.flat()
  private let haloMaterial: SCNMaterial
  private var dashed = false

  /// Matches the 2D overlay: 7 px dashes with 5 px gaps, at 1 mm per px.
  private static let dashPeriod: Float = 0.012
  private static let dashTexture: UIImage = {
    UIGraphicsImageRenderer(size: CGSize(width: 1, height: 12)).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 1, height: 7))
    }
  }()

  /// The outline is a slightly bigger copy drawn inside out, so only its
  /// rim shows around the arrow.
  private static let haloScale: Float = 1.7

  init(halo: UIColor) {
    haloMaterial = ArrowNode.flat()
    haloMaterial.diffuse.contents = halo.withAlphaComponent(0.55)
    haloMaterial.cullMode = .front
    super.init()
    for (node, material) in [(shaftHalo, haloMaterial), (shaft, shaftMaterial), (headHalo, haloMaterial), (head, headMaterial)] {
      let isShaft = node === shaft || node === shaftHalo
      node.geometry = isShaft
        ? SCNCylinder(radius: 1, height: 1) as SCNGeometry
        : SCNCone(topRadius: 0, bottomRadius: 1, height: 1)
      node.geometry?.firstMaterial = material
      addChildNode(node)
    }
    let plane = SCNPlane(width: 1, height: 1)
    let labelMaterial = ArrowNode.flat()
    labelMaterial.isDoubleSided = true
    labelMaterial.readsFromDepthBuffer = false
    labelMaterial.writesToDepthBuffer = false
    plane.firstMaterial = labelMaterial
    label.geometry = plane
    label.renderingOrder = 10
    let billboard = SCNBillboardConstraint()
    billboard.freeAxes = .all
    label.constraints = [billboard]
    addChildNode(label)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("ArrowNode is built in code")
  }

  func apply(_ spec: ArrowSpec, origin: simd_float3, label image: UIImage?) {
    simdPosition = origin
    simdOrientation = ArrowNode.rotation(to: spec.direction)

    // Proportions follow the 2D overlay's arrow head.
    let headLength = min(spec.radius * 5.5, spec.length * 0.45)
    let headRadius = spec.radius * 2.3
    let shaftLength = max(spec.length - headLength * 0.8, 0.0001)

    shaft.simdScale = simd_float3(spec.radius, shaftLength, spec.radius)
    shaft.simdPosition = simd_float3(0, shaftLength / 2, 0)
    shaftHalo.simdScale = shaft.simdScale * simd_float3(ArrowNode.haloScale, 1, ArrowNode.haloScale)
    shaftHalo.simdPosition = shaft.simdPosition
    head.simdScale = simd_float3(headRadius, headLength, headRadius)
    head.simdPosition = simd_float3(0, spec.length - headLength / 2, 0)
    headHalo.simdScale = simd_float3(headRadius * 1.3, headLength * 1.25, headRadius * 1.3)
    headHalo.simdPosition = head.simdPosition

    shaftMaterial.diffuse.contents = spec.color
    headMaterial.diffuse.contents = spec.color
    if spec.dashed != dashed { setDashed(spec.dashed) }
    if spec.dashed {
      let repeats = max(shaftLength / ArrowNode.dashPeriod, 1)
      shaftMaterial.transparent.contentsTransform = SCNMatrix4MakeScale(1, repeats, 1)
      shaftHalo.geometry?.firstMaterial?.transparent.contentsTransform = SCNMatrix4MakeScale(1, repeats, 1)
    }

    if let image = image {
      let height: Float = 0.024
      let width = height * Float(image.size.width / image.size.height)
      label.simdScale = simd_float3(width, height, 1)
      label.simdPosition = simd_float3(0, spec.length + 0.008 + max(width, height) / 2, 0)
      label.geometry?.firstMaterial?.diffuse.contents = image
      label.opacity = 1
    } else {
      label.opacity = 0
    }
  }

  private func setDashed(_ on: Bool) {
    dashed = on
    shaftMaterial.transparent.contents = on ? ArrowNode.dashTexture : nil
    shaftMaterial.transparent.wrapT = .repeat
    shaftMaterial.transparencyMode = .aOne
    // The dashed shaft gets its own outline material, so the head's stays solid.
    let halo = on ? haloMaterial.copy() as! SCNMaterial : haloMaterial
    if on {
      halo.transparent.contents = ArrowNode.dashTexture
      halo.transparent.wrapT = .repeat
      halo.transparencyMode = .aOne
    }
    shaftHalo.geometry?.firstMaterial = halo
  }

  /// Turns the node's +y axis to `direction`.
  static func rotation(to direction: simd_float3) -> simd_quatf {
    let up = simd_float3(0, 1, 0)
    // from:to: has no unique answer for opposite vectors.
    if simd_dot(up, direction) < -0.9999 {
      return simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0))
    }
    return simd_quatf(from: up, to: direction)
  }

  /// Unlit, so arrows show the physics palette exactly, as in 2D.
  private static func flat() -> SCNMaterial {
    let material = SCNMaterial()
    material.lightingModel = .constant
    return material
  }
}

/// Label pictures, like an italic F with a small N, drawn once per colour.
final class LabelImages {
  private var cache: [String: UIImage] = [:]

  func image(for spec: ArrowSpec, halo: UIColor) -> UIImage? {
    guard !spec.symbol.isEmpty else { return nil }
    let key = "\(spec.symbol)|\(spec.subscriptText)|\(spec.color)"
    if let image = cache[key] { return image }
    let image = draw(spec.symbol, spec.subscriptText, color: spec.color, halo: halo)
    cache[key] = image
    return image
  }

  private func draw(_ symbol: String, _ sub: String, color: UIColor, halo: UIColor) -> UIImage {
    let main = UIFont.italicSystemFont(ofSize: 96)
    let small = UIFont.systemFont(ofSize: 58, weight: .semibold)
    let text = NSMutableAttributedString(string: symbol, attributes: [.font: main])
    if !sub.isEmpty {
      text.append(NSAttributedString(string: sub, attributes: [.font: small, .baselineOffset: -20]))
    }
    let all = NSRange(location: 0, length: text.length)
    let bounds = text.boundingRect(
      with: CGSize(width: 2000, height: 2000), options: [.usesLineFragmentOrigin], context: nil)
    let pad: CGFloat = 14
    let size = CGSize(width: ceil(bounds.width) + pad * 2, height: ceil(bounds.height) + pad * 2 + 20)
    let format = UIGraphicsImageRendererFormat()
    format.opaque = false
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      let outline = NSMutableAttributedString(attributedString: text)
      outline.addAttributes([.strokeColor: halo.withAlphaComponent(0.8), .strokeWidth: 12], range: all)
      outline.draw(at: CGPoint(x: pad, y: pad))
      let fill = NSMutableAttributedString(attributedString: text)
      fill.addAttribute(.foregroundColor, value: color, range: all)
      fill.draw(at: CGPoint(x: pad, y: pad))
    }
  }
}

private func number(_ value: Any?) -> Double? {
  (value as? NSNumber)?.doubleValue
}

private func vector3(_ value: Any?) -> simd_float3? {
  guard let list = value as? [Any], list.count == 3 else { return nil }
  let values = list.compactMap(number)
  guard values.count == 3 else { return nil }
  return simd_float3(Float(values[0]), Float(values[1]), Float(values[2]))
}

extension UIColor {
  /// From a Dart `Color.toARGB32()` sent over the channel.
  convenience init(argb value: Any?) {
    let v = (value as? NSNumber)?.uint32Value ?? 0xFFFF_FFFF
    self.init(
      red: CGFloat((v >> 16) & 0xFF) / 255,
      green: CGFloat((v >> 8) & 0xFF) / 255,
      blue: CGFloat(v & 0xFF) / 255,
      alpha: CGFloat((v >> 24) & 0xFF) / 255)
  }
}
