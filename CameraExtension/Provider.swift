import CoreMediaIO
import Foundation
import IOKit.audio
import os.log

// The camera's UVC stream is its screen: 256x342 H.264 at 25 fps.
let kNativeWidth: Int32 = 256
let kNativeHeight: Int32 = 342
let kFrameRate: Int32 = 25
let kHelperPort: UInt16 = 47256

// Fixed so apps remember the camera between launches.
let kDeviceID = UUID(uuidString: "F6BD0896-F004-4AE6-A37F-6F520AC1EA17")!
let kStreamID = UUID(uuidString: "68B12E0C-2995-4F31-84DE-8AF717F29956")!

/// An output size. Scale > 1 is nearest-neighbor so the thermal pixels stay crisp.
struct OutputFormat {
    let scale: Int
    let description: CMVideoFormatDescription
    let pool: CVPixelBufferPool
    let placeholder: CVPixelBuffer

    init(scale: Int) {
        self.scale = scale
        let width = kNativeWidth * Int32(scale)
        let height = kNativeHeight * Int32(scale)
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width: width, height: height, extensions: nil, formatDescriptionOut: &description)
        self.description = description!

        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        self.pool = pool!

        // Near-black frame shown while the camera isn't sending anything.
        var placeholder: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool!, &placeholder)
        CVPixelBufferLockBaseAddress(placeholder!, [])
        for (plane, value) in [(0, UInt8(24)), (1, UInt8(128))] {
            memset(
                CVPixelBufferGetBaseAddressOfPlane(placeholder!, plane), Int32(value),
                CVPixelBufferGetBytesPerRowOfPlane(placeholder!, plane)
                    * CVPixelBufferGetHeightOfPlane(placeholder!, plane))
        }
        CVPixelBufferUnlockBaseAddress(placeholder!, [])
        self.placeholder = placeholder!
    }

    var streamFormat: CMIOExtensionStreamFormat {
        let duration = CMTime(value: 1, timescale: kFrameRate)
        return CMIOExtensionStreamFormat(
            formatDescription: description, maxFrameDuration: duration, minFrameDuration: duration,
            validFrameDurations: nil)
    }

    /// Returns the frame at this format's size: the decoder's buffer as-is at 1x, a scaled copy otherwise.
    func render(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        if scale == 1 { return source }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess,
              let output
        else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        // NV12: plane 0 is Y (1 byte/pixel), plane 1 is interleaved CbCr at half resolution (2 bytes/pixel).
        for plane in 0..<2 {
            let bytesPerPixel = plane == 0 ? 1 : 2
            let src = CVPixelBufferGetBaseAddressOfPlane(source, plane)!.assumingMemoryBound(to: UInt8.self)
            let dst = CVPixelBufferGetBaseAddressOfPlane(output, plane)!.assumingMemoryBound(to: UInt8.self)
            let srcStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let dstStride = CVPixelBufferGetBytesPerRowOfPlane(output, plane)
            let dstWidth = CVPixelBufferGetWidthOfPlane(output, plane)
            let width = min(CVPixelBufferGetWidthOfPlane(source, plane), dstWidth / scale)
            let height = min(CVPixelBufferGetHeightOfPlane(source, plane), CVPixelBufferGetHeightOfPlane(output, plane) / scale)
            for y in 0..<height {
                let srcRow = src + y * srcStride
                let dstRow = dst + y * scale * dstStride
                for x in 0..<width {
                    for k in 0..<scale {
                        let o = (x * scale + k) * bytesPerPixel
                        dstRow[o] = srcRow[x * bytesPerPixel]
                        if bytesPerPixel == 2 { dstRow[o + 1] = srcRow[x * bytesPerPixel + 1] }
                    }
                }
                for k in 1..<scale {
                    memcpy(dstRow + k * dstStride, dstRow, dstWidth * bytesPerPixel)
                }
            }
        }
        CVBufferPropagateAttachments(source, output)
        return output
    }
}

// MARK: -

/// Reads length-prefixed H.264 access units from tr256e-helper and decodes them on its own thread.
final class HelperClient {
    private let lock = NSLock()
    private var socketFD: Int32 = -1
    private var running = true
    private let onFrame: (CVPixelBuffer) -> Void

    init(onFrame: @escaping (CVPixelBuffer) -> Void) {
        self.onFrame = onFrame
        Thread { [self] in run() }.start()
    }

