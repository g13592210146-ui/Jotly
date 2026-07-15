import Foundation

extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

extension UInt32 {
    var bigEndianData: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}

extension Int32 {
    var bigEndianData: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: MemoryLayout<Int32>.size)
    }
}

extension Data {
    func readUInt32BigEndian(at offset: Int) -> UInt32 {
        let range = offset..<(offset + 4)
        var value: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { targetBuffer in
            copyBytes(to: targetBuffer, from: range)
        }
        return UInt32(bigEndian: value)
    }

    func readInt32BigEndian(at offset: Int) -> Int32 {
        let range = offset..<(offset + 4)
        var value: Int32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { targetBuffer in
            copyBytes(to: targetBuffer, from: range)
        }
        return Int32(bigEndian: value)
    }
}
