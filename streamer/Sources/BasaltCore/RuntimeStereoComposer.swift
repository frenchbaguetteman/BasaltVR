import CoreVideo
import Foundation
import Metal

/// Composes the OpenXR runtime's two per-eye images into ALVR's side-by-side
/// stereo layout. Unlike `StereoFrameComposer` (which centers a duplicated
/// desktop using IPD/FOV calibration), each game image already bakes its
/// eye's projection, so each one simply fills its half of the output.
public final class RuntimeStereoComposer: @unchecked Sendable {
    /// Keeps a preallocated compositor output unavailable until its downstream
    /// consumer (VideoToolbox in production) has finished with it.
    public final class ComposedFrame: @unchecked Sendable {
        fileprivate let output: Output
        private weak var composer: RuntimeStereoComposer?

        public var pixelBuffer: CVPixelBuffer { output.pixelBuffer }

        fileprivate init(output: Output, composer: RuntimeStereoComposer) {
            self.output = output
            self.composer = composer
        }

        deinit { composer?.recycle(output) }
    }

    /// A preallocated output and its Metal view, both made once at init.
    fileprivate struct Output {
        let pixelBuffer: CVPixelBuffer
        /// Keeps `texture` valid; the texture cache does not retain it.
        let cvTexture: CVMetalTexture
        let texture: MTLTexture
    }

    public static let maximumFramesInFlight = 2

    public let perEyeWidth: Int
    public let height: Int
    public var outputWidth: Int { perEyeWidth * 2 }

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let completionQueue = DispatchQueue(
        label: "basalt.runtime-stereo-composer.completions")
    private let outputLock = NSLock()
    /// Preallocated outputs not currently in composition or downstream use.
    private var availableOutputs: [Output] = []

    public init(perEyeWidth: Int, height: Int) throws {
        guard perEyeWidth > 0, height > 0 else {
            throw BasaltError("Invalid stereo output dimensions")
        }
        self.perEyeWidth = perEyeWidth
        self.height = height
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw BasaltError("Metal is unavailable for runtime stereo composition")
        }
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void composeOpaqueStereo(
            texture2d<float, access::sample> left [[texture(0)]],
            texture2d<float, access::sample> right [[texture(1)]],
            texture2d<float, access::write> output [[texture(2)]],
            uint2 position [[thread_position_in_grid]])
        {
            if (position.x >= output.get_width() ||
                position.y >= output.get_height()) {
                return;
            }
            constexpr sampler linearSampler(
                coord::normalized, address::clamp_to_edge, filter::linear);
            const uint eyeWidth = output.get_width() / 2;
            const bool rightEye = position.x >= eyeWidth;
            const uint localX = rightEye ? position.x - eyeWidth : position.x;
            const float2 uv = float2(
                (float(localX) + 0.5f) / float(eyeWidth),
                (float(position.y) + 0.5f) / float(output.get_height()));
            const float3 rgb = rightEye
                ? right.sample(linearSampler, uv).rgb
                : left.sample(linearSampler, uv).rgb;
            output.write(float4(rgb, 1.0f), position);
        }
        """
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw BasaltError("Could not compile runtime stereo compositor: \(error)")
        }
        guard let function = library.makeFunction(name: "composeOpaqueStereo") else {
            throw BasaltError("Runtime stereo compositor function is missing")
        }
        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw BasaltError("Could not create runtime stereo compositor: \(error)")
        }
        self.commandQueue = commandQueue

        var maybeTextureCache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            nil, nil, device, nil, &maybeTextureCache)
        guard cacheStatus == kCVReturnSuccess, let textureCache = maybeTextureCache else {
            throw BasaltError("CVMetalTextureCacheCreate failed (\(cacheStatus))")
        }
        self.textureCache = textureCache

        // The fixed outputs below are the reuse mechanism, so they are
        // created directly rather than drawn from a pixel-buffer pool.
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        for _ in 0..<Self.maximumFramesInFlight {
            var maybeOutput: CVPixelBuffer?
            let outputStatus = CVPixelBufferCreate(
                nil, perEyeWidth * 2, height, kCVPixelFormatType_32BGRA,
                attributes as CFDictionary, &maybeOutput)
            guard outputStatus == kCVReturnSuccess, let output = maybeOutput else {
                throw BasaltError(
                    "Could not preallocate stereo compositor output (\(outputStatus))")
            }
            guard let (cvTexture, texture) = Self.metalTexture(for: output, in: textureCache) else {
                throw BasaltError("Could not create a Metal view of the compositor output")
            }
            availableOutputs.append(
                Output(pixelBuffer: output, cvTexture: cvTexture, texture: texture))
        }
    }

    private static func metalTexture(
        for buffer: CVPixelBuffer, in cache: CVMetalTextureCache
    ) -> (CVMetalTexture, MTLTexture)? {
        var maybeTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer),
            0, &maybeTexture)
        guard status == kCVReturnSuccess,
              let cvTexture = maybeTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        return (cvTexture, texture)
    }

    /// Scales each eye to fill its half without blocking the runtime-link
    /// receive queue. At most two output surfaces can be in composition or
    /// downstream encoding at once; callers drop a new frame when this method
    /// returns false instead of extending latency.
    ///
    /// `completion` runs in command-buffer order after Metal has finished
    /// reading both source IOSurfaces. Retain the returned `ComposedFrame`
    /// until the encoder callback fires so its preallocated output slot cannot
    /// be overwritten while VideoToolbox is still consuming it.
    @discardableResult
    public func composeAsync(
        left: CVPixelBuffer,
        right: CVPixelBuffer,
        completion: @escaping @Sendable (ComposedFrame?) -> Void
    ) -> Bool {
        guard let output = reserveOutput() else { return false }
        guard let leftTexture = Self.metalTexture(for: left, in: textureCache),
              let rightTexture = Self.metalTexture(for: right, in: textureCache),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            recycle(output)
            return false
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(leftTexture.1, index: 0)
        encoder.setTexture(rightTexture.1, index: 1)
        encoder.setTexture(output.texture, index: 2)
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(
            1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        encoder.dispatchThreads(
            MTLSize(width: outputWidth, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: threadWidth, height: threadHeight, depth: 1))
        encoder.endEncoding()
        // CVMetalTextureCacheCreateTextureFromImage requires callers to keep
        // each CVMetalTexture alive until the GPU finishes with it; the system
        // does not retain it. Hold the source wrappers and buffers until then;
        // the reserved output stays alive through `output`.
        let gpuResources = (left, right, leftTexture.0, rightTexture.0)
        commandBuffer.addCompletedHandler { [weak self] buffer in
            withExtendedLifetime(gpuResources) {}
            guard let self else {
                completion(nil)
                return
            }
            self.completionQueue.async {
                guard buffer.status == .completed else {
                    self.recycle(output)
                    completion(nil)
                    return
                }
                completion(ComposedFrame(output: output, composer: self))
            }
        }
        commandBuffer.commit()
        return true
    }

    private func reserveOutput() -> Output? {
        outputLock.lock()
        defer { outputLock.unlock() }
        return availableOutputs.popLast()
    }

    fileprivate func recycle(_ output: Output) {
        outputLock.lock()
        availableOutputs.append(output)
        outputLock.unlock()
    }
}
