import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI
import UIKit

// MARK: - Video surface (AVPlayerLayer + Picture in Picture)

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct VideoSurface: UIViewRepresentable {
    let controller: VideoPlayerController

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = .black
        view.playerLayer.player = controller.avPlayer
        view.playerLayer.videoGravity = controller.gravity
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let pip = AVPictureInPictureController(playerLayer: view.playerLayer)
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
            DispatchQueue.main.async { controller.pip = pip }
        }
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        if view.playerLayer.videoGravity != controller.gravity {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            view.playerLayer.videoGravity = controller.gravity
            CATransaction.commit()
        }
    }
}

// MARK: - System volume & brightness

@MainActor
enum DeviceControls {
    static weak var volumeSlider: UISlider?

    static var volume: Float {
        get { volumeSlider?.value ?? AVAudioSession.sharedInstance().outputVolume }
        set { volumeSlider?.value = max(0, min(1, newValue)) }
    }

    static var screen: UIScreen? {
        (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?.screen
    }

    static var brightness: CGFloat {
        get { screen?.brightness ?? 0.5 }
        set { screen?.brightness = max(0, min(1, newValue)) }
    }
}

/// An invisible MPVolumeView: lets gestures change the volume and hides the system volume HUD.
struct HiddenVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 10, height: 10))
        view.alpha = 0.0001
        DispatchQueue.main.async {
            DeviceControls.volumeSlider = view.subviews.compactMap { $0 as? UISlider }.first
        }
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - Orientation

final class AppDelegate: NSObject, UIApplicationDelegate {
    nonisolated(unsafe) static var orientationMask: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationMask
    }
}

@MainActor
enum Orientation {
    static func allow(_ mask: UIInterfaceOrientationMask, prefer: UIInterfaceOrientationMask) {
        AppDelegate.orientationMask = mask
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene else { return }
        var vc = scene.keyWindow?.rootViewController
        while let current = vc {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            vc = current.presentedViewController
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: prefer)) { _ in }
    }
}
