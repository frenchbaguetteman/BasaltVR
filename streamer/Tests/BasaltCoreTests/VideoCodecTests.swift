import CoreMedia
import CoreVideo
import XCTest
@testable import BasaltCore

/// HEVC support: parameter-set extraction, Annex-B framing, and the ALVR
/// codec fields. The parameter sets below are real VideoToolbox output
/// (HEVC Main and H.264 High at 2304x1216 on an M3 Pro).
final class VideoCodecTests: XCTestCase {
    private static let startCode: [UInt8] = [0, 0, 0, 1]
    private static let hevcVPS: [UInt8] = [
        0x40, 0x01, 0x0c, 0x03, 0xff, 0xff, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0xb0, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x99, 0x00, 0x00, 0x0c, 0xc0, 0x90,
    ]
    private static let hevcSPS: [UInt8] = [
        0x42, 0x01, 0x03, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0xb0, 0x00, 0x00, 0x03, 0x00,
        0x00, 0x03, 0x00, 0x99, 0x00, 0x00, 0xa0, 0x01, 0x20, 0x20, 0x04, 0xc1, 0x62, 0x03,
        0x3b, 0x91, 0x48, 0x62, 0xe7, 0xe1, 0x3d, 0x0b, 0xea, 0x1b, 0xd5, 0x0f, 0xea, 0xa0,
        0x8f, 0x55, 0x41, 0x3e, 0xaa, 0xa0, 0xaf, 0x55, 0x54, 0x17, 0xea, 0xaa, 0xa0, 0xcf,
        0x55, 0x55, 0x4a, 0x6a, 0x04, 0x04, 0x04, 0x07, 0xf0, 0x80, 0x41,
    ]
    private static let hevcPPS: [UInt8] = [0x44, 0x01, 0xc0, 0x72, 0xf0, 0x5b, 0x24]
    private static let hevcIDRSlice: [UInt8] = [0x28, 0x01, 0xaf, 0x2d, 0x11]
    private static let hevcPrefixSEI: [UInt8] = [0x4e, 0x01, 0x05, 0x01, 0x80]
    private static let h264SPS: [UInt8] = [
        0x27, 0x64, 0x00, 0x33, 0xac, 0x13, 0x14, 0x10, 0x00, 0x90, 0x02, 0x66, 0x9a, 0x81,
        0x01, 0x01, 0x03, 0xc2, 0x01, 0x08, 0x42,
    ]
    private static let h264PPS: [UInt8] = [0x28, 0xee, 0x3c, 0xb0]

    private func annexB(_ units: [[UInt8]], shortStartCodes: Set<Int> = []) -> Data {
        var data = Data()
        for (index, unit) in units.enumerated() {
            data.append(contentsOf: shortStartCodes.contains(index) ? [0, 0, 1] : Self.startCode)
            data.append(contentsOf: unit)
        }
        return data
    }

    // MARK: NAL types and ALVR codec values

    func testCodecValuesMatchALVR() {
        XCTAssertEqual(VideoCodec.h264.alvrCodecType, 0)
        XCTAssertEqual(VideoCodec.hevc.alvrCodecType, 1)
        XCTAssertEqual(VideoCodec.h264.alvrVariantName, "H264")
        XCTAssertEqual(VideoCodec.hevc.alvrVariantName, "Hevc")
        XCTAssertEqual(VideoCodec.hevc.ffmpegFormat, "hevc")
    }

    func testNALUnitTypesUseEachCodecsHeaderLayout() {
        XCTAssertEqual(VideoCodec.hevc.nalUnitType(headerByte: 0x40), 32) // VPS
        XCTAssertEqual(VideoCodec.hevc.nalUnitType(headerByte: 0x42), 33) // SPS
        XCTAssertEqual(VideoCodec.hevc.nalUnitType(headerByte: 0x44), 34) // PPS
        XCTAssertEqual(VideoCodec.hevc.nalUnitType(headerByte: 0x28), 20) // IDR_N_LP
        XCTAssertEqual(VideoCodec.hevc.nalUnitType(headerByte: 0x26), 19) // IDR_W_RADL
        XCTAssertEqual(VideoCodec.hevc.nalUnitType(headerByte: 0x02), 1)  // TRAIL_R
        XCTAssertEqual(VideoCodec.h264.nalUnitType(headerByte: 0x67), 7)
        XCTAssertEqual(VideoCodec.h264.nalUnitType(headerByte: 0x65), 5)
    }

    // MARK: DecoderConfig buffer extraction from an access unit

