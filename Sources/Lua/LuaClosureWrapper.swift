// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

import CLua

/// A class which wraps a Swift closure of type ``LuaClosure`` and can be pushed as a Lua function.
///
/// Normally you would call ``Lua/Swift/UnsafeMutablePointer/push(_:numUpvalues:toindex:)`` or one of the
/// `L.push(closure:)` overloads rather than using this class directly - internally those functions use
/// `LuaClosureWrapper`. Using `LuaClosureWrapper` directly can be useful if you need to track a `LuaClosure` as a
/// ``Pushable`` object.
///
/// Do not use `push(userdata:)` to push a `LuaClosureWrapper` - it will not be callable. Use
/// ``Lua/Swift/UnsafeMutablePointer/push(_:toindex:)-59fx9``, ``push(onto:)`` or
/// ``push(onto:numUpvalues:)`` instead.
public class LuaClosureWrapper: Pushable {

    /// The number of internal upvalues used when pushing a ``LuaClosure``.
    ///
    /// If ``Lua/Swift/UnsafeMutablePointer/push(_:numUpvalues:toindex:)`` was called with a non-zero `numUpvalues`,
    /// those upvalues they do not start at `lua_upvalueindex(1)` as you might expect, but rather at
    /// `lua_upvalueindex(NumInternalUpvalues + 1)`. This is because some upvalues are used internally to support the
    /// ability for errors thrown by closures to be translated into Lua errors.
    ///
    /// For example:
    /// ```swift
    /// L.push(userdata: /*someValue*/) // upvalue
    /// L.push({ L in
    ///     let idx = lua_upvalueindex(LuaClosureWrapper.NumInternalUpvalues + 1)
    ///     let upvalue: SomeValueType = L.tovalue(idx)!
    ///     /* do things with upvalue */
    /// }, numUpvalues: 1)
    /// ```
    public static let NumInternalUpvalues: CInt = 2

    // This is only optional because of the nonescaping requirements in for_pairs/for_ipairs
    var _closure: Optional<LuaClosure>

    public var closure: LuaClosure {
        return _closure!
    }

    public init(_ closure: @escaping LuaClosure) {
        self._closure = closure
    }

    private static let callClosure: lua_CFunction = { (L: LuaState!) -> CInt in
        let wrapper: LuaClosureWrapper = L.tovalue(lua_upvalueindex(2))!
        guard let closure = wrapper._closure else {
            fatalError("Attempt to call a LuaClosureWrapper after it has been explicitly nilled")
        }

        do {
            return try closure(L)
        } catch {
            L.push(error: error)
            return LUASWIFT_CALLCLOSURE_ERROR
        }
    }

    public func push(onto L: LuaState) {
        push(onto: L, numUpvalues: 0)
    }

    public func push(onto L: LuaState, numUpvalues: CInt) {
        L.push(function: Self.callClosure)
        L.push(userdata: self)
        // Move these below numUpvalues
        if numUpvalues > 0 {
            lua_rotate(L, -(numUpvalues + Self.NumInternalUpvalues), Self.NumInternalUpvalues)
        }
        lua_pushcclosure(L, luaswift_callclosurewrapper, numUpvalues + Self.NumInternalUpvalues)
    }
}
