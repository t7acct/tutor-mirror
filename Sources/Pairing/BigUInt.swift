import Foundation

/// Just enough unsigned big-number arithmetic for SRP-6a (on-screen code
/// pairing, see `PinPairing`): bytes in and out, comparison, and modular
/// power, product and sum on a fixed odd modulus. Not constant-time; the
/// secrets it handles live for one pairing attempt.
struct BigUInt: Comparable {
    /// Little-endian 32-bit limbs, with no zero limbs at the top.
    private(set) var limbs: [UInt32]

    init(limbs: [UInt32]) {
        self.limbs = limbs
        while let last = self.limbs.last, last == 0 { self.limbs.removeLast() }
    }

    init(_ value: UInt32) { self.init(limbs: [value]) }

    /// From big-endian bytes.
    init<D: DataProtocol>(bytes: D) {
        var out: [UInt32] = []
        var word: UInt32 = 0, shift: UInt32 = 0
        for byte in [UInt8](bytes).reversed() {
            word |= UInt32(byte) << shift
            shift += 8
            if shift == 32 { out.append(word); word = 0; shift = 0 }
        }
        if shift > 0 { out.append(word) }
        self.init(limbs: out)
    }

    var isZero: Bool { limbs.isEmpty }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    func bit(_ i: Int) -> Bool {
        let word = i / 32
        return word < limbs.count && (limbs[word] >> UInt32(i % 32)) & 1 == 1
    }

    /// Big-endian bytes: the shortest form (no leading zero bytes), or
    /// left-padded with zeros to `length`.
    func bytes(length: Int? = nil) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(limbs.count * 4)
        for limb in limbs.reversed() {
            out += [UInt8(limb >> 24), UInt8(truncatingIfNeeded: limb >> 16),
                    UInt8(truncatingIfNeeded: limb >> 8), UInt8(truncatingIfNeeded: limb)]
        }
        out.removeFirst(out.firstIndex { $0 != 0 } ?? out.count)
        if let length, out.count < length {
            out = [UInt8](repeating: 0, count: length - out.count) + out
        }
        return Data(out)
    }

    static func < (a: BigUInt, b: BigUInt) -> Bool {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
        for i in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[i] != b.limbs[i] {
            return a.limbs[i] < b.limbs[i]
        }
        return false
    }
}

/// Arithmetic modulo a fixed odd number, using Montgomery multiplication
/// (CIOS), so no long division is needed. Every operand must already be
/// below the modulus.
struct MontgomeryModulus {
    let modulus: BigUInt
    private let n: [UInt32]
    private let size: Int
    /// −n⁻¹ mod 2³².
    private let n0inv: UInt32
    /// R² mod n, with R = 2^(32·size).
    private let r2: [UInt32]
    private let one: [UInt32]

    init(_ modulus: BigUInt) {
        precondition(modulus.bitWidth > 1 && modulus.bit(0), "the modulus must be odd and above 1")
        self.modulus = modulus
        n = modulus.limbs
        size = n.count
        var inverse: UInt32 = 1                 // n[0]⁻¹ mod 2³² by Newton's method:
        for _ in 0..<5 { inverse = inverse &* (2 &- n[0] &* inverse) }   // 5 steps double 1 → 32 good bits
        n0inv = 0 &- inverse
        var x = [UInt32](repeating: 0, count: size)
        x[0] = 1
        for _ in 0..<(64 * size) { x = Self.doubled(x, n) }
        r2 = x
        var o = [UInt32](repeating: 0, count: size)
        o[0] = 1
        one = o
    }

    /// base^exponent mod n.
    func power(_ base: BigUInt, _ exponent: BigUInt) -> BigUInt {
        let b = montMul(padded(base), r2)
        var x = montMul(one, r2)
        for i in stride(from: exponent.bitWidth - 1, through: 0, by: -1) {
            x = montMul(x, x)
            if exponent.bit(i) { x = montMul(x, b) }
        }
        return BigUInt(limbs: montMul(x, one))
    }

    /// a·b mod n.
    func product(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        BigUInt(limbs: montMul(montMul(padded(a), padded(b)), r2))
    }

    /// a + b mod n.
    func sum(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        var out = padded(a)
        let y = padded(b)
        var carry: UInt64 = 0
        for i in 0..<size {
            let v = UInt64(out[i]) + UInt64(y[i]) + carry
            out[i] = UInt32(truncatingIfNeeded: v)
            carry = v >> 32
        }
        if carry != 0 || !Self.less(out, n) { Self.subtract(&out, n) }
        return BigUInt(limbs: out)
    }

    private func padded(_ v: BigUInt) -> [UInt32] {
        precondition(v < modulus, "operand must be below the modulus")
        return v.limbs + [UInt32](repeating: 0, count: size - v.limbs.count)
    }

    /// a·b·R⁻¹ mod n (Koç's CIOS).
    private func montMul(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        let s = size
        var t = [UInt32](repeating: 0, count: s + 2)
        for i in 0..<s {
            let bi = UInt64(b[i])
            var c: UInt64 = 0
            for j in 0..<s {
                let v = UInt64(t[j]) &+ UInt64(a[j]) &* bi &+ c
                t[j] = UInt32(truncatingIfNeeded: v)
                c = v >> 32
            }
            var v = UInt64(t[s]) &+ c
            t[s] = UInt32(truncatingIfNeeded: v)
            t[s + 1] = UInt32(truncatingIfNeeded: v >> 32)

            let m = UInt64(t[0] &* n0inv)
            v = UInt64(t[0]) &+ m &* UInt64(n[0])
            c = v >> 32
            for j in 1..<s {
                v = UInt64(t[j]) &+ m &* UInt64(n[j]) &+ c
                t[j - 1] = UInt32(truncatingIfNeeded: v)
                c = v >> 32
            }
            v = UInt64(t[s]) &+ c
            t[s - 1] = UInt32(truncatingIfNeeded: v)
            t[s] = t[s + 1] &+ UInt32(truncatingIfNeeded: v >> 32)
        }
        var out = Array(t[0..<s])
        if t[s] != 0 || !Self.less(out, n) { Self.subtract(&out, n) }
        return out
    }

    /// 2x mod n, for x below n.
    private static func doubled(_ x: [UInt32], _ n: [UInt32]) -> [UInt32] {
        var out = x
        var carry: UInt32 = 0
        for i in 0..<out.count {
            let v = out[i]
            out[i] = (v << 1) | carry
            carry = v >> 31
        }
        if carry == 1 || !less(out, n) { subtract(&out, n) }
        return out
    }

    /// a < b, for limb arrays of the same length.
    private static func less(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] {
            return a[i] < b[i]
        }
        return false
    }

    /// a −= b for limb arrays of the same length, dropping the final borrow
    /// (callers only subtract when the true result fits).
    private static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for i in 0..<a.count {
            let d = UInt64(a[i]) &- UInt64(b[i]) &- borrow
            a[i] = UInt32(truncatingIfNeeded: d)
            borrow = d >> 63
        }
    }
}
