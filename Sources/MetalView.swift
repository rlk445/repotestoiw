import SwiftUI
import MetalKit

struct MetalView: UIViewRepresentable {
    let model: AppModel

    final class Coordinator: NSObject {
        var renderer: Renderer?

        @objc func pan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            renderer?.addLook(yaw: Float(t.x) * 0.005, pitch: Float(t.y) * 0.005)
        }
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        if let r = Renderer(view: view, model: model) {
            context.coordinator.renderer = r
            model.renderer = r
            view.delegate = r
            DispatchQueue.main.async { model.renderInfo = r.summary }
        } else {
            DispatchQueue.main.async { model.renderInfo = "ERRO renderer: " + Renderer.lastError }
        }
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
