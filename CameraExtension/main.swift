import CoreMediaIO
import Foundation

let providerSource = ThermalProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
