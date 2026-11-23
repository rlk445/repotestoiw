import SwiftUI

final class AppModel: ObservableObject {
    let tracker = HandTracker()
    let motion = MotionController()
    let audio = AudioManager()
    weak var renderer: Renderer?

    @Published var gyroEnabled = true {
        didSet { motion.enabled = gyroEnabled }
    }
    @Published var showCamera = true
    @Published var renderInfo = "renderer: iniciando…"
    private var started = false

    func start() {
        if started { return }
        started = true
        motion.start()
        audio.startAmbient()
        tracker.start()
    }

    func recenter() {
        renderer?.recenter()
    }
}
