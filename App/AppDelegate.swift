//
//  AppDelegate.swift
//  SteelFront
//

import UIKit
import AVFoundation

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = GameViewController()
        window.backgroundColor = UIColor(white: 0.04, alpha: 1)
        window.makeKeyAndVisible()
        self.window = window

        // Keep the screen awake during a run.
        application.isIdleTimerDisabled = true
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .landscape
    }

    func applicationWillResignActive(_ application: UIApplication) {
        AVAudioSessionPause()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        AVAudioSessionResume()
    }
}

// Small helpers so the audio session does not fight other apps.
private func AVAudioSessionPause() {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
}

private func AVAudioSessionResume() {
    try? AVAudioSession.sharedInstance().setActive(true)
}
