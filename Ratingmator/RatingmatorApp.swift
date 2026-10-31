//
//  RatingmatorApp.swift
//  Ratingmator
//
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct RatingmatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Ratingmator", id: "main") {
            RootView()
                .environmentObject(model)
        }
        .windowResizability(.contentMinSize)

        Window("Conflicts", id: "conflicts") {
            ConflictsWindow()
                .environmentObject(model)
        }
    }
}
