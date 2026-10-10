import ServiceManagement
import SwiftUI
import SystemExtensions

let kExtensionID = "com.quirklocal.tr256ecam.camera"
let kHelperPlist = "com.quirklocal.tr256ecam.helper.plist"

@main
struct TR256ECamApp: App {
    @StateObject private var installer = Installer()

    var body: some Scene {
        WindowGroup("TR256E Camera") {
            ContentView()
                .environmentObject(installer)
                .frame(width: 420)
                .fixedSize()
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @EnvironmentObject var installer: Installer

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Makes the Mileseey TR256E show up as a working webcam called **TR256E Thermal**.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    row("Camera extension", installer.extensionStatus)
                    HStack {
                        Button("Install / Update") { installer.activateExtension() }
                        Button("Uninstall") { installer.deactivateExtension() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    row("USB helper", installer.helperStatus)
                    HStack {
                        Button("Enable") { installer.registerHelper() }
                        Button("Disable") { installer.unregisterHelper() }
                        if installer.helperNeedsApproval {
                            Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            Text("The helper runs as root because only root can take the camera's video port away from macOS. It only talks to the camera while an app is using TR256E Thermal.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .onAppear { installer.refreshHelperStatus() }
    }

    private func row(_ title: String, _ status: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).bold()
            Spacer()
            Text(status).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

final class Installer: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var extensionStatus = "Unknown"
    @Published var helperStatus = "Unknown"
    @Published var helperNeedsApproval = false

    private let helper = SMAppService.daemon(plistName: kHelperPlist)

    // MARK: Camera extension

    func activateExtension() {
        extensionStatus = "Installing…"
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: kExtensionID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivateExtension() {
        extensionStatus = "Uninstalling…"
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: kExtensionID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(
        _ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        extensionStatus = "Approve it in System Settings → General → Login Items & Extensions"
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed: extensionStatus = "Done"
        case .willCompleteAfterReboot: extensionStatus = "Done after reboot"
        @unknown default: extensionStatus = "Finished (\(result.rawValue))"
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        extensionStatus = "Failed: \(error.localizedDescription)"
    }

    // MARK: Helper daemon

    func registerHelper() {
        do {
            // Re-register so launchd picks up a rebuilt helper binary.
            if helper.status == .enabled { try? helper.unregister() }
            try helper.register()
        } catch {
            helperStatus = "Failed: \(error.localizedDescription)"
            refreshHelperStatus(keepError: true)
            return
        }
        refreshHelperStatus()
    }

    func unregisterHelper() {
        helper.unregister { [weak self] _ in
            DispatchQueue.main.async { self?.refreshHelperStatus() }
        }
    }

    func refreshHelperStatus(keepError: Bool = false) {
        let status = helper.status
        helperNeedsApproval = status == .requiresApproval
        if keepError { return }
        switch status {
        case .enabled: helperStatus = "Running"
        case .requiresApproval: helperStatus = "Allow it under Login Items in System Settings"
        case .notRegistered: helperStatus = "Not enabled"
        case .notFound: helperStatus = "Not found in app bundle"
        @unknown default: helperStatus = "Unknown"
        }
    }
}
