// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

import CLua

/// Protocol adopted by any Swift type that can unambiguously be converted to a basic Lua type.
///
/// Any type which conforms to Pushable (either due to an extension provided by the `Lua` module, or by an implemention
/// from anywhere else) can be pushed onto the Lua stack using
/// ``Lua/Swift/UnsafeMutablePointer/push(_:toindex:)-59fx9``. Several functions have convenience overloads allowing
/// `Pushable` values to be passed in directly, shortcutting the need to push them onto the stack then refer to them by
/// stack index, such as ``Lua/Swift/UnsafeMutablePointer/setglobal(name:value:)``.
///
/// For example:
/// ```swift
/// let L = LuaState(libraries: .all)
/// L.push(1234) // Integer is Pushable
/// L.push(["abc", "def"]) // String is Pushable, therefore Array<String> is too
/// L.setglobal("foo", "bar")
/// ```
///
/// Note that `[UInt8]` does not conform to `Pushable` because there is ambiguity as to whether that should be
/// represented as an array of integers or as a string of bytes, and because of that `UInt8` cannot conform either.
public protocol Pushable {
    /// Push this Swift value onto the stack, as a Lua type.
    func push(onto state: LuaState)
}

extension Bool: Pushable {
    public func push(onto L: LuaState) {
        lua_pushboolean(L, self ? 1 : 0)
    }
}

extension Int: Pushable {
    public func push(onto L: LuaState) {
        lua_pushinteger(L, lua_Integer(self))
    }
}

extension CInt: Pushable {
    public func push(onto L: LuaState) {
        lua_pushinteger(L, lua_Integer(self))
    }
}

extension Int64: Pushable {
    public func push(onto L: LuaState) {
        lua_pushinteger(L, self)
    }
}

extension Double: Pushable {
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
        lua_createtable(L, CInt(self.count), 0)
        for (i, val) in self.enumerated() {
            val.push(onto: L)
            lua_rawseti(L, -2, lua_Integer(i + 1))
        }
    }
}

extension Dictionary: Pushable where Key: Pushable, Value: Pushable {
    public func push(onto L: LuaState) {
        lua_createtable(L, 0, CInt(self.count))
        for (k, v) in self {
            L.push(k)
            L.push(v)
            lua_settable(L, -3)
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
