import Foundation

/// Minimal HEVC bitstream reader for tests: reads each picture's
/// `PicOrderCntVal` and the short-term reference pictures its slices use
/// (`RefPicSetStCurrBefore/After`, H.265 §7.3.7, §8.3.1–8.3.2).
///
/// HEVC has no `frame_num`. Its equivalent of an H.264 `frame_num` gap is a
/// P-frame whose reference picture set names a picture that the decoder
/// never received ("Could not find ref with POC"): the picture is decoded
/// against a missing reference and is corrupt until the next IDR.
struct HEVCReferenceParser {
    struct Picture: Equatable {
        let nalType: Int
        let pictureOrderCount: Int
        /// POCs of the pictures this one predicts from.
        let referencePOCs: [Int]

        var isIDR: Bool { nalType == 19 || nalType == 20 }
        var isIRAP: Bool { (16...23).contains(nalType) }
    }

    private struct ShortTermRPS {
        var negative: [(delta: Int, used: Bool)] = []
        var positive: [(delta: Int, used: Bool)] = []
    }

    private(set) var longTermReferencesPresent = false
    private var log2MaxPOCLsb: Int?
    private var separateColourPlane = false
    private var shortTermSets = [ShortTermRPS]()
    private var dependentSliceSegmentsEnabled = false
    private var outputFlagPresent = false
    private var extraSliceHeaderBits = 0
    private var previousTid0POC = 0

    /// Reads any SPS and PPS in the access unit, then returns the picture of
    /// its first slice segment.
    mutating func parse(accessUnit: Data) -> Picture? {
        var picture: Picture?
        for nal in H264FrameNumParser.nalUnits(accessUnit) where nal.count > 2 {
            let type = Int(nal[0] >> 1) & 0x3F
            let temporalID = Int(nal[1] & 0x07) - 1
            var reader = H264FrameNumParser.BitReader(Array(nal.dropFirst(2)))
            switch type {
            case 33: readSPS(&reader)
            case 34: readPPS(&reader)
            case 0...21 where picture == nil:
                picture = readSlice(&reader, nalType: type, temporalID: temporalID)
            default: break
            }
        }
        return picture
    }

    /// Indices of pictures that predict from a picture the decoder does not
    /// have: one not received since the last IDR.
    static func missingReferences(_ pictures: [Picture]) -> [Int] {
        var decoded = Set<Int>()
        var missing = [Int]()
        for (index, picture) in pictures.enumerated() {
            if picture.isIDR { decoded.removeAll() }
            if !picture.referencePOCs.allSatisfy(decoded.contains) { missing.append(index) }
            decoded.insert(picture.pictureOrderCount)
        }
        return missing
    }

    private mutating func readSlice(_ r: inout H264FrameNumParser.BitReader, nalType: Int,
                                    temporalID: Int) -> Picture? {
        guard let log2MaxPOCLsb else { return nil }
        guard r.u(1) == 1 else { return nil } // first_slice_segment_in_pic_flag
        if (16...23).contains(nalType) { _ = r.u(1) } // no_output_of_prior_pics_flag
        _ = r.ue() // slice_pic_parameter_set_id
        _ = r.u(extraSliceHeaderBits) // slice_reserved_flag[]
        _ = r.ue() // slice_type
        if outputFlagPresent { _ = r.u(1) }
        if separateColourPlane { _ = r.u(2) }

        let isIDR = nalType == 19 || nalType == 20
        var pictureOrderCount = 0
        var references = [Int]()
        if !isIDR {
            let lsb = r.u(log2MaxPOCLsb)
            let rps: ShortTermRPS
            if r.u(1) == 0 { // short_term_ref_pic_set_sps_flag
                rps = readShortTermRPS(&r, index: shortTermSets.count)
            } else {
                let count = shortTermSets.count
                let bits = count > 1 ? Int(ceil(log2(Double(count)))) : 0
                rps = shortTermSets[r.u(bits)]
            }
            // §8.3.1: POC MSB follows the previous TemporalId-0 picture.
            let maxLsb = 1 << log2MaxPOCLsb
            let previousLsb = previousTid0POC & (maxLsb - 1)
            var msb = previousTid0POC - previousLsb
            if lsb < previousLsb && previousLsb - lsb >= maxLsb / 2 {
                msb += maxLsb
            } else if lsb > previousLsb && lsb - previousLsb > maxLsb / 2 {
                msb -= maxLsb
            }
            pictureOrderCount = msb + lsb
            references = (rps.negative + rps.positive).filter(\.used)
                .map { pictureOrderCount + $0.delta }
        }
        // RASL, RADL, and sub-layer non-reference pictures do not anchor POC.
        let subLayerNonReference = nalType <= 14 && nalType % 2 == 0
        if temporalID == 0 && !(6...9).contains(nalType) && !subLayerNonReference {
            previousTid0POC = pictureOrderCount
        }
        return Picture(nalType: nalType, pictureOrderCount: pictureOrderCount,
                       referencePOCs: references)
    }

