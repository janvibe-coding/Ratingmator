import Foundation

nonisolated enum Flag: Int, Sendable {
    case reject = -1
    case none = 0
    case pick = 1
}

/// The stars and flag found in one source. nil means the field isn't there at all;
/// an explicit 0 is a value (SPEC 5.2).
nonisolated struct PhotoValue: Equatable, Sendable {
    var stars: Int?
    var flag: Flag?

    static let empty = PhotoValue(stars: nil, flag: nil)
}
