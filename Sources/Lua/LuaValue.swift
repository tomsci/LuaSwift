// Copyright (c) 2023 Tom Sutcliffe
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation
import CLua

/// A Swift type which holds a reference to a Lua value.
/// 
/// The Lua value will not be collected as long as the `LuaValue` remains valid. The `LuaValue` object can be pushed
/// back on to the Lua stack, or converted back to a Swift value using one of the `to...()` functions, which behave
/// the same as the similarly-named members of `LuaState` that take a stack index.
///
/// Using `LuaValue` objects to represent Lua values has (marginally) more overhead than working directly with stack
/// indexes.
///
/// `LuaValue` supports indexing the Lua value using `get()` or the subscript operator, assuming the Lua type
/// supports indexing - if it doesn't, a `LuaValueError` will be thrown. Because the subscript operator cannot throw,
/// attempting to use it on a nil value or one that does not support indexing will cause a `fatalError` - use `get()`
/// instead (which can throw) if the value might not support indexing. The following are equivalent:
///
/// ```swift
/// try! L.globals.get("print")
/// L.globals["print"] // equivalent
/// ```
///
/// Assuming the Lua value is callable, it can be called using `pcall()` or using the @dynamicCallable syntax. If it is
/// not callable, `LuaValueError.notCallable` will be thrown.
///
/// ```swift
/// let printFn = L.globals["print"]
/// try! printFn.pcall("Hello World!")
/// try! printFn("Hello World!") // Equivalent to the line above
/// ```
///
/// Because `LuaValue` is `Pushable` and `LuaValue.pcall()` returns a `LuaValue`, they can be chained together:
///
/// ```swift
/// // This calls type(print)
/// let result = try! L.globals["type"].pcall(L.globals["print"])
/// ```
///
/// `LuaValue` objects are only valid as long as the `LuaState` is. Calling any of its functions after the
/// `LuaState` has been closed will cause a crash.
@dynamicCallable
public class LuaValue: Equatable, Hashable, Pushable {
    var L: LuaState!
    let ref: CInt

    /// The type of the value this `LuaValue` represents.
    public let type: LuaType

    init(L: LuaState, index: CInt) {
        self.L = L
        self.type = L.type(index)!
        lua_pushvalue(L, index)
        self.ref = luaL_ref(L, LUA_REGISTRYINDEX)
    }

    // Takes ownership of an existing ref
    init(L: LuaState, ref: CInt, type: LuaType) {
        self.L = L
        self.type = type
        self.ref = ref
    }

    deinit {
        // LUA_RIDX_GLOBALS is not actually a luaL_ref (despite otherwise acting like one) so doesn't need to be
        // unref'd (and mustn't be, because it is not tracked in _State.luaValues thus L won't be nilled if the
        // state is closed). `LuaValue`s representing `nil` are never tracked either.
        if ref != LUA_RIDX_GLOBALS && ref != LUA_REFNIL {
            if let L {
                L.unref(ref)
            }
        }
    }

    public static func == (lhs: LuaValue, rhs: LuaValue) -> Bool {
        return lhs.L == rhs.L && lhs.ref == rhs.ref
    }

    public func hash(into hasher: inout Hasher) {
        L.hash(into: &hasher)
        ref.hash(into: &hasher)
    }

