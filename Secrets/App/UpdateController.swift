import Combine
import Sparkle
import SwiftUI

struct UpdatePolicy {
    static let feed = "https://github.com/torbensko/secrets/releases/latest/download/appcast.xml"

    static func permitsUpdates(identifier: String?, channel: String?, feed: String?, publicKey: String?) -> Bool {
        identifier == "com.torbensko.secrets" && channel == "Release" && feed == Self.feed
            && publicKey.flatMap { Data(base64Encoded: $0) }?.count == 32
    }
}

/// Sparkle updates for release builds. Development builds can't replace themselves with a public release.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    let enabled: Bool
    private var controller: SPUStandardUpdaterController?

    init(bundle: Bundle = .main) {
        #if DEBUG
        enabled = false
        #else
        enabled = UpdatePolicy.permitsUpdates(
            identifier: bundle.bundleIdentifier,
            channel: bundle.object(forInfoDictionaryKey: "SecretsUpdateChannel") as? String,
            feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        )
        #endif
        super.init()
        guard enabled else { return }
        // Let Sparkle own permission, scheduling and persisted preferences.
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticChecks)
    }

    func check() { controller?.checkForUpdates(nil) }
    func setAutomaticChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
}

struct UpdateCommands: Commands {
    @ObservedObject var updates: UpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.check() }
                .disabled(!updates.enabled || !updates.canCheck)
            if updates.enabled {
                Toggle("Automatically Check for Updates", isOn: Binding(
                    get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }
                ))
            }
        }
    }
}
