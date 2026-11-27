import SceneKit
import UIKit

/// Passeggiata in soggettiva tra calli, fondamenta, ponti e campi di Venezia.
/// Il mondo viene generato a tratti di 24 m davanti alla camera e rimosso alle spalle.
/// La camera avanza alla velocità del tapis; sui ponti sale e scende.
@MainActor
final class VeniceScene: NSObject {
    enum ChunkKind { case calle, fondamentaLeft, fondamentaRight, ponte, campo }
    enum RoutePreference: String { case mixed, canals, calli }
    enum LanternState { case idle, listening, thinking, speaking }

    let scene = SCNScene()
    let cameraNode = SCNNode()

    /// Metri percorsi nella scena.
    private(set) var distance: Double = 0
    var speedKmh: () -> Double = { 0 }
    var inclinePct: () -> Double = { 0 }
    /// Chiamato quando si avvicina un bivio (circa 100 m prima).
    var onForkApproaching: (() -> Void)?
    var routePreference: RoutePreference = .mixed

    private let chunkLength: Double = 24
    private let aheadDistance: Double = 130
    private let behindDistance: Double = 30
    private let forkEvery = 16
    private var chunkNodes: [Int: SCNNode] = [:]
    private var chunkKinds: [Int: ChunkKind] = [:]
    private var signNodes: [(node: SCNNode, distance: Double)] = []
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var bobPhase: Double = 0
    private var elapsed: Double = 0
    private var announcedForks: Set<Int> = []
    private var decidedForks: Set<Int> = []
    private let lantern = SCNNode()
    private var lanternState: LanternState = .idle

