import Foundation
import NaturalLanguage

/// Turns text into a unit-length vector. Swappable: the on-device Apple model is the default,
/// tests use `HashingEmbedder`, and a stronger model can replace both later.
public protocol Embedder: Sendable {
    var modelID: String { get }
    func embed(_ text: String) -> [Float]?
}

/// Apple's on-device English sentence embedding (512-d). Loads in ~40 ms, no network.
public final class AppleSentenceEmbedder: Embedder, @unchecked Sendable {
    public let modelID = "apple-nl-sentence-en"
    private let model: NLEmbedding
    private let lock = NSLock()

    public init?() {
        guard let model = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        self.model = model
    }

    public func embed(_ text: String) -> [Float]? {
        let trimmed = String(text.prefix(2000))
        lock.lock()
        defer { lock.unlock() }
        guard let vector = model.vector(for: trimmed) else { return nil }
        return VectorMath.normalized(vector.map(Float.init))
    }
}

/// Deterministic bag-of-words embedding for tests: shared words produce similar vectors.
public struct HashingEmbedder: Embedder {
    public let modelID = "hashing-test"
    public let dimension: Int

    public init(dimension: Int = 256) {
        self.dimension = dimension
    }

    public func embed(_ text: String) -> [Float]? {
        var vector = [Float](repeating: 0, count: dimension)
        for token in FTSQuery.tokens(in: text) {
            var hash: UInt64 = 1469598103934665603
            for byte in token.utf8 {
                hash = (hash ^ UInt64(byte)) &* 1099511628211
            }
            vector[Int(hash % UInt64(dimension))] += 1
        }
        guard vector.contains(where: { $0 != 0 }) else { return nil }
        return VectorMath.normalized(vector)
    }
}

public enum VectorMath {
    public static func normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// Dot product; callers store unit vectors so this is cosine similarity.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for i in 0..<a.count { sum += a[i] * b[i] }
        return sum
    }

    public static func encode(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }
}
