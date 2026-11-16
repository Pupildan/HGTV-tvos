// U1Constants.swift
// LF0/u1.<clinit> 里的 x-argus 基准偏移表（W3 / D1）。
// 来源：androguard 解码 LF0/u1.<clinit> 的 fill-array-data-payload + 构造点常量（字节码，权威）。
// 这些是 XArgus.swift 里 md5Variant(W3.a) / sha256Variant(D1.c/d) 两个 TODO 缺失的基准偏移原始值。
//
// ⚠️ 注意：这里只有「原始值」。它们在算法里如何参与（base 选取 / 轮偏移 / 置换索引）
//    需对照字节码 md5Variant / sha256Variant 的实际用法定夺；接入前先对拍，别盲用。
//    详见 XGorgonSerialize.md 与 SIGNING_NOTES.md。

/// LF0/W3：md5Variant 的基准偏移持有类（字段 a:Int=基准, b:[Int]=16 元素置换表）
/// u1.<clinit> 共构造 5 条，按出现顺序：
public enum U1W3 {
    /// (a, permutation[16])
    public static let entries: [(a: Int, perm: [Int])] = [
        (27, [8, 1, 12, 11, 9, 6, 0, 4, 13, 7, 3, 2, 10, 5, 14, 15]),
        (2,  [9, 8, 13, 6, 10, 7, 14, 11, 0, 1, 2, 15, 12, 4, 5, 3]),
        (15, [10, 11, 7, 14, 9, 12, 2, 13, 3, 6, 15, 5, 0, 8, 1, 4]),
        (18, [7, 5, 11, 12, 6, 1, 15, 14, 13, 8, 4, 3, 9, 0, 10, 2]),
        (17, [5, 8, 3, 6, 4, 2, 0, 12, 10, 7, 15, 9, 13, 11, 1, 14]),
    ]
}

/// LF0/D1：sha256Variant 的基准偏移持有类（字段 a:[Int]=8 元素置换, b/c/d:Int=偏移）
/// u1.<clinit> 共构造 6 条，按出现顺序。构造签名 D1([I arr, I b, I c, I d)。
public enum U1D1 {
    /// (perm[8], b, c, d)
    public static let entries: [(perm: [Int], b: Int, c: Int, d: Int)] = [
        ([0, 1, 3, 7, 4, 5, 2, 6], 7, 15, 100),
        ([5, 3, 6, 4, 0, 2, 7, 1], 2, 13, 96),
        ([7, 6, 5, 4, 3, 1, 0, 2], 3, 62, 94),
        ([6, 7, 4, 0, 2, 5, 1, 3], 4, 79, 97),
        ([3, 5, 2, 7, 1, 0, 4, 6], 7, 66, 96),
        ([6, 2, 7, 4, 1, 3, 0, 5], 6, 127, 99),
    ]
}