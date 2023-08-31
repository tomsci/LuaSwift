// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

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
/// let result = try! L.globals["type"].pcall(L.globals["print"]).tostring()
/// // result is "function"
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

    // Takes ownership of an existing ref
    init(L: LuaState, ref: CInt, type: LuaType) {
        self.L = L
        self.type = type
        self.ref = ref
    }

    /// Create a LuaValue with a nil value.
    public static func nilValue(_ L: LuaState) -> LuaValue {
        return LuaValue(L: L, ref: LUA_REFNIL, type: .nilType)
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
    public func push(state L: LuaState) {
        precondition(self.L != nil, "LuaValue used after LuaState has been deinited!")
        lua_rawgeti(L, LUA_REGISTRYINDEX, lua_Integer(self.ref))
    }

    // MARK: - to...() functions

    public func toboolean() -> Bool {
        push(state: L)
        let result = L.toboolean(-1)
        L.pop()
        return result
    }

    public func tointeger() -> lua_Integer? {
        push(state: L)
        let result = L.tointeger(-1)
        L.pop()
        return result
    }

    public func toint() -> Int? {
        push(state: L)
        let result = L.toint(-1)
        L.pop()
        return result
    }

    public func tonumber() -> Double? {
        push(state: L)
        let result = L.tonumber(-1)
        L.pop()
        return result
    }

    public func todata() -> [UInt8]? {
        push(state: L)
        let result = L.todata(-1)
        L.pop()
        return result
    }

    public func tostring(convert: Bool = false) -> String? {
        push(state: L)
        let result = L.tostring(-1, convert: convert)
        L.pop()
        return result
    }

    public func toany(guessType: Bool = true) -> Any? {
        push(state: L)
        let result = L.toany(-1, guessType: guessType)
        L.pop()
        return result
    }

    public func tovalue<T>() -> T? {
        push(state: L)
        let result: T? = L.tovalue(-1)
        L.pop()
        return result
    }

    public func touserdata<T>() -> T? {
        push(state: L)
        let result: T? = L.touserdata(-1)
        L.pop()
        return result
    }

    /// Convert a value on the stack to the specified `Decodable` type.
    ///
    /// If `T` is a composite struct or class type, the Lua representation must be a table with members corresponding
    /// to the Swift member names. Userdata values, or tables containing userdatas, are not convertible using this
    /// function - use `touserdata()` ot `tovalue()` instead.
    ///
    /// - Returns: A value of type `T`, or `nil` if the value at the given stack position cannot be decoded to `T`.
    func todecodable<T: Decodable>() -> T? {
        push(state: L)
        let result = L.todecodable(-1, T.self)
        L.pop()
        return result
    }

    /// Convert a value on the stack to the specified `Decodable` type.
    ///
    /// If `T` is a composite struct or class type, the Lua representation must be a table with members corresponding
    /// to the Swift member names. Userdata values, or tables containing userdatas, are not convertible using this
    /// function - use `touserdata()` ot `tovalue()` instead.
    ///
    /// - Parameter type: The `Decodable` type to convert to.
    /// - Returns: A value of type `T`, or `nil` if the value at the given stack position cannot be decoded to `T`.
    func todecodable<T: Decodable>(_ type: T.Type) -> T? {
        push(state: L)
        let result = L.todecodable(-1, type)
        L.pop()
        return result
    }

    // MARK: - Callable

    private func pushAndCheckCallable() throws {
        try checkValid()
        push(state: L)
        try Self.checkTopIsCallable(L)
    }

    // On error, pops stack top
    private static func checkTopIsCallable(_ L: LuaState!) throws {
        if L.type(-1) != .function {
            let callMetafieldType = luaL_getmetafield(L, -1, "__call")
            if callMetafieldType != LUA_TNIL {
                L.pop() // Pop the metafield
            }
            if callMetafieldType != LUA_TFUNCTION {
                L.pop() // Pop the value
                throw LuaValueError.notCallable
            }
        }
    }

    public func pcall(nargs: CInt, nret: CInt, traceback: Bool = true) throws {
        try pushAndCheckCallable()
        lua_insert(L, -(nret + 1))
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
        return L.popref()
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
        try fn.checkValid()
        L.push(fn)
        try Self.checkTopIsCallable(L)
        L.push(self)
        for arg in arguments {
            L.push(any: arg)
        }
        try L.pcall(nargs: CInt(arguments.count + 1), nret: 1, traceback: traceback)
        return L.popref()
    }

    @discardableResult
    public func dynamicallyCall(withArguments arguments: [Any?]) throws -> LuaValue {
        return try pcall(arguments: arguments, traceback: true)
    }

    // MARK: - Get/Set

    func checkValid() throws {
        if !valid() {
            throw LuaValueError.nilValue
        }
    }

    // On error, pops stack top
    private static func checkTopIsIndexable(_ L: LuaState!) throws {
        // Tables are always indexable, we don't actually need to check how
        if L.type(-1) != .table {
            let indexMetafieldType = luaL_getmetafield(L, -1, "__index")
            if indexMetafieldType == LUA_TNIL {
                L.pop() // The value itself
                throw LuaValueError.notIndexable
            }
            defer {
                L.pop() // index metafield
            }
            if indexMetafieldType != LUA_TFUNCTION {
                try checkTopIsIndexable(L)
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
    /// - Throws: `LuaValueError.nilValue` if the Lua value associated with `self` is nil.
    /// - Throws: `LuaValueError.notIndexable` if the Lua value does not support indexing.
    /// - Throws: ``LuaCallError`` if an error is thrown during a metatable `__index` call.
    public func get(_ key: Any) throws -> LuaValue {
        try self.checkValid()
        push(state: L)
        try Self.checkTopIsIndexable(L)
        defer {
            L.pop()
        }
        L.push(any: key)
        try L.get(-2)
        return L.popref()
    }

    /// Returns the length of a value, as per the [length operator](https://www.lua.org/manual/5.4/manual.html#3.4.7).
    ///
    /// - Throws: `LuaValueError.nilValue` if the Lua value associated with `self` is nil.
    /// - Throws: `LuaValueError.noLength` if the Lua value does not support the length operator, or `__len` did not
    ///   return an integer.
    /// - Throws: ``LuaCallError`` if an error is thrown during a metatable `__len` call.
   public var len: lua_Integer {
       get throws {
           try self.checkValid()
           push(state: L)
           defer {
               L.pop()
           }
           if let result = try L.len(-1) {
               return result
           } else {
               throw LuaValueError.noLength
           }
       }
   }

    // On error, pops stack top
    private static func checkTopIsNewIndexable(_ L: LuaState!) throws {
        // Tables are always newindexable, we don't actually need to check how
        if L.type(-1) != .table {
            let newIndexMetafieldType = luaL_getmetafield(L, -1, "__newindex")
            if newIndexMetafieldType == LUA_TNIL {
                L.pop() // The value itself
                throw LuaValueError.notNewIndexable
            }
            defer {
                L.pop() // newindex metafield
            }
            if newIndexMetafieldType != LUA_TFUNCTION {
                try checkTopIsNewIndexable(L)
            }
        }
    }

    /// Sets the value of `key` in the Lua value associated with `self` to `value`, assuming it supports indexing.
    ///
    /// ```swift
    /// try L.globals.set("foo", "bar") // Equivalent to _G["foo"] = "bar"
    /// ```
    ///
    /// - Parameter key: The key to use for indexing.
    /// - Parameter value: The value to set. Can be nil to remove `key` from the table.
    /// - Throws: `LuaValueError.nilValue` if the Lua value associated with `self` is nil.
    /// - Throws: `LuaValueError.notNewIndexable` if the Lua value does not support indexing.
    /// - Throws: ``LuaCallError`` if an error is thrown during a metatable `__newindex` call.
    public func set(_ key: Any, _ value: Any?) throws {
        try self.checkValid()
        push(state: L)
        try Self.checkTopIsNewIndexable(L)
        L.push({ L in
            lua_settable(L, 1)
            return 0
        })
        lua_insert(L, -2) // Move the fn below self
        L.push(any: key)
        L.push(any: value)
        try L.pcall(nargs: 3, nret: 0)
    }

    /// Non-throwing convenience function, otherwise identical to ``get(_:)`` or ``set(_:_:)``.
    ///
    /// If any error is thrown by the underlying `get()` or `set()` call, the error is silently ignored and (in the
    /// case of `get()`) a `LuaValue` representing `nil` is returned instead. Use `get()` or `set()` if you want to
    /// preserve any error.
    ///
    /// ```swift
    /// let printFn = L.globals["print"]
    /// L.globals["foo"] = bar
    /// ```
    public subscript(key: Any) -> LuaValue {
        get {
            return (try? get(key)) ?? .nilValue(L)
        }
        set(newValue) {
            do {
                try set(key, newValue)
            } catch {
                // Ignore
            }
        }
    }

    // MARK: - Iterators

    private class IPairsIterator : Sequence, IteratorProtocol {
        let value: LuaValue
        var i: lua_Integer
        init(_ value: LuaValue, start: lua_Integer?) {
            self.value = value
            i = (start ?? 1) - 1
        }
        public func next() -> (lua_Integer, LuaValue)? {
            i = i + 1
            let val = value[i]
            if val.type != .nilType {
                return (i, val)
            } else {
                return nil
            }
        }
    }

    /// Return a for-iterator that iterates the array part of a table.
    ///
    /// Returning each array member as a `LuaValue`. Members are looked up using the same semantics as subscript,
    /// thus any errors thrown by `get()` will treated like `nil` and will complete the iteration, and otherwise
    /// ignored. Use `for_ipairs(block:)` instead, to preserve any errors thrown.
    ///
    /// ```swift
    /// let foo = L.ref(any: [11, 22, 33])
    /// for (i, val) in foo.ipairs() {
    ///     print("Index \(i) is \(val.toint()!)")
    /// }
    /// // Prints:
    /// // Index 1 is 11
    /// // Index 2 is 22
    /// // Index 3 is 33
    /// ```
    ///
    /// - Parameter start: If set, start iteration at this index rather than the beginning of the array.
    /// - Throws: `LuaValueError.nilValue` if the Lua value associated with `self` is `nil`.
    /// - Throws: `LuaValueError.notIndexable` if the Lua value does not support indexing.
    public func ipairs(start: lua_Integer? = nil) throws -> some Sequence<(lua_Integer, LuaValue)> {
        try checkValid()
        push(state: L)
        try Self.checkTopIsIndexable(L)
        L.pop()
        return IPairsIterator(self, start: start)
    }

    private class PairsIterator: Sequence, IteratorProtocol {
        let iterFn: LuaValue
        let state: LuaValue
        var k: LuaValue
        init(_ value: LuaValue) throws {
            let L = value.L!
            value.push(state: L)
            let isIterable = try L.pushPairsParameters()
            if !isIterable {
                L.pop(3)
                throw LuaValueError.notIterable
            }
            k = L.popref()
            state = L.popref()
            iterFn = L.popref()
        }

        public func next() -> (LuaValue, LuaValue)? {
            let L = iterFn.L!
            L.push(state)
            L.push(k)
            do {
                try iterFn.pcall(nargs: 2, nret: 2)
            } catch {
                // print warning?
                return nil
            }
            let val = L.popref()
            k = L.popref()
            if k.type != .nilType {
                return (k, val)
            } else {
                return nil
            }
        }
    }

    /// Return a for-iterator that will iterate all the members of a value.
    ///
    /// The values in the table are iterated in an unspecified order. The `__pairs` metafield is respected if present.
    /// If `__pairs` returned an iterator function which errors at any point during the iteration, the error is
    /// silently ignored and will be treated as if it returned `nil, nil`, ie will end the iteration. Use
    /// `for_pairs(block:)` to preserve such errors.
    ///
    /// ```swift
    /// let foo = L.ref(any: ["a": 1, "b": 2, "c": 3])
    /// for (key, value) in try foo.pairs() {
    ///     print("\(key.tostring()!) \(value.toint()!)")
    /// }
    /// // ...might output the following:
    /// // b 2
    /// // c 3
    /// // a 1
    /// ```
    ///
    /// - Throws: `LuaValueError.nilValue` if the Lua value associated with `self` is nil.
    /// - Throws: `LuaValueError.notIterable` if the Lua value is not a table and does not have a `__pairs` metafield.
    /// - Throws: ``LuaCallError`` if an error is thrown during a `__pairs` call.
    public func pairs() throws -> some Sequence<(LuaValue, LuaValue)> {
        return try PairsIterator(self)
    }

    /// Calls the given closure with each array element in order.
    ///
    /// `__index` metafields are observed, if present, and any error thrown by them will be re-thrown from
    /// `for_ipairs()` as a `LuaCallError`. `block` is called with two arguments, the integer `index` of the array
    /// item, and a `LuaValue` representing the value. `block` can return `false` to halt the iteration early,
    /// otherwise it should return `true`.
    ///
    /// ```swift
    /// let foo = L.ref(any: [11, 22, 33])
    /// for (i, val) in foo.ipairs() {
    ///     print("Index \(i) is \(val.toint()!)")
    /// }
    /// // Prints:
    /// // Index 1 is 11
    /// // Index 2 is 22
    /// // Index 3 is 33
    /// ```
    ///
    /// - Parameter start: If set, start iteration at this index rather than the beginning of the array.
    /// - Throws: `LuaValueError.nilValue` if the Lua value associated with `self` is `nil`.
    /// - Throws: `LuaValueError.notIndexable` if the Lua value does not support indexing.
    /// - Throws: ``LuaCallError`` if an error is thrown during an `__index` call.
    public func for_ipairs(start: lua_Integer? = nil, block: (lua_Integer, LuaValue) throws -> Bool) throws {
        try checkValid()
        push(state: L)
        try Self.checkTopIsIndexable(L)
        defer {
            L.pop()
        }
        try L.for_ipairs(-1, start: start) { i in
            let value = L.popref()
            return try block(i, value)
        }
    }

    /// Iterate a Lua table-like value, calling `block` for each member.
    ///
    /// This function observes `__pairs` metatables if present. `block` should
    /// return `true` to continue iteration, or `false` otherwise.
    ///
    /// ```swift
    /// let foo = L.ref(any: ["a": 1, "b": 2, "c": 3])
    /// try foo.for_pairs() { key, value in
    ///     print("\(key.tostring()!) \(value.toint()!)")
    ///     return true // continue iteration
    /// }
    /// ```
    ///
    /// - Parameter index: Stack index of the table to iterate.
    /// - Parameter block: The code to execute.
    /// - Throws: `LuaValueError.nilValue` if the Lua value associated with `self` is nil.
    /// - Throws: `LuaValueError.notIterable` if the Lua value is not a table and does not have a `__pairs` metafield.
    /// - Throws: ``LuaCallError`` if an error is thrown during a `__pairs` or iterator call.
    public func for_pairs(block: (LuaValue, LuaValue) throws -> Bool) throws {
        try checkValid()
        push(state: L)
        let iterable = try L.pushPairsParameters() // pops self, pushes iterfn, state, initval
        if !iterable {
            L.pop(3) // iterfn, state, initval
            throw LuaValueError.notIterable
        }

        try L.do_for_pairs() { k, v in
            let key = L.ref(index: k)
            let value = L.ref(index: v)
            return try block(key, value)
        }
    }

    /// Convenience function to iterate the value as an array using `for_ipairs()`.
    ///
    /// - Throws: `LuaValueError.nilValue` if the Lua value associated with `self` is `nil`.
    /// - Throws: `LuaValueError.notIndexable` if the Lua value does not support indexing.
    /// - Throws: ``LuaCallError`` if an error is thrown during an `__index` call.
    public func forEach(_ block: (LuaValue) throws -> Void) throws {
        try for_ipairs() { _, value in
            try block(value)
            return true
        }
    }

    public func forEach(_ block: (LuaValue, LuaValue) throws -> Void) throws {
        try for_pairs() { key, value in
            try block(key, value)
            return true
        }
    }

}

struct UnownedLuaValue {
    unowned let val: LuaValue
}