    // Materiali condivisi
    private var facadeMaterials: [SCNMaterial] = []
    private lazy var roofMaterial = makeMaterial(TextureFactory.roofTiles(), repeatScale: 4)
    private lazy var stoneMaterial = colorMaterial(UIColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 1))
    private lazy var brickMaterial = makeMaterial(TextureFactory.bricks(), repeatScale: 3)
    private lazy var waterMaterial: SCNMaterial = {
        let m = makeMaterial(TextureFactory.water(), repeatScale: 6)
        m.specular.contents = UIColor(white: 0.6, alpha: 1)
        m.shininess = 0.8
        return m
    }()
    private lazy var darkMaterial = colorMaterial(UIColor(white: 0.06, alpha: 1))
    private lazy var woodMaterial = colorMaterial(UIColor(red: 0.36, green: 0.22, blue: 0.12, alpha: 1))
    private var pavingCache: [String: SCNMaterial] = [:]

    override init() {
        super.init()
        setUpScene()
    }

    // MARK: Ciclo di aggiornamento

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
        updateChunks()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTimestamp == 0 ? 0 : min(now - lastTimestamp, 0.1)
        lastTimestamp = now
        elapsed += dt

        let speed = max(0, speedKmh()) / 3.6
        distance += speed * dt

        // Oscillazione del passo: frequenza e ampiezza crescono con la velocità.
        let cadence = speed > 0.1 ? 1.5 + speed * 0.2 : 0
        bobPhase += dt * cadence * 2 * .pi
        let bobAmplitude = min(0.012 + speed * 0.008, 0.045)
        let bob = speed > 0.1 ? sin(bobPhase) * bobAmplitude : 0
        let sway = speed > 0.1 ? sin(bobPhase / 2) * bobAmplitude * 0.6 : 0

        let y = 1.65 + groundHeight(at: distance) + bob
        cameraNode.position = SCNVector3(Float(sway), Float(y), Float(-distance))
        let pitch = atan(inclinePct() / 100) * 0.5 + bridgeSlope(at: distance) * 0.35
        cameraNode.eulerAngles = SCNVector3(Float(pitch), 0, 0)

        // Increspature dell'acqua
        let t = Float(elapsed)
        waterMaterial.diffuse.contentsTransform = SCNMatrix4Mult(
            SCNMatrix4MakeScale(6, 6, 1), SCNMatrix4MakeTranslation(t * 0.02, t * 0.035, 0))

        updateLantern()
        updateChunks()
        removePassedSigns()
    }

    // MARK: API per l'app

    /// Insegna "a bandiera" sul muro, circa 35 m più avanti, inclinata verso chi arriva.
    func showSign(title: String, text: String, style: SignFactory.Style) {
        var target = distance + 35
        // Evita il tratto del ponte (non ci sono muri)
        if let k = chunkIndex(at: target), chunkKind(k) == .ponte { target = Double(k + 1) * chunkLength + 3 }
        let (image, aspect) = SignFactory.image(title: title, text: text, style: style)
        let width: CGFloat = 2.6
        let node = signNode(image: image, width: width, height: width / aspect)
        let side = preferredSignSide(at: target)
        let wallX = wallOffset(at: target, side: side) - side * 0.9
        node.position = SCNVector3(Float(wallX), Float(2.6 + groundHeight(at: target)), Float(-target))
        node.eulerAngles.y = Float(side > 0 ? -0.75 : 0.75)
        // Staffa di ferro
        let bracket = SCNNode(geometry: SCNBox(width: 1.0, height: 0.05, length: 0.05, chamferRadius: 0))
        bracket.geometry?.firstMaterial = darkMaterial
        bracket.position = SCNVector3(Float(side * 0.5), Float(width / aspect / 2 + 0.05), 0)
        node.addChildNode(bracket)
        node.opacity = 0
        scene.rootNode.addChildNode(node)
        node.runAction(.fadeIn(duration: 0.6))
        signNodes.append((node, target))
    }

    func setLantern(_ state: LanternState) { lanternState = state }

    func chooseRoute(_ preference: RoutePreference) {
        routePreference = preference
        if let fork = nextFork() { decidedForks.insert(fork) }
    }

    /// true dal momento in cui il bivio è annunciato finché non viene scelto (o superato).
    var forkOpen: Bool {
        guard let fork = nextFork() else { return false }
        return announcedForks.contains(fork) && !decidedForks.contains(fork)
    }

    /// Indice del prossimo tratto "bivio" davanti alla camera, se esiste.
    func nextFork() -> Int? {
        let current = Int(distance / chunkLength)
        let next = ((current / forkEvery) + 1) * forkEvery - 1
        return next >= current ? next : nil
    }

    // MARK: Impostazione scena

    private func setUpScene() {
        scene.background.contents = skyGradient()
        scene.fogStartDistance = 45
        scene.fogEndDistance = 170
        scene.fogColor = UIColor(red: 0.86, green: 0.84, blue: 0.80, alpha: 1)

        let camera = SCNCamera()
        camera.fieldOfView = 68
        camera.zNear = 0.1
        camera.zFar = 400
        camera.wantsHDR = true
        camera.bloomIntensity = 0.3
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 1.65, 0)
        scene.rootNode.addChildNode(cameraNode)

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 1100
        sun.light?.color = UIColor(red: 1.0, green: 0.95, blue: 0.85, alpha: 1)
        sun.light?.castsShadow = true
        sun.light?.shadowMode = .deferred
        sun.light?.shadowColor = UIColor(white: 0, alpha: 0.45)
        sun.light?.automaticallyAdjustsShadowProjection = true
        sun.light?.maximumShadowDistance = 60
        sun.eulerAngles = SCNVector3(-0.9, 0.6, 0)
        // Il sole segue la camera così le ombre restano definite.
        cameraNode.addChildNode(sun)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        ambient.light?.color = UIColor(red: 0.85, green: 0.88, blue: 1.0, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        for colorIndex in 0..<TextureFactory.plasterColors.count {
            for columns in [2, 3] {
                let image = TextureFactory.facade(colorIndex: colorIndex, columns: columns, floors: 4, shutters: colorIndex % 2 == 0)
                let m = SCNMaterial()
                m.diffuse.contents = image
                m.lightingModel = .physicallyBased
                m.roughness.contents = 0.9
                facadeMaterials.append(m)
            }
        }

        // Il "fanale" di Claude: una luce che cammina davanti e cambia colore.
        let sphere = SCNSphere(radius: 0.12)
        let glow = SCNMaterial()
        glow.lightingModel = .constant
        glow.diffuse.contents = UIColor.white
        glow.emission.contents = UIColor.white
        sphere.firstMaterial = glow
        lantern.geometry = sphere
        let light = SCNLight()
        light.type = .omni
        light.intensity = 300
        light.attenuationEndDistance = 6
        lantern.light = light
        scene.rootNode.addChildNode(lantern)
    }

    private func skyGradient() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 256)).image { ctx in
            let colors = [UIColor(red: 0.45, green: 0.62, blue: 0.85, alpha: 1).cgColor,
                          UIColor(red: 0.93, green: 0.88, blue: 0.80, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 256), options: [])
        }
    }

    private func updateLantern() {
        let color: UIColor
        var pulse: Double = 1
        switch lanternState {
        case .idle: color = UIColor(red: 1.0, green: 0.92, blue: 0.75, alpha: 1)
        case .listening: color = UIColor(red: 0.40, green: 1.0, blue: 0.55, alpha: 1); pulse = 0.85 + 0.15 * sin(elapsed * 6)
        case .thinking: color = UIColor(red: 1.0, green: 0.70, blue: 0.20, alpha: 1); pulse = 0.6 + 0.4 * sin(elapsed * 4)
        case .speaking: color = UIColor(red: 0.45, green: 0.70, blue: 1.0, alpha: 1); pulse = 0.85 + 0.15 * sin(elapsed * 10)
        }
        lantern.geometry?.firstMaterial?.emission.contents = color
        lantern.light?.color = color
        lantern.light?.intensity = CGFloat(300 * pulse)
        let ahead = distance + 6
        let float = sin(elapsed * 1.3) * 0.06
        lantern.position = SCNVector3(0.8, Float(2.3 + groundHeight(at: ahead) + float), Float(-ahead))
        lantern.scale = SCNVector3(Float(pulse), Float(pulse), Float(pulse))
    }

    // MARK: Generazione del percorso

    private func chunkIndex(at d: Double) -> Int? { d >= 0 ? Int(d / chunkLength) : nil }

    private func chunkKind(_ k: Int) -> ChunkKind {
        if let kind = chunkKinds[k] { return kind }
        let kind = pickKind(k)
        chunkKinds[k] = kind
        return kind
    }

    private func pickKind(_ k: Int) -> ChunkKind {
        if k < 2 { return .calle }
        let previous = chunkKind(k - 1)
        if previous == .ponte { return .calle }
        var rng = SeededRandom(seed: UInt64(k) &* 2654435761)
        let weights: [(ChunkKind, Double)]
        switch routePreference {
        case .canals: weights = [(.fondamentaLeft, 3), (.fondamentaRight, 3), (.ponte, 2), (.calle, 1), (.campo, 0.7)]
        case .calli: weights = [(.calle, 4), (.ponte, 2), (.campo, 1.5), (.fondamentaLeft, 0.7), (.fondamentaRight, 0.7)]
        case .mixed: weights = [(.calle, 3), (.ponte, 2), (.fondamentaLeft, 2), (.fondamentaRight, 2), (.campo, 1)]
        }
        let filtered = weights.filter { !(previous == .campo && $0.0 == .campo) }
        let total = filtered.reduce(0) { $0 + $1.1 }
        var pick = rng.next(in: 0...total)
        for (kind, weight) in filtered {
            pick -= weight
            if pick <= 0 { return kind }
        }
        return .calle
    }

    private func updateChunks() {
        let first = max(0, Int((distance - behindDistance) / chunkLength))
        var last = Int((distance + aheadDistance) / chunkLength)

        // Oltre un bivio non ancora deciso, aspetta la scelta (o di essere vicini: allora resta "misto").
        if let fork = nextFork(), last > fork {
            if !announcedForks.contains(fork) {
                announcedForks.insert(fork)
                onForkApproaching?()
            }
            let forkEnd = Double(fork + 1) * chunkLength
            if !decidedForks.contains(fork) && distance < forkEnd - 60 {
                last = fork
            } else {
                decidedForks.insert(fork)
            }
        }

        for k in first...max(first, last) where chunkNodes[k] == nil {
            let node = buildChunk(k)
            chunkNodes[k] = node
            scene.rootNode.addChildNode(node)
        }
        for (k, node) in chunkNodes where k < first {
            node.removeFromParentNode()
            chunkNodes[k] = nil
        }
        // Memoria dei tipi: tiene solo quelli recenti
        for k in chunkKinds.keys where k < first - 2 { chunkKinds[k] = nil }
    }

    private func removePassedSigns() {
        signNodes.removeAll { item in
            if item.distance < distance - 15 {
                item.node.removeFromParentNode()
                return true
            }
            return false
        }
    }

    // MARK: Altezze e muri

    private func bridgeRange(_ k: Int) -> ClosedRange<Double> {
        let start = Double(k) * chunkLength
        return (start + 3)...(start + 21)
    }

    private let bridgeHeight: Double = 2.0

    func groundHeight(at d: Double) -> Double {
        guard let k = chunkIndex(at: d), chunkKinds[k] == .ponte else { return 0 }
        let range = bridgeRange(k)
        guard range.contains(d) else { return 0 }
        let t = (d - range.lowerBound) / (range.upperBound - range.lowerBound)
        return bridgeHeight * sin(.pi * t)
    }

    private func bridgeSlope(at d: Double) -> Double {
        let h1 = groundHeight(at: d), h2 = groundHeight(at: d + 0.5)
        return atan((h2 - h1) / 0.5)
    }

    /// +1 = lato destro, -1 = lato sinistro.
    private func preferredSignSide(at d: Double) -> Double {
        guard let k = chunkIndex(at: d) else { return 1 }
        switch chunkKind(k) {
        case .fondamentaRight: return 1      // canale a sinistra, case a destra
        case .fondamentaLeft: return -1
        default: return 1
        }
    }

    private func wallOffset(at d: Double, side: Double) -> Double {
        guard let k = chunkIndex(at: d) else { return side * 1.75 }
        switch chunkKind(k) {
        case .calle, .ponte: return side * 1.75
        case .fondamentaLeft, .fondamentaRight: return side * 2.0
        case .campo: return side * 4.0
        }
    }

    // MARK: Costruzione dei tratti

    private func buildChunk(_ k: Int) -> SCNNode {
        let kind = chunkKind(k)
        var rng = SeededRandom(seed: UInt64(k) &* 0x51ED27 &+ 17)
        let z0 = Double(k) * chunkLength   // distanza di inizio (z = -z0)
        let staticNode = SCNNode()
        let dynamicNode = SCNNode()

        switch kind {
        case .calle:
            addGround(staticNode, x: 0, width: 3.5, from: z0, length: chunkLength)
            addRowOfHouses(staticNode, side: 1, innerX: 1.75, from: z0, length: chunkLength, rng: &rng, baseY: 0)
            addRowOfHouses(staticNode, side: -1, innerX: 1.75, from: z0, length: chunkLength, rng: &rng, baseY: 0)
            if rng.nextInt(3) == 0 {
                let lineD = z0 + rng.next(in: 4...20)
                addLaundryLine(staticNode, at: lineD, rng: &rng)
            }
        case .fondamentaRight, .fondamentaLeft:
            let canalSide: Double = kind == .fondamentaRight ? -1 : 1
            addGround(staticNode, x: 0, width: 4, from: z0, length: chunkLength)
            addRowOfHouses(staticNode, side: -canalSide, innerX: 2, from: z0, length: chunkLength, rng: &rng, baseY: 0)
            addCanalAlongPath(staticNode, dynamicNode, side: canalSide, from: z0, rng: &rng)
        case .ponte:
            addGround(staticNode, x: 0, width: 3.5, from: z0, length: 6)
            addGround(staticNode, x: 0, width: 3.5, from: z0 + 18, length: 6)
            addBlock(staticNode, side: 1, from: z0, length: 6, rng: &rng)
            addBlock(staticNode, side: -1, from: z0, length: 6, rng: &rng)
            addBlock(staticNode, side: 1, from: z0 + 18, length: 6, rng: &rng)
            addBlock(staticNode, side: -1, from: z0 + 18, length: 6, rng: &rng)
            addCrossCanal(staticNode, dynamicNode, from: z0 + 6, width: 12, rng: &rng)
            addBridge(staticNode, range: bridgeRange(k))
        case .campo:
            addGround(staticNode, x: 0, width: 36, from: z0, length: chunkLength)
            addRowOfHouses(staticNode, side: 1, innerX: 18, from: z0, length: chunkLength, rng: &rng, baseY: 0)
            addRowOfHouses(staticNode, side: -1, innerX: 18, from: z0, length: chunkLength, rng: &rng, baseY: 0)
            addWell(staticNode, x: -5, d: z0 + 12)
            if rng.nextInt(2) == 0 { addCampanile(staticNode, x: rng.nextInt(2) == 0 ? 12 : -12, d: z0 + 20) }
        }

        // Nizioleto con il nome della calle all'inizio di alcuni tratti
        if kind != .ponte && (k % 3 == 1 || kind == .campo) {
            let name = SignFactory.streetNames[k % SignFactory.streetNames.count]
            let (image, aspect) = SignFactory.image(title: name, text: "", style: .street)
            let side = preferredSignSide(at: z0 + 3)
            let w: CGFloat = 1.8
            let sign = signNode(image: image, width: w, height: w / aspect)
            let x = wallOffset(at: z0 + 3, side: side) - side * 0.03
            sign.position = SCNVector3(Float(x), 3.4, Float(-(z0 + 3)))
            sign.eulerAngles.y = Float(side > 0 ? -Double.pi / 2 : Double.pi / 2)
            staticNode.addChildNode(sign)
        }

        // Cartelli del bivio
        if k > 0 && (k + 1) % forkEvery == 0 {
            let d = z0 + 14
            for (side, title) in [(-1.0, "← Canali"), (1.0, "Calli →")] {
                let (image, aspect) = SignFactory.image(title: title, text: side < 0 ? "braccio a sinistra" : "braccio a destra", style: .info)
                let node = signNode(image: image, width: 2.2, height: 2.2 / aspect)
                node.position = SCNVector3(Float(wallOffset(at: d, side: side) - side * 0.9), 2.7, Float(-d))
                node.eulerAngles.y = Float(side > 0 ? -0.6 : 0.6)
                dynamicNode.addChildNode(node)
            }
        }

        let container = SCNNode()
        let flat = staticNode.flattenedClone()
        flat.castsShadow = true
        container.addChildNode(flat)
        container.addChildNode(dynamicNode)
        return container
    }

    private func addGround(_ parent: SCNNode, x: Double, width: Double, from d: Double, length: Double) {
        let box = SCNBox(width: CGFloat(width), height: 0.4, length: CGFloat(length), chamferRadius: 0)
        box.firstMaterial = pavingMaterial(width: width, length: length)
        let node = SCNNode(geometry: box)
        node.position = SCNVector3(Float(x), -0.2, Float(-(d + length / 2)))
        parent.addChildNode(node)
    }

    /// Fila di case lungo il percorso, dal bordo interno `innerX` verso l'esterno.
    private func addRowOfHouses(_ parent: SCNNode, side: Double, innerX: Double, from d: Double, length: Double,
                                rng: inout SeededRandom, baseY: Double) {
        var cursor = d
        while cursor < d + length - 0.5 {
            let w = min(rng.next(in: 4...7.5), d + length - cursor)
            let depth = 7.0
            let height = rng.next(in: 9...15)
            addHouse(parent, centerX: side * (innerX + depth / 2), centerD: cursor + w / 2,
                     widthAlongPath: w, depth: depth, height: height, baseY: baseY, rng: &rng)
            cursor += w
        }
    }

    private func addHouse(_ parent: SCNNode, centerX: Double, centerD: Double, widthAlongPath: Double,
                          depth: Double, height: Double, baseY: Double, rng: inout SeededRandom) {
        let box = SCNBox(width: CGFloat(depth), height: CGFloat(height), length: CGFloat(widthAlongPath), chamferRadius: 0)
        let facade = facadeMaterials[rng.nextInt(facadeMaterials.count)]
        box.materials = [facade, facade, facade, facade, roofMaterial, darkMaterial]
        let node = SCNNode(geometry: box)
        node.position = SCNVector3(Float(centerX), Float(baseY + height / 2), Float(-centerD))
        parent.addChildNode(node)

        // Cornicione in pietra e comignolo veneziano "a imbuto"
        let cornice = SCNNode(geometry: SCNBox(width: CGFloat(depth + 0.3), height: 0.25, length: CGFloat(widthAlongPath + 0.1), chamferRadius: 0))
        cornice.geometry?.firstMaterial = stoneMaterial
        cornice.position = SCNVector3(Float(centerX), Float(baseY + height), Float(-centerD))
        parent.addChildNode(cornice)
        if rng.nextInt(3) == 0 {
            let chimney = SCNNode(geometry: SCNCone(topRadius: 0.35, bottomRadius: 0.15, height: 0.8))
            chimney.geometry?.firstMaterial = brickMaterial
            let stack = SCNNode(geometry: SCNCylinder(radius: 0.15, height: 1.2))
            stack.geometry?.firstMaterial = brickMaterial
            let x = Float(centerX + rng.next(in: -1.5...1.5))
            stack.position = SCNVector3(x, Float(baseY + height + 0.6), Float(-centerD))
            chimney.position = SCNVector3(x, Float(baseY + height + 1.6), Float(-centerD))
            parent.addChildNode(stack)
            parent.addChildNode(chimney)
        }
    }

    /// Isolato compatto ai lati del ponte: affaccia sulla calle e sul canale.
    private func addBlock(_ parent: SCNNode, side: Double, from d: Double, length: Double, rng: inout SeededRandom) {
        var x = 1.75
        while x < 40 {
            let w = rng.next(in: 5...8)
            let height = rng.next(in: 9...14)
            addHouse(parent, centerX: side * (x + w / 2), centerD: d + length / 2, widthAlongPath: length,
                     depth: w, height: height, baseY: -1.0, rng: &rng)
            x += w
        }
    }

    /// Canale parallelo al percorso, con riva in pietra d'Istria, case sull'altra sponda, pali e gondole.
    private func addCanalAlongPath(_ parent: SCNNode, _ dynamic: SCNNode, side: Double, from d: Double, rng: inout SeededRandom) {
        let canalWidth = 10.0
        let innerEdge = 2.0
        let centerX = side * (innerEdge + canalWidth / 2)

        let water = SCNNode(geometry: SCNBox(width: CGFloat(canalWidth), height: 0.05, length: CGFloat(chunkLength), chamferRadius: 0))
        water.geometry?.firstMaterial = waterMaterial
        water.position = SCNVector3(Float(centerX), -0.9, Float(-(d + chunkLength / 2)))
        parent.addChildNode(water)

        // Muro di sponda e bordo in pietra bianca
        for edge in [innerEdge, innerEdge + canalWidth] {
            let wall = SCNNode(geometry: SCNBox(width: 0.4, height: 1.6, length: CGFloat(chunkLength), chamferRadius: 0))
            wall.geometry?.firstMaterial = brickMaterial
            wall.position = SCNVector3(Float(side * edge), -0.8, Float(-(d + chunkLength / 2)))
            parent.addChildNode(wall)
        }
        let rim = SCNNode(geometry: SCNBox(width: 0.45, height: 0.12, length: CGFloat(chunkLength), chamferRadius: 0.02))
        rim.geometry?.firstMaterial = stoneMaterial
        rim.position = SCNVector3(Float(side * innerEdge), 0.0, Float(-(d + chunkLength / 2)))
        parent.addChildNode(rim)

        // Case sull'altra sponda, che salgono dall'acqua
        addRowOfHouses(parent, side: side, innerX: innerEdge + canalWidth + 0.2, from: d, length: chunkLength, rng: &rng, baseY: -1.0)

        // Pali da ormeggio a strisce
        for _ in 0..<rng.nextInt(3) {
            let poleX = side * (innerEdge + rng.next(in: 0.8...2.0))
            let poleD = d + rng.next(in: 2...22)
            addMooringPole(parent, x: poleX, d: poleD, rng: &rng)
        }
        // Gondola
        if rng.nextInt(2) == 0 {
            let gondola = makeGondola()
            gondola.position = SCNVector3(Float(side * (innerEdge + rng.next(in: 3...7))), -0.8, Float(-(d + rng.next(in: 4...20))))
            let direction: Float = rng.nextInt(2) == 0 ? 1 : -1
            gondola.runAction(.repeatForever(.sequence([
                .moveBy(x: 0, y: 0, z: CGFloat(direction * 20), duration: 25),
                .moveBy(x: 0, y: 0, z: CGFloat(-direction * 20), duration: 25),
            ])))
            dynamic.addChildNode(gondola)
        }
    }

    /// Rio che attraversa il percorso (sotto il ponte).
    private func addCrossCanal(_ parent: SCNNode, _ dynamic: SCNNode, from d: Double, width: Double, rng: inout SeededRandom) {
        let water = SCNNode(geometry: SCNBox(width: 90, height: 0.05, length: CGFloat(width), chamferRadius: 0))
        water.geometry?.firstMaterial = waterMaterial
        water.position = SCNVector3(0, -0.9, Float(-(d + width / 2)))
        parent.addChildNode(water)
        for edge in [d, d + width] {
            let wall = SCNNode(geometry: SCNBox(width: 90, height: 1.6, length: 0.4, chamferRadius: 0))
            wall.geometry?.firstMaterial = brickMaterial
            wall.position = SCNVector3(0, -0.8, Float(-edge))
            parent.addChildNode(wall)
        }
        if rng.nextInt(2) == 0 {
            let gondola = makeGondola()
            gondola.eulerAngles.y = .pi / 2
            gondola.position = SCNVector3(-30, -0.8, Float(-(d + width / 2 + rng.next(in: -2...2))))
            gondola.runAction(.repeatForever(.sequence([
                .moveBy(x: 60, y: 0, z: 0, duration: 40),
                .moveBy(x: -60, y: 0, z: 0, duration: 40),
            ])))
            dynamic.addChildNode(gondola)
        }
        for _ in 0..<2 {
            let poleX = rng.next(in: 4...20) * (rng.nextInt(2) == 0 ? 1 : -1)
            let poleD = d + rng.next(in: 1...3)
            addMooringPole(parent, x: poleX, d: poleD, rng: &rng)
        }
    }

    /// Ponte ad arco in mattoni con gradini e bordi in pietra d'Istria.
    private func addBridge(_ parent: SCNNode, range: ClosedRange<Double>) {
        let steps = 24
        let length = range.upperBound - range.lowerBound
        let stepLength = length / Double(steps)
        for i in 0..<steps {
            let dMid = range.lowerBound + (Double(i) + 0.5) * stepLength
            let t = (dMid - range.lowerBound) / length
            let h = bridgeHeight * sin(.pi * t)
            let stepNode = SCNNode(geometry: SCNBox(width: 3.2, height: CGFloat(h + 1.2), length: CGFloat(stepLength + 0.01), chamferRadius: 0))
            stepNode.geometry?.materials = [brickMaterial, brickMaterial, brickMaterial, brickMaterial, pavingMaterial(width: 3.2, length: stepLength), brickMaterial]
            stepNode.position = SCNVector3(0, Float((h - 1.2) / 2), Float(-dMid))
            parent.addChildNode(stepNode)
            // Bordo bianco del gradino
            let edge = SCNNode(geometry: SCNBox(width: 3.2, height: 0.03, length: 0.12, chamferRadius: 0))
            edge.geometry?.firstMaterial = stoneMaterial
            edge.position = SCNVector3(0, Float(h + 0.01), Float(-(dMid - stepLength / 2 + 0.06)))
            parent.addChildNode(edge)
            // Parapetti
            for side in [-1.0, 1.0] {
                let parapet = SCNNode(geometry: SCNBox(width: 0.25, height: 0.9, length: CGFloat(stepLength + 0.02), chamferRadius: 0))
                parapet.geometry?.firstMaterial = brickMaterial
                parapet.position = SCNVector3(Float(side * 1.6), Float(h + 0.45), Float(-dMid))
                parent.addChildNode(parapet)
                let cap = SCNNode(geometry: SCNBox(width: 0.32, height: 0.08, length: CGFloat(stepLength + 0.02), chamferRadius: 0))
                cap.geometry?.firstMaterial = stoneMaterial
                cap.position = SCNVector3(Float(side * 1.6), Float(h + 0.94), Float(-dMid))
                parent.addChildNode(cap)
            }
        }
    }

    private func addMooringPole(_ parent: SCNNode, x: Double, d: Double, rng: inout SeededRandom) {
        let colors: [UIColor] = [.white, UIColor(red: 0.75, green: 0.12, blue: 0.12, alpha: 1), UIColor(red: 0.10, green: 0.25, blue: 0.55, alpha: 1)]
        let accent = colors[1 + rng.nextInt(2)]
        for i in 0..<6 {
            let segment = SCNNode(geometry: SCNCylinder(radius: 0.12, height: 0.5))
            segment.geometry?.firstMaterial = colorMaterial(i % 2 == 0 ? .white : accent)
            segment.position = SCNVector3(Float(x), Float(-0.9 + 0.25 + Double(i) * 0.5), Float(-d))
            parent.addChildNode(segment)
        }
    }

    private func addWell(_ parent: SCNNode, x: Double, d: Double) {
        let well = SCNNode(geometry: SCNCylinder(radius: 0.8, height: 0.9))
        well.geometry?.firstMaterial = stoneMaterial
        well.position = SCNVector3(Float(x), 0.45, Float(-d))
        parent.addChildNode(well)
        let top = SCNNode(geometry: SCNCylinder(radius: 0.6, height: 0.02))
        top.geometry?.firstMaterial = darkMaterial
        top.position = SCNVector3(Float(x), 0.91, Float(-d))
        parent.addChildNode(top)
    }

    private func addCampanile(_ parent: SCNNode, x: Double, d: Double) {
        let tower = SCNNode(geometry: SCNBox(width: 4, height: 34, length: 4, chamferRadius: 0))
        tower.geometry?.firstMaterial = brickMaterial
        tower.position = SCNVector3(Float(x), 17, Float(-d))
        parent.addChildNode(tower)
        let belfry = SCNNode(geometry: SCNBox(width: 4.4, height: 5, length: 4.4, chamferRadius: 0))
        belfry.geometry?.firstMaterial = stoneMaterial
        belfry.position = SCNVector3(Float(x), 36.5, Float(-d))
        parent.addChildNode(belfry)
        let spire = SCNNode(geometry: SCNPyramid(width: 4.4, height: 7, length: 4.4))
        spire.geometry?.firstMaterial = colorMaterial(UIColor(red: 0.35, green: 0.50, blue: 0.42, alpha: 1))
        spire.position = SCNVector3(Float(x), 39, Float(-d))
        parent.addChildNode(spire)
    }

    private func addLaundryLine(_ parent: SCNNode, at d: Double, rng: inout SeededRandom) {
        let y = Float(rng.next(in: 5...8))
        let line = SCNNode(geometry: SCNCylinder(radius: 0.008, height: 3.5))
        line.geometry?.firstMaterial = darkMaterial
        line.eulerAngles.z = .pi / 2
        line.position = SCNVector3(0, y, Float(-d))
        parent.addChildNode(line)
        let palette: [UIColor] = [.white, .systemBlue, .systemRed, .systemYellow, .systemTeal]
        for i in 0..<5 {
            let cloth = SCNNode(geometry: SCNBox(width: 0.4, height: 0.6, length: 0.01, chamferRadius: 0))
            cloth.geometry?.firstMaterial = colorMaterial(palette[(i + rng.nextInt(5)) % palette.count])
            cloth.position = SCNVector3(Float(-1.3 + Double(i) * 0.65), y - 0.32, Float(-d))
            parent.addChildNode(cloth)
        }
    }

    private func makeGondola() -> SCNNode {
        let node = SCNNode()
        let hull = SCNNode(geometry: SCNCapsule(capRadius: 0.55, height: 10))
        hull.geometry?.firstMaterial = darkMaterial
        hull.eulerAngles.x = .pi / 2
        hull.scale = SCNVector3(1, 1, 0.45)
        node.addChildNode(hull)
        // Ferro di prua
        let ferro = SCNNode(geometry: SCNBox(width: 0.05, height: 0.9, length: 0.4, chamferRadius: 0))
        ferro.geometry?.firstMaterial = stoneMaterial
        ferro.position = SCNVector3(0, 0.6, -5.0)
        node.addChildNode(ferro)
        // Gondoliere stilizzato
        let body = SCNNode(geometry: SCNCapsule(capRadius: 0.22, height: 1.6))
        body.geometry?.firstMaterial = colorMaterial(.white)
        body.position = SCNVector3(0, 1.1, 3.4)
        node.addChildNode(body)
        let hat = SCNNode(geometry: SCNCylinder(radius: 0.25, height: 0.08))
        hat.geometry?.firstMaterial = colorMaterial(UIColor(red: 0.85, green: 0.75, blue: 0.45, alpha: 1))
        hat.position = SCNVector3(0, 2.0, 3.4)
        node.addChildNode(hat)
        let oar = SCNNode(geometry: SCNCylinder(radius: 0.03, height: 4))
        oar.geometry?.firstMaterial = woodMaterial
        oar.eulerAngles.x = 0.5
        oar.position = SCNVector3(0.4, 0.6, 3.0)
        node.addChildNode(oar)
        return node
    }

    private func signNode(image: UIImage, width: CGFloat, height: CGFloat) -> SCNNode {
        let plane = SCNPlane(width: width, height: height)
        let m = SCNMaterial()
        m.diffuse.contents = image
        m.emission.contents = image
        m.emission.intensity = 0.35
        m.isDoubleSided = true
        m.lightingModel = .lambert
        plane.firstMaterial = m
        return SCNNode(geometry: plane)
    }

    // MARK: Materiali

    private func makeMaterial(_ image: UIImage, repeatScale: Float) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = image
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(repeatScale, repeatScale, 1)
        m.lightingModel = .physicallyBased
        m.roughness.contents = 0.85
        return m
    }

    private func colorMaterial(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .physicallyBased
        m.roughness.contents = 0.7
        return m
    }

    private func pavingMaterial(width: Double, length: Double) -> SCNMaterial {
        let key = "\(Int(width * 10))x\(Int(length * 10))"
        if let m = pavingCache[key] { return m }
        let m = makeMaterial(TextureFactory.paving(), repeatScale: 1)
        // una "piastrella" di texture ≈ 3 m
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(Float(width / 3), Float(length / 3), 1)
        pavingCache[key] = m
        return m
    }
}
