// Copyright (c) 2023-2024 Tom Sutcliffe
// See LICENSE file for license information.

/// Placeholder type used by ``Lua/Swift/UnsafeMutablePointer/toany(_:guessType:)`` when `guessType` is `false`.
public struct LuaStringRef {
    let L: LuaState
    let index: CInt

    public init(L: LuaState, index: CInt) {
        self.L = L
        self.index = L.absindex(index)
    }

    public func ref() -> LuaValue {
        L.push(index: index)
        return L.popref()
    }

    public func toString() -> String? {
        return L.tostring(index)
    }

    public func toData() -> [UInt8] {
        return L.todata(index)! // Definitely won't error (assuming index still valid) as type has already been checked
    }

    public func guessType() -> AnyHashable {
        if let str = toString() {
            return str
        } else {
            return toData()
        }
    }
}
