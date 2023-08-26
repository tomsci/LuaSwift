// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

import Foundation

public struct LuaStringRef {
    let L: LuaState!
    let index: CInt

    public init(L: LuaState!, index: CInt) {
        self.L = L
        self.index = L.absindex(index)
    }

    public func toString(encoding: ExtendedStringEncoding? = nil) -> String? {
        return L.tostring(index, encoding: encoding)
    }

    public func toData() -> Data {
        return L.todata(index)! // Definitely won't error (assuming index still valid) as type has already been checked
    }

    public func guessType() -> AnyHashable {
        if let str = L.tostring(index, convert: false) {
            // This will fail if the string isn't valid in the default encoding
            return str
        } else {
            return L.todata(index)!
        }
    }
}
