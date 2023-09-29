// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

@testable import Lua
import CLua

extension LuaValue {
    public func internal_get_L() -> LuaState? {
        return L
    }
}

extension UnsafeMutablePointer where Pointee == lua_State {
    public struct internal_MoreGarbage {
        static let count = MoreGarbage.count
        static let countb = MoreGarbage.countb
        static let isrunning = MoreGarbage.isrunning
    }
}
