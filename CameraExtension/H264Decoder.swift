import CoreMedia
import Foundation
import VideoToolbox
import os.log

/// Decodes Annex-B H.264 access units (one per call) into IOSurface-backed NV12 pixel buffers.
final class H264Decoder {
    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private let onFrame: (CVPixelBuffer) -> Void

    init(onFrame: @escaping (CVPixelBuffer) -> Void) {
        self.onFrame = onFrame
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        sps = nil
        pps = nil
    }

    func decode(accessUnit: Data) {
        var slices: [Data] = []
        var newSPS = sps
        var newPPS = pps
        for nal in Self.splitAnnexB(accessUnit) {
            switch nal[nal.startIndex] & 0x1F {
            case 7: newSPS = nal
            case 8: newPPS = nal
            case 9: break  // access unit delimiter
            default: slices.append(nal)
            }
        }
        if newSPS != sps || newPPS != pps, let newSPS, let newPPS {
            sps = newSPS
            pps = newPPS
            makeSession()
        }
        guard let session, let formatDescription, !slices.isEmpty,
              let sample = Self.makeSample(slices: slices, format: formatDescription)
        else { return }

        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            [onFrame] status, _, imageBuffer, _, _ in
            if status == noErr, let imageBuffer {
                onFrame(imageBuffer)
            }
        }
    }

    private func makeSession() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        guard let sps, let pps else { return }

        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else {
            os_log(.error, "H.264 parameter sets rejected: %d", status)
            return
        }

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var newSession: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &newSession)
        guard created == noErr, let newSession else {
            os_log(.error, "VTDecompressionSessionCreate failed: %d", created)
            return
        }
        formatDescription = format
        session = newSession
    }

    /// Repackages Annex-B NAL units as one AVCC (4-byte length-prefixed) sample.
    private static func makeSample(slices: [Data], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var avcc = Data(capacity: slices.reduce(0) { $0 + $1.count + 4 })
        for nal in slices {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr, let block
        else { return nil }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }

    /// Splits on 00 00 01 / 00 00 00 01 start codes, returning NAL payloads without them.
    static func splitAnnexB(_ data: Data) -> [Data] {
        var nals: [Data] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            let n = p.count
            var i = 0
            var start = -1
            while i + 2 < n {
                if p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1 {
                    if start >= 0 {
                        var end = i
                        while end > start && p[end - 1] == 0 { end -= 1 }  // trailing zero / 4-byte code
                        if end > start { nals.append(Data(p[start..<end])) }
                    }
                    i += 3
                    start = i
                } else {
                    i += 1
                }
            }
            if start >= 0 {
                var end = n
                while end > start && p[end - 1] == 0 { end -= 1 }  // zero padding after the last NAL
                if end > start { nals.append(Data(p[start..<end])) }
            }
        }
        return nals
    }
}
