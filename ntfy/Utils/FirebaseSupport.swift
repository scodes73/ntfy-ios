import Foundation

/// Controls whether Firebase/FCM is used.
/// On the **simulator** we skip Firebase by default so the app runs without a real
/// `GoogleService-Info.plist` / Google account. Real devices still use Firebase when the plist is present.
///
/// Opt into Firebase on simulator: set env `NTFY_ENABLE_FIREBASE=1` in the Xcode scheme.
enum FirebaseSupport {
    static var isEnabled: Bool {
        let hasPlist = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil
        #if targetEnvironment(simulator)
        let force = ProcessInfo.processInfo.environment["NTFY_ENABLE_FIREBASE"] == "1"
        return force && hasPlist
        #else
        return hasPlist
        #endif
    }

    static var isSimulatorDevMode: Bool {
        #if targetEnvironment(simulator)
        return !isEnabled
        #else
        return false
        #endif
    }
}