    /// Pushes the value this `LuaValue` represents onto the Lua stack of `L`.
    ///
    /// - Note: `L` must be related to the `LuaState` used to construct the object.
    public func push(state L: LuaState!) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, lua_Integer(self.ref))
    }

    // MARK: - to...() functions

    public func toboolean() -> Bool {
        L.push(self)
        let result = L.toboolean(-1)
        L.pop()
        return result
    }

    public func tointeger() -> lua_Integer? {
        L.push(self)
        let result = L.tointeger(-1)
        L.pop()
        return result
    }

    public func toint() -> Int? {
        L.push(self)
        let result = L.toint(-1)
        L.pop()
        return result
    }

    public func tonumber() -> Double? {
        L.push(self)
        let result = L.tonumber(-1)
        L.pop()
        return result
    }

    public func todata() -> Data? {
        L.push(self)
        let result = L.todata(-1)
        L.pop()
        return result
    }

    public func tostring(encoding: ExtendedStringEncoding? = nil, convert: Bool = false) -> String? {
        L.push(self)
        let result = L.tostring(-1, encoding: encoding, convert: convert)
        L.pop()
        return result
    }

    public func tostring(encoding: String.Encoding, convert: Bool = false) -> String? {
        L.push(self)
        let result = L.tostring(-1,  encoding: encoding, convert: convert)
        L.pop()
        return result
    }

    public func tostringarray(encoding: ExtendedStringEncoding? = nil, convert: Bool = false) -> [String]? {
        L.push(self)
        let result = L.tostringarray(-1, encoding: encoding, convert: convert)
        L.pop()
        return result
    }

    public func tostringarray(encoding: String.Encoding, convert: Bool = false) -> [String]? {
        L.push(self)
        let result = L.tostringarray(-1, encoding: encoding, convert: convert)
        L.pop()
        return result
    }

    public func toany(guessType: Bool = true) -> Any? {
        L.push(self)
        let result = L.toany(-1, guessType: guessType)
        L.pop()
        return result
    }

    public func tovalue<T>() -> T? {
        L.push(self)
        let result: T? = L.tovalue(-1)
        L.pop()
        return result
    }

    public func touserdata<T>() -> T? {
        L.push(self)
        let result: T? = L.touserdata(-1)
        L.pop()
        return result
    }

    // MARK: - Callable

    private func pushAndCheckCallable() throws {
        try checkNonNil()
        L.push(self)
        try checkCallable()
    }

    private func checkCallable() throws {
        if L.type(-1) != .function {
            let callMetafieldType = luaL_getmetafield(L, -1, "__call")
            L.pop()
            if callMetafieldType != LUA_TFUNCTION {
                L.pop()
                throw LuaValueError.notCallable
            }
        }
    }

    public func pcall(nargs: CInt, nret: CInt, traceback: Bool = true) throws {
        try pushAndCheckCallable()
        try L.pcall(nargs: nargs, nret: nret, traceback: traceback)
    }

    @discardableResult
    public func pcall(_ arguments: Any?..., traceback: Bool = true) throws -> LuaValue {
        return try pcall(arguments: arguments, traceback: traceback)
    }

    @discardableResult
    public func pcall(arguments: [Any?], traceback: Bool = true) throws -> LuaValue {
        try pushAndCheckCallable()
        for arg in arguments {
            L.push(any: arg)
        }
        try L.pcall(nargs: CInt(arguments.count), nret: 1, traceback: traceback)
        let result = L.ref(-1)
        L.pop()
        return result
    }

    /// Call a member function with `self` as the first argument.
    ///
    /// - Parameter member: The name of the member function to call.
    /// - Parameter arguments: Arguments to pass to the Lua function.
    /// - Parameter traceback: If true, any errors thrown will include a full stack trace.
    /// - Returns: The first result of the function, as a `LuaValue`.
    /// - Throws: ``LuaCallError`` if `member` does not exist or is not callable, or if a Lua error is raised during the
    ///   execution of the function.
    @discardableResult
    public func pcall(member: String, _ arguments: Any?..., traceback: Bool = true) throws -> LuaValue {
        return try pcall(member: member, arguments: arguments, traceback: traceback)
    }

    @discardableResult
    public func pcall(member: String, arguments: [Any?], traceback: Bool = true) throws -> LuaValue {
        let fn = try self.get(member)
        try fn.checkNonNil()
        L.push(fn)
        try checkCallable()
        L.push(self)
        for arg in arguments {
            L.push(any: arg)
        }
        try L.pcall(nargs: CInt(arguments.count + 1), nret: 1, traceback: traceback)
        let result = L.ref(-1)
        L.pop()
        return result
    }

    public func dynamicallyCall(withArguments arguments: [Any?]) throws -> LuaValue {
        return try pcall(arguments: arguments, traceback: true)
    }

    // MARK: - Get

    func checkNonNil() throws {
        if !valid() {
            throw LuaValueError.nilValue
        }
    }

    func checkIndexable() throws {
        if L.type(-1) != .table {
            let indexMetafieldType = luaL_getmetafield(L, -1, "__index")
            L.pop()
            if indexMetafieldType != LUA_TFUNCTION && indexMetafieldType != LUA_TTABLE {
                L.pop() // The value itself
                throw LuaValueError.notIndexable
            }
        }
    }

    /// Returns true if the instance represents a valid non-`nil` Lua value.
    public func valid() -> Bool {
        return self.type != .nilType
    }

    /// Returns the value for the given key, assuming the Lua value associated with `self` supports indexing.
    ///
    /// ```swift
    /// let printFn = L.globals.get("print")
    /// ```
    ///
    /// - Parameter key: The key to use for indexing.
    /// - Returns: The value associated with `key` as a `LuaValue`.
    /// - Throws: `LuaValueError.nilValue` if the Lua value is nil.
    /// - Throws: `LuaValueError.notIndexable` if the Lua value does not support indexing.
    /// - Throws: ``LuaCallError`` if an error is thrown during a metatable `__index` call.
    ///
    public func get(_ key: Any) throws -> LuaValue {
        try checkNonNil()
        L.push(self)
        try checkIndexable()
        // Don't call lua_gettable directly, it can error
        L.push { L in
            lua_gettable(L, 1)
            return 1
        }
        lua_insert(L, -2) // Move the fn below self
        L.push(any: key)
        try L.pcall(nargs: 2, nret: 1)
        return L.ref(-1)
    }

    /// Non-throwing convenience function, otherwise identical to ``get(_:)``.
    ///
    /// ```swift
    /// let printFn = L.globals["print"]
    /// ```
    ///
    /// - Returns: The value associated with `key` as a `LuaValue`.
    /// - Precondition: The Lua value associated with `self` must support indexing without throwing an error.
    public subscript(key: Any) -> LuaValue {
        return try! get(key)
    }
}

struct UnownedLuaValue {
    unowned let val: LuaValue
}

/// Errors that can be thrown while using `LuaValue` (in addition to ``Lua/LuaCallError``).
public enum LuaValueError: Error {
    /// A call or index was attempted on a `nil` value.
    case nilValue
    /// An index operation was attempted on a value that is not indexable.
    case notIndexable
    /// A call operation was attempted on a value that is not callable.
    case notCallable
}
