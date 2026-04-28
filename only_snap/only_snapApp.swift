//
//  only_snapApp.swift
//  only_snap
//
//  Created by Jarl Giovanni on 4/25/26.
//

import SwiftUI

// MARK: - AppDelegate  (portrait-only orientation lock)
//
// SwiftUI's WindowGroup has no .supportedInterfaceOrientations modifier on iOS.
// The only reliable way to lock to portrait programmatically is via
// UIApplicationDelegate.application(_:supportedInterfaceOrientationsFor:).
// Device orientation changes are still tracked through UIDevice notifications in
// ContentView and used solely to rotate individual icons + adjust videoRotationAngle —
// the layout itself never rotates, keeping AVCaptureVideoPreviewLayer out of any
// transformed CALayer hierarchy (which would corrupt the XPC link → err=-17281).

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        return .portrait
    }
}

// MARK: - App

@main
struct only_snapApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var camera = CameraManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(camera)
                .preferredColorScheme(.light)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                Task { await camera.start() }
            case .background:
                // Only stop when truly backgrounded, not on transient .inactive
                // (e.g. permission dialogs, control center) to avoid session restarts.
                camera.stop()
            default:
                break
            }
        }
    }
}
