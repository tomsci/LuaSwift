// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

import CLua

public protocol Pushable {
    /// Push this Swift value onto the stack, as a Lua type.
    func push(onto state: LuaState)
}

extension Bool: Pushable {
    public func push(onto L: LuaState) {
        lua_pushboolean(L, self ? 1 : 0)
    }
}

// Is there a cleaner way to make all integers Pushable with extensions and where clauses?

extension Int: Pushable {
    public func push(onto L: LuaState) {
        lua_pushinteger(L, lua_Integer(self))
    }
}

extension Int8: Pushable {
    public func push(onto L: LuaState) {
        lua_pushinteger(L, lua_Integer(self))
    }
}

extension Int16: Pushable {
    public func push(onto L: LuaState) {
        lua_pushinteger(L, lua_Integer(self))
    }
}

extension Int32: Pushable {
    public func push(onto L: LuaState) {
        lua_pushinteger(L, lua_Integer(self))
    }
}

extension Int64: Pushable {
    public func push(onto L: LuaState) {
        lua_pushinteger(L, self)
    }
}

extension UInt16: Pushable {
    public func push(onto L: LuaState) {
        lua_pushinteger(L, lua_Integer(self))
    }
}

extension UInt32: Pushable {
    public func push(onto L: LuaState) {
        lua_pushinteger(L, lua_Integer(self))
    }
}

// Note, UInt8 and UInt64 are NOT Pushable because they cannot be represented unambiguously; UInt8 because [UInt8]
// should not push as an array of numbers, and UInt64 because lua_Integer is a signed 64 bit value so UInt64 isn't
// guaranteed to fit.

extension lua_Number: Pushable {
    public func push(onto L: LuaState) {
        lua_pushnumber(L, self)
    }
}

extension String: Pushable {
    /// Push the string onto the Lua stack using the default string encoding.
    public func push(onto L: LuaState) {
        L.push(string: self)
    }
}

extension Array: Pushable where Element: Pushable {
    public func push(onto L: LuaState) {
        L.newtable(narr: CInt(self.count))
        for (i, val) in self.enumerated() {
            val.push(onto: L)
            lua_rawseti(L, -2, lua_Integer(i + 1))
        }
    }
}

extension Dictionary: Pushable where Key: Pushable, Value: Pushable {
    public func push(onto L: LuaState) {
        L.newtable(nrec: CInt(self.count))
        for (k, v) in self {
            L.push(k)
            L.push(v)
            lua_rawset(L, -3)
        }
    }
}

extension UnsafeRawBufferPointer: Pushable {
    public func push(onto L: LuaState) {
        self.withMemoryRebound(to: CChar.self) { charBuf -> Void in
            lua_pushlstring(L, charBuf.baseAddress, charBuf.count)
        }
    }
}