    func stop() {
        lock.lock()
        running = false
        if socketFD >= 0 { shutdown(socketFD, SHUT_RDWR) }
        lock.unlock()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func run() {
        while isRunning {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = kHelperPort.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if connected != 0 {
                os_log(.error, "can't reach tr256e-helper on port %d: %{public}s", kHelperPort, String(cString: strerror(errno)))
                close(fd)
                usleep(1_000_000)
                continue
            }

            lock.lock()
            socketFD = fd
            let keepGoing = running
            lock.unlock()
            if keepGoing {
                os_log(.info, "connected to tr256e-helper")
                let decoder = H264Decoder(onFrame: onFrame)
                while let accessUnit = readFrame(fd) {
                    decoder.decode(accessUnit: accessUnit)
                }
                decoder.invalidate()
            }
            lock.lock()
            socketFD = -1
            lock.unlock()
            close(fd)
            if isRunning { usleep(500_000) }
        }
    }

    private func readFrame(_ fd: Int32) -> Data? {
        guard let header = readExactly(fd, 4) else { return nil }
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length < 4 << 20 else {
            os_log(.error, "bad frame length %d", length)
            return nil
        }
        return readExactly(fd, length)
    }

    private func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, count - offset) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            offset += n
        }
        return data
    }
}

// MARK: -

class ThermalDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private var streamSource: ThermalStreamSource!
    let outputFormats = [OutputFormat(scale: 3), OutputFormat(scale: 1)]

    private let stateQueue = DispatchQueue(label: "tr256e.state")
    private var client: HelperClient?
    private var placeholderTimer: DispatchSourceTimer?
    private let frameLock = NSLock()
    private var lastFrameHostTime: UInt64 = 0

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: kDeviceID, legacyDeviceID: nil, source: self)
        streamSource = ThermalStreamSource(
            localizedName: "TR256E Thermal.Video", streamID: kStreamID,
            streamFormats: outputFormats.map(\.streamFormat), device: device)
        do {
            try device.addStream(streamSource.stream)
        } catch let error {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "Mileseey TR256E"
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func startStreaming() {
        stateQueue.sync {
            guard client == nil else { return }
            client = HelperClient { [weak self] frame in self?.deliver(frame) }

            // Show a placeholder whenever the camera has gone quiet for a second.
            let timer = DispatchSource.makeTimerSource(queue: stateQueue)
            timer.schedule(deadline: .now(), repeating: 0.2)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.frameLock.lock()
                let last = self.lastFrameHostTime
                self.frameLock.unlock()
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                if UInt64(now.seconds * Double(NSEC_PER_SEC)) - last > NSEC_PER_SEC {
                    self.send(self.currentFormat.placeholder, at: now)
                }
            }
            timer.resume()
            placeholderTimer = timer
        }
    }

    func stopStreaming() {
        stateQueue.sync {
            client?.stop()
            client = nil
            placeholderTimer?.cancel()
            placeholderTimer = nil
        }
    }

    private var currentFormat: OutputFormat {
        outputFormats[min(max(streamSource.activeFormatIndex, 0), outputFormats.count - 1)]
    }

    private func deliver(_ frame: CVPixelBuffer) {
        guard let output = currentFormat.render(frame) else { return }
        send(output, at: CMClockGetTime(CMClockGetHostTimeClock()), isLive: true)
    }

    private func send(_ pixelBuffer: CVPixelBuffer, at time: CMTime, isLive: Bool = false) {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: kFrameRate), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        var sample: CMSampleBuffer?
        guard let format,
              CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format,
                sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample
        else { return }
        let hostTime = UInt64(time.seconds * Double(NSEC_PER_SEC))
        if isLive {
            frameLock.lock()
            lastFrameHostTime = hostTime
            frameLock.unlock()
        }
        streamSource.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: hostTime)
    }
}

// MARK: -

class ThermalStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let streamFormats: [CMIOExtensionStreamFormat]

    init(localizedName: String, streamID: UUID, streamFormats: [CMIOExtensionStreamFormat], device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormats = streamFormats
        super.init()
        self.stream = CMIOExtensionStream(
            localizedName: localizedName, streamID: streamID, direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] {
        return streamFormats
    }

    var activeFormatIndex: Int = 0 {
        didSet {
            if activeFormatIndex >= streamFormats.count {
                os_log(.error, "Invalid format index %d", activeFormatIndex)
                activeFormatIndex = 0
            }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: kFrameRate)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        return true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? ThermalDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        deviceSource.startStreaming()
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? ThermalDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        deviceSource.stopStreaming()
    }
}

// MARK: -

class ThermalProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: ThermalDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = ThermalDeviceSource(localizedName: "TR256E Thermal")
        do {
            try provider.addDevice(deviceSource.device)
        } catch let error {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "Mileseey"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
