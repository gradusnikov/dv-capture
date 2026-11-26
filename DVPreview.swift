import SwiftUI
import AVFoundation
import VideoToolbox

// Used on the helper pipe's serial reader. The decoder handles interlaced DV
// directly and hands its pixel buffers to the display layer without JPEG copies.
final class DVPreviewDecoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var frameIndex: Int64 = 0
    private var frameBytes = 0

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func decode(_ data: Data, deliver: @escaping (CMSampleBuffer) -> Void) throws {
        let pal = data.count == 144000
        if data.count != frameBytes {
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
            frameBytes = 0
            try check(CMVideoFormatDescriptionCreate(allocator: nil,
                codecType: pal ? kCMVideoCodecType_DVCPAL : kCMVideoCodecType_DVCNTSC,
                width: 720, height: pal ? 576 : 480, extensions: nil, formatDescriptionOut: &format))
            let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_422YpCbCr8] as CFDictionary
            try check(VTDecompressionSessionCreate(allocator: nil, formatDescription: format!,
                decoderSpecification: nil, imageBufferAttributes: attributes, outputCallback: nil,
                decompressionSessionOut: &session))
            try check(VTSessionSetProperty(session!, key: kVTDecompressionPropertyKey_FieldMode,
                value: kVTDecompressionProperty_FieldMode_DeinterlaceFields))
            frameBytes = data.count
            frameIndex = 0
        }
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil,
            blockLength: data.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: 0, blockBufferOut: &block))
        try data.withUnsafeBytes { bytes in
            try check(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!,
                offsetIntoDestination: 0, dataLength: data.count))
        }
        let duration = CMTime(value: pal ? 1 : 1001, timescale: pal ? 25 : 30000)
        var timing = CMSampleTimingInfo(duration: duration,
            presentationTimeStamp: CMTime(value: frameIndex * duration.value, timescale: duration.timescale),
            decodeTimeStamp: .invalid)
        frameIndex += 1
        var size = data.count
        var sample: CMSampleBuffer?
        try check(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample))
        var outputStatus: OSStatus = noErr
        try check(VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sample!, flags: [],
            infoFlagsOut: nil, outputHandler: { status, _, image, pts, duration in
            outputStatus = status
            guard status == noErr, let image else { return }
            var desc: CMVideoFormatDescription?
            outputStatus = CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
                formatDescriptionOut: &desc)
            guard outputStatus == noErr, let desc else { return }
            var time = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            var display: CMSampleBuffer?
            outputStatus = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
                formatDescription: desc, sampleTiming: &time, sampleBufferOut: &display)
            if let display {
                if let array = CMSampleBufferGetSampleAttachmentsArray(display, createIfNecessary: true) {
                    let flags = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
                    CFDictionarySetValue(flags, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                         Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
                }
                deliver(display)
            }
        }))
        try check(outputStatus)
    }
}

struct PixelPreview: NSViewRepresentable {
    let display: AVSampleBufferDisplayLayer
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        display.videoGravity = .resize
        view.layer = display
        view.wantsLayer = true
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
