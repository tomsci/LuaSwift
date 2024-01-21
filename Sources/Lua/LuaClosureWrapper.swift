// Copyright (c) 2023-2024 Tom Sutcliffe
// See LICENSE file for license information.

import CLua

/// See ``LuaCallContinuation``.
public struct LuaCallContinuationStatus {
    public let yielded: Bool
}

/// See ``LuaPcallContinuation``.
public struct LuaPcallContinuationStatus {
    public let yielded: Bool
    public let error: LuaCallError?
}

/// As per ``LuaPcallContinuation`` but for `callk()` rather than `pcallk()`.
public typealias LuaCallContinuation = (LuaState, LuaCallContinuationStatus) throws -> CInt

public typealias LuaPcallContinuation = (LuaState, LuaPcallContinuationStatus) throws -> CInt

internal class LuaContinuationWrapper {
    let continuation: LuaPcallContinuation

    init(_ continuation: @escaping LuaPcallContinuation) {
        self.continuation = continuation
    }
}

/// A class which wraps a Swift closure of type ``LuaClosure`` and can be pushed as a Lua function.
///
/// Normally you would call ``Lua/Swift/UnsafeMutablePointer/push(_:numUpvalues:toindex:)`` or one of the
/// `L.push(closure:)` overloads rather than using this class directly - internally those functions use
/// `LuaClosureWrapper`. Using `LuaClosureWrapper` explicitly can be useful if you need to track a `LuaClosure` as a
/// ``Pushable`` object.
///
/// Do not use `push(userdata:)` to push a `LuaClosureWrapper` - it will not be callable. Use
/// ``Lua/Swift/UnsafeMutablePointer/push(_:toindex:)-59fx9``, ``push(onto:)`` or
/// ``push(onto:numUpvalues:)`` instead.
public class LuaClosureWrapper: Pushable {

    /// The number of internal upvalues used when pushing a ``LuaClosure``.
    ///
    /// If ``Lua/Swift/UnsafeMutablePointer/push(_:numUpvalues:toindex:)`` was called with a non-zero `numUpvalues`, the
    /// stack pseudo-indexes for those upvalues do not start at `lua_upvalueindex(1)` as you might expect, but rather
    /// at `lua_upvalueindex(NumInternalUpvalues + 1)`. This is because some upvalues are used internally to support
    /// the ability for errors thrown by closures to be translated into Lua errors. Use the convenience function
    /// ``upvalueIndex(_:)`` instead of `lua_upvalueindex()` to avoid having to worry about this detail.
    ///
    /// For example:
    /// ```swift
    /// L.push(userdata: /*someValue*/) // upvalue
    /// L.push({ L in
    ///     // This is equivalent to lua_upvalueindex(NumInternalUpvalues + 1)
    ///     let idx = LuaClosureWrapper.upvalueIndex(1)
    ///     let upvalue: SomeValueType = L.tovalue(idx)!
    ///     /* do things with upvalue */
    /// }, numUpvalues: 1)
    /// ```
    public static let NumInternalUpvalues: CInt = 1

    /// Returns the stack pseudo-index for the specified upvalue to a `LuaClosure`.
    ///
    /// See ``NumInternalUpvalues`` for how this function differs from `lua_upvalueindex()`.
    ///
    /// - Parameter i: Which upvalue to get the index for. Must be between 1 and `numUpvalues` inclusive, where
    ///   `numUpvalues` is the value passed to ``Lua/Swift/UnsafeMutablePointer/push(_:numUpvalues:toindex:)``.
    /// - Returns: The stack pseudo-index for the specified upvalue.
    public static func upvalueIndex(_ i: CInt) -> CInt {
        return lua_upvalueindex(NumInternalUpvalues + i)
    }

    // This is only optional (and a var) because of the nonescaping requirements in for_pairs/for_ipairs
    var _closure: Optional<LuaClosure>

    public var closure: LuaClosure {
        return _closure!
    }

    public init(_ closure: @escaping LuaClosure) {
        self._closure = closure
    }

    private static let callClosure: lua_CFunction = { (L: LuaState!) -> CInt in
        let wrapper: LuaClosureWrapper = L.unchecked_touserdata(lua_upvalueindex(1))!
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

    internal static let callContinuation: lua_CFunction = { (L: LuaState!) -> CInt in
        let statusInt = CInt(L.toint(-1)!)
        let continuationIndex = CInt(L.toint(-2)!)
        let continuationWrapper: LuaContinuationWrapper = L.touserdata(continuationIndex)!
        L.pop(2) // statusInt, continuationIndex
        lua_remove(L, continuationIndex)
        lua_remove(L, continuationIndex - 1) // msgh

        // Stack should now be in correct state to call the continuation closure (except for possibly an error object)

        let status: LuaPcallContinuationStatus
        switch statusInt {
        case LUA_OK:
            status = LuaPcallContinuationStatus(yielded: false, error: nil)
        case LUA_YIELD:
            status = LuaPcallContinuationStatus(yielded: true, error: nil)
        default:
            status = LuaPcallContinuationStatus(yielded: false, error: LuaCallError.popFromStack(L))
        }

        do {
            return try continuationWrapper.continuation(L, status)
        } catch {
            L.push(error: error)
            return LUASWIFT_CALLCLOSURE_ERROR
        }
    }

    public func push(onto L: LuaState) {
        push(onto: L, numUpvalues: 0)
    }

    public func push(onto L: LuaState, numUpvalues: CInt) {
        precondition(numUpvalues >= 0 && numUpvalues <= 255 - Self.NumInternalUpvalues)

        // This only technically needs doing once but it's easier to just do it every time.
        L.push(function: luaswift_callclosurewrapper)
        L.push(function: Self.callClosure)
        L.rawset(LUA_REGISTRYINDEX)

        L.push(userdata: self)
        // Move these below numUpvalues
        if numUpvalues > 0 {
            lua_rotate(L, -(numUpvalues + Self.NumInternalUpvalues), Self.NumInternalUpvalues)
        }
        lua_pushcclosure(L, luaswift_callclosurewrapper, numUpvalues + Self.NumInternalUpvalues)
    }
}
