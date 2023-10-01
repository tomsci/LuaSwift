// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

@testable import Lua
import CLua

extension LuaValue {
    public func internal_get_L() -> LuaState? {
        return L
    }
}
