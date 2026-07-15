import AVFoundation
import Foundation

extension AVAudioPCMBuffer {
    func copyBuffer() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        copy.frameLength = frameLength
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                dst[channel].initialize(from: src[channel], count: Int(frameLength))
            }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for channel in 0..<Int(format.channelCount) {
                dst[channel].initialize(from: src[channel], count: Int(frameLength))
            }
        } else if let src = int32ChannelData, let dst = copy.int32ChannelData {
            for channel in 0..<Int(format.channelCount) {
                dst[channel].initialize(from: src[channel], count: Int(frameLength))
            }
        }
        return copy
    }
}
