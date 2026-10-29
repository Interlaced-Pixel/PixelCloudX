import AppKit
import Combine
import Sparkle

@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()
    @Published private(set) var canCheck = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var installationWaiting = false
    @Published var automaticallyChecks = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    @Published var automaticallyDownloads = false {
        didSet { controller?.updater.automaticallyDownloadsUpdates = automaticallyDownloads }
    }
    private var controller: SPUStandardUpdaterController!
    private weak var stream: XboxCloudStreamController?
    private var subscriptions: Set<AnyCancellable> = []
    private var installAfterStream: (() -> Void)?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastCheck)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloads)
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
    }
    func start(stream: XboxCloudStreamController) {
        guard self.stream == nil else { return }
        self.stream = stream
        stream.$phase.sink { [weak self] phase in
            guard phase == .idle else { return }
            DispatchQueue.main.async {
                guard let self, self.stream?.isActive != true, let install = self.installAfterStream else { return }
                self.installAfterStream = nil
                self.installationWaiting = false
                install()
            }
        }.store(in: &subscriptions)
        controller.startUpdater()
    }
    func check() { controller.checkForUpdates(nil) }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard stream?.isActive != true else {
            throw NSError(domain: "PixelCloudX.Updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "End the game stream before checking for updates."])
        }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard stream?.isActive == true else { return false }
        installAfterStream = installHandler
        installationWaiting = true
        return true
    }
}
