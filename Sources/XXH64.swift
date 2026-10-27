// xxHash64: o checksum que o mercado usa para conferir cópias (e o que o ASC MHL registra).
// Bem mais rápido que SHA-256 e igualmente confiável para detectar arquivo corrompido.
// Implementação do algoritmo de referência (github.com/Cyan4973/xxHash), em modo contínuo.

struct XXH64 {
    private static let p1: UInt64 = 11400714785074694791
    private static let p2: UInt64 = 14029467366897019727
    private static let p3: UInt64 = 1609587929392839161
    private static let p4: UInt64 = 9650029242287828579
    private static let p5: UInt64 = 2870177450012600261

    private let seed: UInt64
    private var v1: UInt64, v2: UInt64, v3: UInt64, v4: UInt64
    private var total: UInt64 = 0
    private var mem = [UInt8](repeating: 0, count: 32)
    private var memSize = 0

    init(seed: UInt64 = 0) {
        self.seed = seed
        v1 = seed &+ Self.p1 &+ Self.p2
        v2 = seed &+ Self.p2
        v3 = seed
        v4 = seed &- Self.p1
    }

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 { (x << r) | (x >> (64 - r)) }
    @inline(__always) private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotl(acc &+ input &* p2, 31) &* p1
    }
    @inline(__always) private static func merge(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        (acc ^ round(0, val)) &* p1 &+ p4
    }

    mutating func update(_ buf: UnsafeRawBufferPointer) {
        guard let base = buf.baseAddress, buf.count > 0 else { return }
        let len = buf.count
        total &+= UInt64(len)
        var p = 0
        if memSize + len < 32 {
            mem.withUnsafeMutableBytes { $0.baseAddress!.advanced(by: memSize).copyMemory(from: base, byteCount: len) }
            memSize += len
            return
        }
        if memSize > 0 {
            let fill = 32 - memSize
            mem.withUnsafeMutableBytes { m in
                m.baseAddress!.advanced(by: memSize).copyMemory(from: base, byteCount: fill)
                let b = UnsafeRawPointer(m.baseAddress!)
                v1 = Self.round(v1, b.loadUnaligned(fromByteOffset: 0, as: UInt64.self).littleEndian)
                v2 = Self.round(v2, b.loadUnaligned(fromByteOffset: 8, as: UInt64.self).littleEndian)
                v3 = Self.round(v3, b.loadUnaligned(fromByteOffset: 16, as: UInt64.self).littleEndian)
                v4 = Self.round(v4, b.loadUnaligned(fromByteOffset: 24, as: UInt64.self).littleEndian)
            }
            p = fill
            memSize = 0
        }
        var a = v1, b = v2, c = v3, d = v4
        while p + 32 <= len {
            a = Self.round(a, base.loadUnaligned(fromByteOffset: p, as: UInt64.self).littleEndian)
            b = Self.round(b, base.loadUnaligned(fromByteOffset: p + 8, as: UInt64.self).littleEndian)
            c = Self.round(c, base.loadUnaligned(fromByteOffset: p + 16, as: UInt64.self).littleEndian)
            d = Self.round(d, base.loadUnaligned(fromByteOffset: p + 24, as: UInt64.self).littleEndian)
            p += 32
        }
        v1 = a; v2 = b; v3 = c; v4 = d
        if p < len {
            let rest = len - p
            mem.withUnsafeMutableBytes { $0.baseAddress!.copyMemory(from: base.advanced(by: p), byteCount: rest) }
            memSize = rest
        }
    }

    func digest() -> UInt64 {
        var h: UInt64
        if total >= 32 {
            h = Self.rotl(v1, 1) &+ Self.rotl(v2, 7) &+ Self.rotl(v3, 12) &+ Self.rotl(v4, 18)
            h = Self.merge(h, v1); h = Self.merge(h, v2); h = Self.merge(h, v3); h = Self.merge(h, v4)
        } else {
            h = seed &+ Self.p5
        }
        h &+= total
        mem.withUnsafeBytes { m in
            let b = m.baseAddress!
            var i = 0
            while i + 8 <= memSize {
                h ^= Self.round(0, b.loadUnaligned(fromByteOffset: i, as: UInt64.self).littleEndian)
                h = Self.rotl(h, 27) &* Self.p1 &+ Self.p4
                i += 8
            }
            if i + 4 <= memSize {
                h ^= UInt64(b.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian) &* Self.p1
                h = Self.rotl(h, 23) &* Self.p2 &+ Self.p3
                i += 4
            }
            while i < memSize {
                h ^= UInt64(m[i]) &* Self.p5
                h = Self.rotl(h, 11) &* Self.p1
                i += 1
            }
        }
        h ^= h >> 33; h = h &* Self.p2
        h ^= h >> 29; h = h &* Self.p3
        h ^= h >> 32
        return h
    }

    /// Forma usada nos relatórios e no ASC MHL: 16 dígitos hexadecimais, minúsculos.
    static func hex(_ v: UInt64) -> String {
        let s = String(v, radix: 16)
        return String(repeating: "0", count: 16 - s.count) + s
    }
}
