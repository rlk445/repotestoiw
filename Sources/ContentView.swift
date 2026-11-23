import SwiftUI

struct HUDBar: View {
    @ObservedObject var tracker: HandTracker
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Text(model.renderInfo)
                .font(.caption2)
                .foregroundColor(.yellow)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.6))
                .clipShape(Capsule())
            Text(tracker.status)
                .font(.footnote)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.45))
                .clipShape(Capsule())
            HStack(spacing: 10) {
                button(model.gyroEnabled ? "Giro: ligado" : "Giro: desligado") {
                    model.gyroEnabled.toggle()
                }
                button(model.showCamera ? "Câmera: ligada" : "Câmera: oculta") {
                    model.showCamera.toggle()
                }
                button("Centralizar") {
                    model.recenter()
                }
            }
        }
        .padding(.bottom, 28)
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.black.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        ZStack {
            MetalView(model: model)
                .ignoresSafeArea()
            VStack {
                HStack {
                    Spacer()
                    if model.showCamera {
                        CameraPreview(session: model.tracker.session)
                            .frame(width: 104, height: 138)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.5), lineWidth: 1))
                            .padding(.top, 54)
                            .padding(.trailing, 14)
                    }
                }
                Spacer()
                HUDBar(tracker: model.tracker, model: model)
            }
        }
        .onAppear { model.start() }
    }
}
