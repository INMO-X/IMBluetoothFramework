//
//  AppDelegate.swift
//  IMBluetoothKitExample
//

import UIKit
import IMBluetoothKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        BluetoothLogger.isEnabled = true
        BluetoothLogger.sink = { message in
            print(message)
        }
        DeviceRegistry.shared.register(C100Factory())
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
