// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

import CLua

public protocol Pushable {
    /// Push this Swift value on to the stack, as a Lua type.
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
    /// Push the string on to the Lua stack using the default string encoding.
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

/// A `Pushable` wrapper around a `lua_CFunction`.
public struct LuaFunctionWrapper: Pushable {
    public let function: lua_CFunction

    public func push(onto L: LuaState) {
        L.push(function: function)
    }
}

/// A `Pushable` wrapper around a `[UInt8]`.
public struct LuaDataArrayWrapper: Pushable {
    public let data: [UInt8]

    public func push(onto L: LuaState) {
        L.push(data)
    }
}

/// A `Pushable` wrapper that pushes its value as a userdata.
public struct LuaUserdataWrapper: Pushable {
    public let value: Any

    public func push(onto L: LuaState) {
        L.push(userdata: value)
    }
}    

/// Internal helper class. Do not instantiate directly.
public struct NonPushableTypesHelper: Pushable {
    private init() {}
    public func push(onto L: LuaState) {
        fatalError() // will never be called
    }
}

// It's not clear to me why the "where Self == NonPushableTypesHelper" has to exist, other than because the type system
// needs there to be _some_ sort of concrete type to resolve ".nilValue" against.
extension Pushable where Self == NonPushableTypesHelper {
    /// Returns a Pushable representing the `nil` Lua value.
    ///
    /// This permits the use of `.nilValue` anywhere a Pushable can be specified. For example to remove `somekey`
    /// from the table on top of the stack:
    ///
    /// ```swift
    /// L.rawset(-1, key: "somekey", value: .nilValue)
    /// ```
    public static var nilValue: some Pushable {
        return LuaValue.nilValue
    }

    /// Returns a Pushable representing a `lua_CFunction`.
    ///
    /// This permits the use of `.function(fn)` anywhere a Pushable can be specified. For example to define a global
    /// function:
    ///
    /// ```swift
    /// L.setglobal(name: "thursday", value: .function { L in
    ///     L!.push(42)
    ///     return 1
    /// }
    /// ```
    public static func function(_ val: lua_CFunction) -> LuaFunctionWrapper {
        // The return type should be `some Pushable`, see https://github.com/apple/swift/issues/61357
        return LuaFunctionWrapper(function: val)
    }

    /// Returns a Pushable representing a `LuaClosure`.
    ///
    /// This permits the use of `.closure(fn)` anywhere a Pushable can be specified. For example to define a global
    /// function:
    ///
    /// ```swift
    /// L.setglobal(name: "thursday", value: .closure { L in
    ///     L.push(42)
    ///     return 1
    /// }
    /// ```
    public static func closure(_ val: @escaping LuaClosure) -> LuaClosureWrapper {
        // The return type should be `some Pushable`, see https://github.com/apple/swift/issues/61357
        return LuaClosureWrapper(val)
    }

    /// Returns a Pushable representing a `UInt8` Array as a byte string.
    ///
    /// This permits the use of `.data(fn)` anywhere a Pushable can be specified. For example to define a global
    /// string:
    ///
    /// ```swift
    /// L.setglobal(name: "hello", value: .data([0x77, 0x6F, 0x72, 0x6C, 0x64]))
    /// ```
    public static func data(_ val: [UInt8]) -> LuaDataArrayWrapper {
        // The return type should be `some Pushable`, see https://github.com/apple/swift/issues/61357
        return LuaDataArrayWrapper(data: val)
    }

    /// Returns a Pushable which pushes its value using `push(userdata:)`.
    ///
    /// This is useful for types which have a metatable registered but do not themselves implement `Pushable` and
    /// therefore must be pushed using ``Lua/Swift/UnsafeMutablePointer/push(userdata:toindex:)``. For example to define
    /// a global value:
    ///
    /// ```swift
    /// L.setglobal(name: "hello", value: .userdata(some_value))
    /// ```
    public static func userdata(_ val: Any) -> LuaUserdataWrapper {
        return LuaUserdataWrapper(value: val)
    }
}