    /// `st_ref_pic_set(index)` (§7.3.7), with inter-RPS prediction (§7.4.8).
    private func readShortTermRPS(_ r: inout H264FrameNumParser.BitReader,
                                  index: Int) -> ShortTermRPS {
        if index != 0 && r.u(1) == 1 { // inter_ref_pic_set_prediction_flag
            let deltaIndex = index == shortTermSets.count ? r.ue() + 1 : 1
            let sign = r.u(1)
            let deltaRPS = (1 - 2 * sign) * (r.ue() + 1)
            let reference = shortTermSets[index - deltaIndex]
            let referenceCount = reference.negative.count + reference.positive.count
            var used = [Bool]()
            var useDelta = [Bool]()
            for _ in 0...referenceCount {
                let isUsed = r.u(1) == 1
                used.append(isUsed)
                useDelta.append(isUsed ? true : r.u(1) == 1)
            }
            let negativeCount = reference.negative.count
            var result = ShortTermRPS()
            for j in stride(from: reference.positive.count - 1, through: 0, by: -1) {
                let delta = reference.positive[j].delta + deltaRPS
                if delta < 0 && useDelta[negativeCount + j] {
                    result.negative.append((delta, used[negativeCount + j]))
                }
            }
            if deltaRPS < 0 && useDelta[referenceCount] {
                result.negative.append((deltaRPS, used[referenceCount]))
            }
            for j in 0..<negativeCount {
                let delta = reference.negative[j].delta + deltaRPS
                if delta < 0 && useDelta[j] { result.negative.append((delta, used[j])) }
            }
            for j in stride(from: negativeCount - 1, through: 0, by: -1) {
                let delta = reference.negative[j].delta + deltaRPS
                if delta > 0 && useDelta[j] { result.positive.append((delta, used[j])) }
            }
            if deltaRPS > 0 && useDelta[referenceCount] {
                result.positive.append((deltaRPS, used[referenceCount]))
            }
            for j in 0..<reference.positive.count {
                let delta = reference.positive[j].delta + deltaRPS
                if delta > 0 && useDelta[negativeCount + j] {
                    result.positive.append((delta, used[negativeCount + j]))
                }
            }
            return result
        }
        var result = ShortTermRPS()
        let negativeCount = r.ue()
        let positiveCount = r.ue()
        var poc = 0
        for _ in 0..<negativeCount {
            poc -= r.ue() + 1
            result.negative.append((poc, r.u(1) == 1))
        }
        poc = 0
        for _ in 0..<positiveCount {
            poc += r.ue() + 1
            result.positive.append((poc, r.u(1) == 1))
        }
        return result
    }

    private mutating func readSPS(_ r: inout H264FrameNumParser.BitReader) {
        _ = r.u(4) // sps_video_parameter_set_id
        let maxSubLayersMinus1 = r.u(3)
        _ = r.u(1) // sps_temporal_id_nesting_flag
        // profile_tier_level(1, maxSubLayersMinus1)
        _ = r.u(44); _ = r.u(44) // general profile fields (88 bits)
        _ = r.u(8) // general_level_idc
        var profilePresent = [Bool]()
        var levelPresent = [Bool]()
        for _ in 0..<maxSubLayersMinus1 {
            profilePresent.append(r.u(1) == 1)
            levelPresent.append(r.u(1) == 1)
        }
        if maxSubLayersMinus1 > 0 {
            for _ in maxSubLayersMinus1..<8 { _ = r.u(2) }
        }
        for layer in 0..<maxSubLayersMinus1 {
            if profilePresent[layer] { _ = r.u(44); _ = r.u(44) }
            if levelPresent[layer] { _ = r.u(8) }
        }
        _ = r.ue() // sps_seq_parameter_set_id
        let chroma = r.ue()
        separateColourPlane = chroma == 3 && r.u(1) == 1
        _ = r.ue() // pic_width_in_luma_samples
        _ = r.ue() // pic_height_in_luma_samples
        if r.u(1) == 1 { for _ in 0..<4 { _ = r.ue() } } // conformance window
        _ = r.ue() // bit_depth_luma_minus8
        _ = r.ue() // bit_depth_chroma_minus8
        let log2MaxPOCLsb = r.ue() + 4
        let orderingInfoForAll = r.u(1) == 1
        for _ in (orderingInfoForAll ? 0 : maxSubLayersMinus1)...maxSubLayersMinus1 {
            _ = r.ue(); _ = r.ue(); _ = r.ue()
        }
        for _ in 0..<6 { _ = r.ue() } // block sizes and transform depths
        if r.u(1) == 1, r.u(1) == 1 { // scaling_list_enabled, sps_scaling_list_data_present
            for sizeID in 0..<4 {
                for _ in stride(from: 0, to: 6, by: sizeID == 3 ? 3 : 1) {
                    if r.u(1) == 0 { // scaling_list_pred_mode_flag
                        _ = r.ue()
                    } else {
                        if sizeID > 1 { _ = r.se() }
                        for _ in 0..<min(64, 1 << (4 + (sizeID << 1))) { _ = r.se() }
                    }
                }
            }
        }
        _ = r.u(1) // amp_enabled_flag
        _ = r.u(1) // sample_adaptive_offset_enabled_flag
        if r.u(1) == 1 { // pcm_enabled_flag
            _ = r.u(8); _ = r.ue(); _ = r.ue(); _ = r.u(1)
        }
        shortTermSets = []
        let setCount = r.ue()
        for index in 0..<setCount {
            shortTermSets.append(readShortTermRPS(&r, index: index))
        }
        longTermReferencesPresent = r.u(1) == 1
        self.log2MaxPOCLsb = log2MaxPOCLsb
    }

    private mutating func readPPS(_ r: inout H264FrameNumParser.BitReader) {
        _ = r.ue() // pps_pic_parameter_set_id
        _ = r.ue() // pps_seq_parameter_set_id
        dependentSliceSegmentsEnabled = r.u(1) == 1
        outputFlagPresent = r.u(1) == 1
        extraSliceHeaderBits = r.u(3)
    }
}
