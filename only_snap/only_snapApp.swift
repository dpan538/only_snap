//
//  only_snapApp.swift
//  only_snap
//
//  Created by Jarl Giovanni on 4/25/26.
//

import SwiftUI

@main
struct only_snapApp: App {

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
                // (e.g. permission dialogs, control center) to avoid session restarts
                camera.stop()
            default:
                break
            }
        }
    }
}
