// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

import CLua

/// Protocol adopted by all fundamental Swift types that can unambiguously be converted to basic Lua types.
public protocol Pushable {
    /// Push this Swift value onto the stack, as a Lua type.
    func push(state L: LuaState)
}

extension Bool: Pushable {
    public func push(state L: LuaState) {
        lua_pushboolean(L, self ? 1 : 0)
    }
}

extension Int: Pushable {
    public func push(state L: LuaState) {
        lua_pushinteger(L, lua_Integer(self))
    }
}

extension CInt: Pushable {
    public func push(state L: LuaState) {
        lua_pushinteger(L, lua_Integer(self))
    }
}

extension Int64: Pushable {
    public func push(state L: LuaState) {
        lua_pushinteger(L, self)
    }
}

extension UInt64: Pushable {
    public func push(state L: LuaState) {
        if self < 0x8000000000000000 {
            lua_pushinteger(L, lua_Integer(self))
        } else {
            lua_pushnumber(L, Double(self))
        }
    }
}

extension Double: Pushable {
    public func push(state L: LuaState) {
        lua_pushnumber(L, self)
    }
}

extension String: Pushable {
    public func push(state L: LuaState) {
        L.push(string: self)
    }
}

extension Array: Pushable where Element: Pushable {
    public func push(state L: LuaState) {
        lua_createtable(L, CInt(self.count), 0)
        for (i, val) in self.enumerated() {
            val.push(state: L)
            lua_rawseti(L, -2, lua_Integer(i + 1))
        }
    }
}

extension Dictionary: Pushable where Key: Pushable, Value: Pushable {
    public func push(state L: LuaState) {
        lua_createtable(L, 0, CInt(self.count))
        for (k, v) in self {
            L.push(k)
            L.push(v)
            lua_settable(L, -3)
        }
    }
}