    func testExtractsVPSSPSAndPPSFromAnHEVCIDRAccessUnit() {
        let accessUnit = annexB([Self.hevcVPS, Self.hevcSPS, Self.hevcPPS, Self.hevcIDRSlice],
                                shortStartCodes: [1])
        XCTAssertEqual(VideoParameterSets.extract(from: accessUnit, codec: .hevc),
                       annexB([Self.hevcVPS, Self.hevcSPS, Self.hevcPPS]))
    }

    func testHEVCExtractionSkipsSEIAndSlices() {
        let accessUnit = annexB([Self.hevcPrefixSEI, Self.hevcVPS, Self.hevcSPS, Self.hevcPPS,
                                 Self.hevcIDRSlice])
        XCTAssertEqual(VideoParameterSets.extract(from: accessUnit, codec: .hevc),
                       annexB([Self.hevcVPS, Self.hevcSPS, Self.hevcPPS]))
        XCTAssertNil(VideoParameterSets.extract(
            from: annexB([[0x02, 0x01, 0xd0, 0x10]]), codec: .hevc), "a P-frame has none")
    }

    func testEachCodecOnlyRecognizesItsOwnParameterSets() {
        // H.264 SPS 0x27 reads as HEVC type 19 (a slice); HEVC VPS 0x40
        // reads as H.264 type 0. Neither may leak into the wrong config.
        let h264 = annexB([Self.h264SPS, Self.h264PPS, [0x25, 0xb8, 0x00]])
        let hevc = annexB([Self.hevcVPS, Self.hevcSPS, Self.hevcPPS, Self.hevcIDRSlice])
        XCTAssertNil(VideoParameterSets.extract(from: h264, codec: .hevc))
        XCTAssertEqual(VideoParameterSets.extract(from: h264, codec: .h264),
                       annexB([Self.h264SPS, Self.h264PPS]))
        XCTAssertEqual(H264ParameterSets.extract(from: h264),
                       annexB([Self.h264SPS, Self.h264PPS]))
        XCTAssertNotEqual(VideoParameterSets.extract(from: hevc, codec: .h264),
                          annexB([Self.hevcVPS, Self.hevcSPS, Self.hevcPPS]))
    }

    // MARK: Format description → Annex-B (what the encoder prepends to IDRs)

    func testReadsHEVCParameterSetsFromAFormatDescription() throws {
        let sets = [Self.hevcVPS, Self.hevcSPS, Self.hevcPPS]
        var format: CMFormatDescription?
        let status = sets[0].withUnsafeBufferPointer { vps in
            sets[1].withUnsafeBufferPointer { sps in
                sets[2].withUnsafeBufferPointer { pps in
                    let pointers = [vps.baseAddress!, sps.baseAddress!, pps.baseAddress!]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: nil, parameterSetCount: 3,
                        parameterSetPointers: pointers, parameterSetSizes: sets.map(\.count),
                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
                }
            }
        }
        XCTAssertEqual(status, noErr)
        let description = try XCTUnwrap(format)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_HEVC)
        let extracted = VideoEncoder.parameterSets(of: description, codec: .hevc)
        XCTAssertEqual(extracted, sets.map { Data($0) })
        XCTAssertEqual(VideoEncoder.annexB(parameterSets: extracted),
                       annexB([Self.hevcVPS, Self.hevcSPS, Self.hevcPPS]))
        XCTAssertEqual(VideoEncoder.parameterSets(of: description, codec: .h264), [],
                       "an HEVC format has no H.264 parameter sets")
    }

    func testReadsH264ParameterSetsFromAFormatDescription() throws {
        let sets = [Self.h264SPS, Self.h264PPS]
        var format: CMFormatDescription?
        let status = sets[0].withUnsafeBufferPointer { sps in
            sets[1].withUnsafeBufferPointer { pps in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2,
                    parameterSetPointers: [sps.baseAddress!, pps.baseAddress!],
                    parameterSetSizes: sets.map(\.count), nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format)
            }
        }
        XCTAssertEqual(status, noErr)
        let extracted = VideoEncoder.parameterSets(of: try XCTUnwrap(format), codec: .h264)
        XCTAssertEqual(extracted, sets.map { Data($0) })
    }

    func testAnnexBFramingSkipsEmptyParameterSets() {
        XCTAssertEqual(VideoEncoder.annexB(parameterSets: [Data([0x40, 0x01]), Data(),
                                                          Data([0x42])]),
                       Data([0, 0, 0, 1, 0x40, 0x01, 0, 0, 0, 1, 0x42]))
        XCTAssertEqual(VideoEncoder.annexB(parameterSets: []), Data())
    }

    // MARK: ALVR packets

    func testDecoderConfigPayloadCarriesTheCodec() {
        let buffer = annexB([Self.hevcVPS, Self.hevcSPS, Self.hevcPPS])
        let payload = AlvrControlProbe.decoderConfigPayload(parameterSets: buffer, codec: .hevc)
        XCTAssertEqual(payload.prefix(8), Data([1, 0, 0, 0, 1, 0, 0, 0]))
        XCTAssertEqual(payload[8..<16], Data([UInt8(buffer.count), 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(payload.dropFirst(16), buffer)
        let h264 = AlvrControlProbe.decoderConfigPayload(parameterSets: Data([7]), codec: .h264)
        XCTAssertEqual(h264, Data([1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 7]))
    }

    func testStreamConfigNamesTheCodecAsASessionChoice() throws {
        let capabilities = AlvrVideoCapabilities(
            width: 1_680, height: 1_760, refreshRates: [72, 90],
            microphoneSampleRate: 48_000, supportsFoveatedEncoding: true,
            supportsHighProfile: true, supports10Bit: true, supportsAV1: true,
            prefers10Bit: false, prefersFullRange: true,
            preferredEncodingGamma: 1, prefersHDR: false)
        let settings = try AlvrNegotiatedSettings.beatSaberDefaults(for: capabilities)
        for codec in VideoCodec.allCases {
            let payload = try AlvrStreamConfigEncoder.payload(settings: settings, codec: codec)
            let length = Int(payload.prefix(8).enumerated().reduce(UInt64(0)) {
                $0 | (UInt64($1.element) << UInt64($1.offset * 8))
            })
            let session = try XCTUnwrap(JSONSerialization.jsonObject(
                with: payload[8..<(8 + length)]) as? [String: Any])
            let video = try XCTUnwrap(
                (session["session_settings"] as? [String: Any])?["video"] as? [String: Any])
            XCTAssertEqual(video["preferred_codec"] as? [String: String],
                           ["variant": codec.alvrVariantName])
            XCTAssertNotNil(video["max_buffering_frames"], "the codec is merged, not replacing")
        }
    }

    // MARK: Live VideoToolbox HEVC

    func testHEVCEncoderPrependsVPSSPSAndPPSToIDRFrames() throws {
        let lock = NSLock()
        var outputs = [(Data, Bool)]()
        let encoder: VideoEncoder
        do {
            encoder = try VideoEncoder(width: 256, height: 256, fps: 72, bitrate: 4_000_000,
                                       keyframeIntervalSeconds: 60, codec: .hevc) { data, key, _ in
                lock.lock()
                outputs.append((data, key))
                lock.unlock()
            }
        } catch {
            throw XCTSkip("VideoToolbox hardware HEVC is unavailable here: \(error)")
        }
        XCTAssertEqual(encoder.codec, .hevc)
        XCTAssertFalse(encoder.rejectedProperties.contains("ProfileLevel"))
        for index in 0..<4 {
            if index == 2 { encoder.forceKeyframe() }
            var buffer: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            XCTAssertEqual(CVPixelBufferCreate(nil, 256, 256, kCVPixelFormatType_32BGRA,
                                               attributes, &buffer), kCVReturnSuccess)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(30 * index),
                   CVPixelBufferGetDataSize(pixelBuffer))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            XCTAssertTrue(encoder.encode(pixelBuffer,
                                         pts: CMTime(value: Int64(index), timescale: 72)))
            encoder.flush()
        }
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(outputs.count, 4)
        XCTAssertEqual(outputs.map(\.1), [true, false, true, false])
        for (data, isKeyframe) in outputs {
            let types = H264FrameNumParser.nalUnits(data).map {
                VideoCodec.hevc.nalUnitType(headerByte: $0[0])
            }
            if isKeyframe {
                XCTAssertEqual(Array(types.prefix(3)), [32, 33, 34], "VPS, SPS, PPS first")
                XCTAssertTrue(types.dropFirst(3).allSatisfy { $0 == 19 || $0 == 20 },
                              "then IDR slices: \(types)")
                let config = try XCTUnwrap(VideoParameterSets.extract(from: data, codec: .hevc))
                XCTAssertTrue(data.starts(with: config))
            } else {
                XCTAssertTrue(types.allSatisfy { $0 <= 9 }, "P-frames carry only slices: \(types)")
                XCTAssertNil(VideoParameterSets.extract(from: data, codec: .hevc))
            }
        }
    }
}
