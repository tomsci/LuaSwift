// Copyright (c) 2023-2024 Tom Sutcliffe
// See LICENSE file for license information.

import CLua

/// A Swift type which holds a reference to a Lua value.
///
/// `LuaValue` is an alternative object-oriented way of interacting with Lua values. `LuaValue` objects may be used
/// and passed around without worrying about what state the Lua stack is in - there is a little more runtime overhead
/// in using them, but it can make code simpler. They can represent any Lua value (including `nil`) and support array
/// and dictionary subscript operations (providing the underlying Lua value does).
///
/// The Lua value will not be collected as long as the `LuaValue` remains valid. Internally, `LuaValue` uses
/// [`luaL_ref()`](https://www.lua.org/manual/5.4/manual.html#luaL_ref) to maintain a reference to the value. The
/// `LuaValue` object can be pushed back on to the Lua stack, or converted back to a Swift value using one of the
/// `to...()` functions, which behave the same as the similarly-named members of `LuaState` that take a stack index.
///
/// `LuaValue` supports indexing the Lua value using ``get(_:)`` or the subscript operator, assuming the Lua type
/// supports indexing - if it doesn't, a ``LuaValueError`` will be thrown. Because the subscript operator cannot throw,
/// attempting to use it on a nil value or one that does not support indexing will cause a `fatalError` - use `get()`
/// instead (which can throw) if the value might not support indexing or might error. The following are equivalent:
///
/// ```swift
/// try! L.globals.get("print")
/// L.globals["print"] // equivalent
/// ```
///
/// Assuming the Lua value is callable, it can be called using `pcall()` or using the `@dynamicCallable` syntax. If it 
/// is not callable, ``LuaValueError/notCallable`` will be thrown.
///
/// ```swift
/// let printFn: LuaValue = L.globals["print"]
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
/// `LuaValue` objects are only valid as long as the `LuaState` is. Calling any of its functions after the `LuaState`
/// has been closed will cause a `fatalError`. It is safe to allow `LuaValue` objects to `deinit` after the
/// `LuaState` has been closed, however.
///
/// 
/// Note that while `LuaValue` is `Equatable`, it does not compare the underlying values. Only two instances which have
/// the same `luaL_ref` ref compare equal. Similarly `LuaValue` is `Hashable`, but will not return the same hash value
/// as the underlying Lua value, in a similar way to how `AnyHashable` behaves.
@dynamicCallable
public final class LuaValue: Equatable, Hashable, Pushable {
    internal var L: LuaState!
    private let ref: CInt

    /// The type of the value this `LuaValue` represents.
    public let type: LuaType

    // Takes ownership of an existing ref
    internal init(L: LuaState, ref: CInt, type: LuaType) {
        self.L = L
        self.type = type
        self.ref = ref
    }

    /// Construct a `LuaValue` representing `nil`.
    public init() {
        self.L = nil
        self.type = .nil
        self.ref = LUA_REFNIL
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

    internal static var nilValue: LuaValue { return LuaValue() }

    public static func == (lhs: LuaValue, rhs: LuaValue) -> Bool {
        return lhs.L == rhs.L && lhs.ref == rhs.ref
    }

    public func hash(into hasher: inout Hasher) {
        L.hash(into: &hasher)
        ref.hash(into: &hasher)
    }

    /// Convenience API to create a LuaValue referencing a new empty table.
    public static func newtable(_ L: LuaState) -> LuaValue {
        L.newtable()
        return L.popref()
    }

    /// Load a Lua chunk from memory, without executing it, and return it as a `LuaValue`.
    public static func load(_ L: LuaState, _ string: String, name: String? = nil) throws -> LuaValue {
        try L.load(string: string, name: name)
        return L.popref()
    }

    /// Pushes the value this `LuaValue` represents on to the Lua stack of `L`.
    ///
    /// - Note: `L` must be related to the `LuaState` used to construct the object.
    public func push(onto L: LuaState) {
        if ref == LUA_REFNIL {
            L.pushnil()
        } else {
            precondition(self.L != nil, "LuaValue used after LuaState has been deinited!")
            precondition(self.L.getMainThread() == L.getMainThread(), "Cannot push a LuaValue onto an unrelated state")
            lua_rawgeti(L, LUA_REGISTRYINDEX, lua_Integer(self.ref))
        }
    }

    // MARK: - to...() functions

    public func toboolean() -> Bool {
        if isNil {
            return false
        }
        push(onto: L)
        let result = L.toboolean(-1)
        L.pop()
        return result
    }

    public func tointeger() -> lua_Integer? {
        if isNil {
            return nil
        }
        push(onto: L)
        let result = L.tointeger(-1)
        L.pop()
        return result
    }

    public func toint() -> Int? {
        if isNil {
            return nil
        }
        push(onto: L)
        let result = L.toint(-1)
        L.pop()
        return result
    }

    public func tonumber() -> lua_Number? {
        if isNil {
            return nil
        }
        push(onto: L)
        let result = L.tonumber(-1)
        L.pop()
        return result
    }

    public func todata() -> [UInt8]? {
        if isNil {
            return nil
        }
        push(onto: L)
        let result = L.todata(-1)
        L.pop()
        return result
    }

    public func tostring(convert: Bool = false) -> String? {
        if isNil {
            return nil
        }
        push(onto: L)
        let result = L.tostring(-1, convert: convert)
        L.pop()
        return result
    }

    public func toany(guessType: Bool = true) -> Any? {
        if isNil {
            return nil
        }
        push(onto: L)
        let result = L.toany(-1, guessType: guessType)
        L.pop()
        return result
    }

    public func tovalue<T>() -> T? {
        if isNil {
            return nil
        }
        push(onto: L)
        let result: T? = L.tovalue(-1)
        L.pop()
        return result
    }

    public func tovalue<T>(type: T.Type) -> T? {
        return tovalue()
    }

    public func touserdata<T>() -> T? {
        if isNil {
            return nil
        }
        push(onto: L)
        let result: T? = L.touserdata(-1)
        L.pop()
        return result
    }

    /// Convert a value on the stack to the specified `Decodable` type.
    ///
    /// If `T` is a composite struct or class type, the Lua representation must be a table with members corresponding
    /// to the Swift member names. Userdata values, or tables containing userdatas, are not convertible using this
    /// function - use ``touserdata()`` or ``tovalue()`` instead.
    ///
    /// - Returns: A value of type `T`, or `nil` if the value at the given stack position cannot be decoded to `T`.
    public func todecodable<T: Decodable>() -> T? {
        if isNil {
            return nil
        }
        push(onto: L)
        let result: T? = L.todecodable(-1)
        L.pop()
        return result
    }

    /// Convert a value on the stack to the specified `Decodable` type.
    ///
    /// If `T` is a composite struct or class type, the Lua representation must be a table with members corresponding
    /// to the Swift member names. Userdata values, or tables containing userdatas, are not convertible using this
    /// function - use ``touserdata()`` or ``tovalue()`` instead.
    ///
    /// - Parameter type: The `Decodable` type to convert to.
    /// - Returns: A value of type `T`, or `nil` if the value at the given stack position cannot be decoded to `T`.
    public func todecodable<T: Decodable>(type: T.Type) -> T? {
        return todecodable()
    }

    // MARK: - Callable

    private func pushAndCheckCallable() throws {
        try checkValid()
        push(onto: L)
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
        lua_insert(L, -(nargs + 1))
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
    /// - Throws: ``LuaValueError`` if `member` does not exist or is not callable, or an error of type determined by
    ///   whether a ``LuaErrorConverter`` is set if a Lua error is raised during the execution of the function.
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

    private func checkValid() throws {
        if isNil {
            throw LuaValueError.nilValue
        }
    }

    // On error, pops stack top
    private static func checkTopIsIndexable(_ L: LuaState) throws {
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

    /// Deprecated, use !``isNil`` instead.
    @available(*, deprecated, message: "Use !isNil instead")
    public func valid() -> Bool {
        return self.type != .nil
    }

    /// Returns true if the instance represents the `nil` Lua value.
    public var isNil: Bool {
        return self.type == .nil
    }

    /// Returns the value for the given key, assuming the Lua value associated with `self` supports indexing.
    ///
    /// ```swift
    /// let printFn = L.globals.get("print")
    /// ```
    ///
    /// - Parameter key: The key to use for indexing.
    /// - Returns: The value associated with `key` as a `LuaValue`.
    /// - Throws: ``LuaValueError/nilValue`` if the Lua value associated with `self` is `nil`.
    ///           ``LuaValueError/notIndexable`` if the Lua value does not support indexing.
    ///           An error (of type determined by whether a ``LuaErrorConverter`` is set) if an error is thrown during a
    ///           metatable `__index` call.
    public func get(_ key: Any) throws -> LuaValue {
        try self.checkValid()
        push(onto: L)
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
    /// - Throws: ``LuaValueError/nilValue`` if the Lua value associated with `self` is `nil`.
    ///           ``LuaValueError/noLength`` if the Lua value does not support the length operator, or `__len` did not
    ///           return an integer.
    ///           An error (of type determined by whether a ``LuaErrorConverter`` is set) if an error is thrown during a
    ///           metatable `__len` call.
   public var len: lua_Integer {
       get throws {
           try self.checkValid()
           push(onto: L)
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
    private static func checkTopIsNewIndexable(_ L: LuaState) throws {
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
    /// - Throws: ``LuaValueError/nilValue`` if the Lua value associated with `self` is nil.
    ///           ``LuaValueError/notNewIndexable`` if the Lua value does not support indexing.
    ///           An error (of type determined by whether a ``LuaErrorConverter`` is set) if an error is thrown during a
    ///           metatable `__newindex` call.
    public func set(_ key: Any, _ value: Any?) throws {
        try self.checkValid()
        push(onto: L)
        try Self.checkTopIsNewIndexable(L)
        defer {
            L.pop()
        }
        L.push(any: key)
        L.push(any: value)
        try L.set(-3)

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
            return (try? get(key)) ?? LuaValue.nilValue
        }
        set(newValue) {
            do {
                try set(key, newValue)
            } catch {
                // Ignore
            }
        }
    }

    /// Get or set the value's metatable.
    ///
    /// The result of getting a value's metatable will always be either a `LuaValue` of type `.table`, or `nil`.
    /// Setting a metatable to `LuaValue()` is equivalent to setting it to `nil`.
    ///
    /// - Precondition: When setting a metatable, the value must be of a type with per-value metatables, ie a table or userdata.
    public var metatable: LuaValue? {
        get {
            if isNil {
                return nil
            }
            L.push(self)
            defer {
                L.pop()
            }
            if lua_getmetatable(L, -1) == 1 {
                return L.popref()
            } else {
                return nil
            }
        }
        set {
            precondition(type == .table || type == .userdata)
            precondition(newValue == nil || newValue!.type == .nil || newValue!.type == .table,
                         "metatable must be a table or nil")
            L.push(self)
            defer {
                L.pop()
            }
            if let newValue {
                L.push(newValue)
            } else {
                L.pushnil()
            }
            lua_setmetatable(L, -2)
        }
    }

    // MARK: - Iterators

    private class IPairsIterator<T> : Sequence, IteratorProtocol {
        let value: LuaValue
        var i: lua_Integer
        init(_ value: LuaValue, start: lua_Integer) {
            self.value = value
            i = start - 1
        }
        public func next() -> (lua_Integer, T)? {
            i = i + 1
            let val = value[i]
            if let element: T = val.tovalue() {
                return (i, element)
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
    /// - Parameter start: What table index to start iterating from. Default is `1`, ie the start of the array.
    /// - Throws: ``LuaValueError/nilValue`` if the Lua value associated with `self` is `nil`.
    ///           ``LuaValueError/notIndexable`` if the Lua value does not support indexing.
    public func ipairs(start: lua_Integer = 1) throws -> some Sequence<(lua_Integer, LuaValue)> {
        try checkValid()
        push(onto: L)
        try Self.checkTopIsIndexable(L)
        L.pop()
        return IPairsIterator(self, start: start)
    }

    public func ipairs<T>(start: lua_Integer = 1, type: T.Type) throws -> some Sequence<(lua_Integer, T)> {
        try checkValid()
        push(onto: L)
        try Self.checkTopIsIndexable(L)
        L.pop()
        return IPairsIterator(self, start: start)
    }

    private class PairsIterator<K, V>: Sequence, IteratorProtocol {
        let iterFn: LuaValue
        let state: LuaValue
        var k: LuaValue
        init(_ value: LuaValue) throws {
            let L = value.L!
            value.push(onto: L)
            let isIterable = try L.pushPairsParameters()
            if !isIterable {
                L.pop(3)
                throw LuaValueError.notIterable
            }
            k = L.popref()
            state = L.popref()
            iterFn = L.popref()
        }

        public func next() -> (K, V)? {
            let L = iterFn.L!
            while true {
                L.push(state)
                L.push(k)
                do {
                    try iterFn.pcall(nargs: 2, nret: 2, traceback: false)
                } catch {
                    // print warning?
                    return nil
                }
                let v = L.popref()
                k = L.popref()
                if k.isNil {
                    return nil
                } else if let key: K = k.tovalue(),
                          let val: V = v.tovalue() {
                    return (key, val)
                } else {
                    // Skip this element, keep iterating
                    continue
                }
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
    /// - Throws: ``LuaValueError/nilValue`` if the Lua value associated with `self` is nil.
    ///           ``LuaValueError/notIterable`` if the Lua value is not a table and does not have a `__pairs` metafield.
    ///           An error (of type determined by whether a ``LuaErrorConverter`` is set) if an error is thrown during a
    ///           `__pairs` call.
    public func pairs() throws -> some Sequence<(LuaValue, LuaValue)> {
        try checkValid()
        return try PairsIterator(self)
    }

    /// Return a for-iterator that will iterate all the members of a value conforming to types `K` and `V`.
    ///
    /// The values in the table are iterated in an unspecified order. The `__pairs` metafield is respected if present.
    /// If `__pairs` returned an iterator function which errors at any point during the iteration, the error is
    /// silently ignored and will be treated as if it returned `nil, nil`, ie will end the iteration. Use
    /// `for_pairs(block:)` to preserve such errors. If any key or value cannot be converted to `K` or `V` using
    /// `tovalue()`, then the element is skipped and the iteration proceeds to the next value.
    ///
    /// ```swift
    /// let foo = L.ref(any: ["a": 1, "b": 2, "c": 3])
    /// for (key, value) in try foo.pairs(type: (String.self, Int.self)) {
    ///     print("\(key) \(value)")
    /// }
    /// // ...might output the following:
    /// // b 2
    /// // c 3
    /// // a 1
    /// ```
    ///
    /// - Throws: ``LuaValueError/nilValue`` if the Lua value associated with `self` is nil.
    ///           ``LuaValueError/notIterable`` if the Lua value is not a table and does not have a `__pairs` metafield.
    ///           An error (of type determined by whether a ``LuaErrorConverter`` is set) if an error is thrown during a
    ///           `__pairs` call.
    public func pairs<K, V>(type: (K.Type, V.Type)) throws -> some Sequence<(K, V)> {
        try checkValid()
        return try PairsIterator(self)
    }

    /// Calls the given closure with each array element in order.
    ///
    /// `__index` metafields are observed, if present, and any error thrown by them will be re-thrown from
    /// `for_ipairs()` as a `LuaCallError`. `block` is called with two arguments, the integer `index` of the array
    /// item, and a `LuaValue` representing the value. `block` can return `.breakIteration` to halt the iteration early,
    /// otherwise it should return `.continueIteration`. If `block` never needs to break, use a Void-returning block
    /// with ``for_ipairs(start:_:)-9ivqt`` instead.
    ///
    /// ```swift
    /// let foo = L.ref(any: [11, 22, 33])
    /// try foo.for_ipairs() { i, val in
    ///     print("Index \(i) is \(val.toint()!)")
    ///     return .continueIteration
    /// }
    /// // Prints:
    /// // Index 1 is 11
    /// // Index 2 is 22
    /// // Index 3 is 33
    /// ```
    ///
    /// - Parameter start: What table index to start iterating from. Default is `1`, ie the start of the array.
    /// - Parameter block: The code to execute on each iteration.
    /// - Throws: ``LuaValueError/nilValue`` if the Lua value associated with `self` is `nil`.
    ///           ``LuaValueError/notIndexable`` if the Lua value does not support indexing.
    ///           An error (of type determined by whether a ``LuaErrorConverter`` is set) if an error is thrown during
    ///           an `__index` call.
    public func for_ipairs(start: lua_Integer = 1, _ block: (lua_Integer, LuaValue) throws -> LuaState.IteratorResult) throws {
        try checkValid()
        push(onto: L)
        try Self.checkTopIsIndexable(L)
        defer {
            L.pop()
        }
        try L.for_ipairs(-1, start: start) { i in
            let value = L.popref()
            return try block(i, value)
        }
    }

    /// Like ``for_ipairs(start:_:)-35dov`` but without the option to break from the iteration.
    ///
    /// This function behaves like ``for_ipairs(start:_:)-35dov`` except that `block` should not return anything. This
    /// is a convenience overload allowing you to omit writing `return .continueIteration` when the block never needs
    /// to exit the iteration early by using `return .breakIteration`.
    ///
    /// ```swift
    /// let foo = L.ref(any: [11, 22, 33])
    /// try foo.for_ipairs() { i, val in
    ///     print("Index \(i) is \(val.toint()!)")
    /// }
    /// // Prints:
    /// // Index 1 is 11
    /// // Index 2 is 22
    /// // Index 3 is 33
    /// ```
    public func for_ipairs(start: lua_Integer = 1, _ block: (lua_Integer, LuaValue) throws -> Void) throws {
        return try for_ipairs(start: start, { i, value in
            try block(i, value)
            return .continueIteration
        })
    }

    public func for_ipairs<T>(start: lua_Integer = 1, type: T.Type, _ block: (lua_Integer, T) throws -> LuaState.IteratorResult) throws {
        try checkValid()
        push(onto: L)
        try Self.checkTopIsIndexable(L)
        defer {
            L.pop()
        }
        try L.for_ipairs(-1, start: start, type: T.self) { i, value in
            return try block(i, value)
        }
    }

    public func for_ipairs<T>(start: lua_Integer = 1, type: T.Type, _ block: (lua_Integer, T) throws -> Void) throws {
        try for_ipairs(start: start, type: T.self) { i, value in
            try block(i, value)
            return .continueIteration
        }
    }

    @available(*, deprecated, message: "Will be removed in v1.0.0. Use overload with block returning IteratorResult or Void instead.")
    public func for_ipairs(start: lua_Integer = 1, block: (lua_Integer, LuaValue) throws -> Bool) throws {
        return try for_ipairs(start: start, { i, value in
            return try block(i, value) ? .continueIteration : .breakIteration
        })
    }

    /// Iterate a Lua table-like value, calling `block` for each member.
    ///
    /// This function observes `__pairs` metafields if present. `block` should
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
    /// - Parameter block: The code to execute.
    /// - Throws: ``LuaValueError/nilValue`` if the Lua value associated with `self` is nil.
    ///           ``LuaValueError/notIterable`` if the Lua value is not a table and does not have a `__pairs` metafield.
    ///           An error (of type determined by whether a ``LuaErrorConverter`` is set) if an error is thrown during a
    ///           `__pairs` or iterator call.
    public func for_pairs(_ block: (LuaValue, LuaValue) throws -> LuaState.IteratorResult) throws {
        try for_pairs(type: (LuaValue.self, LuaValue.self), block)
    }

    public func for_pairs(_ block: (LuaValue, LuaValue) throws -> Void) throws {
        try for_pairs { k, v in
            try block(k, v)
            return .continueIteration
        }
    }

    public func for_pairs<K, V>(type: (K.Type, V.Type), _ block: (K, V) throws -> LuaState.IteratorResult) throws {
        try checkValid()
        push(onto: L)
        let iterable = try L.pushPairsParameters() // pops self, pushes iterfn, state, initval
        if !iterable {
            L.pop(3) // iterfn, state, initval
            throw LuaValueError.notIterable
        }

        try L.do_for_pairs() { k, v in
            if let key: K = L.tovalue(k),
               let value: V = L.tovalue(v) {
                return try block(key, value)
            } else {
                return .continueIteration
            }
        }
    }        

    public func for_pairs<K, V>(type: (K.Type, V.Type), _ block: (K, V) throws -> Void) throws {
        try for_pairs(type: (K.self, V.self)) { k, v in
            try block(k, v)
            return .continueIteration
        }
    }

    @available(*, deprecated, message: "Will be removed in v1.0.0. Use overload with block returning IteratorResult or Void instead.")
    public func for_pairs(block: (LuaValue, LuaValue) throws -> Bool) throws {
        try for_pairs { k, v in
            return try block(k, v) ? .continueIteration : .breakIteration
        }
    }

    /// Convenience function to iterate the value as an array using `for_ipairs()`.
    ///
    /// - Throws: ``LuaValueError/nilValue`` if the Lua value associated with `self` is `nil`.
    ///           ``LuaValueError/notIndexable`` if the Lua value does not support indexing.
    ///           An error (of type determined by whether a ``LuaErrorConverter`` is set) if an error is thrown during
    ///           an `__index` call.
    @available(*, deprecated, message: "Will be removed in v1.0.0. Use for_ipairs() overload with block returning Void instead.")
    public func forEach(_ block: (LuaValue) throws -> Void) throws {
        try for_ipairs() { _, value in
            try block(value)
            return true
        }
    }

    @available(*, deprecated, message: "Will be removed in v1.0.0. Use for_pairs() overload with block returning Void instead.")
    public func forEach(_ block: (LuaValue, LuaValue) throws -> Void) throws {
        try for_pairs() { key, value in
            try block(key, value)
            return true
        }
    }

    // MARK: - Comparisons

    /// Compare two values for raw equality, ie without invoking `__eq` metamethods.
    ///
    /// See [lua_rawequal](https://www.lua.org/manual/5.4/manual.html#lua_rawequal).
    ///
    /// - Parameter other: The value to compare against.
    /// - Returns: true if the two values are equal according to the definition of raw equality.
    public func rawequal(_ other: LuaValue) -> Bool {
        precondition(L.getMainThread() == other.L.getMainThread(), "Cannot compare LuaValues from different LuaStates")
        L.push(self)
        L.push(other)
        defer {
            L.pop(2)
        }
        return L.rawequal(-2, -1)
    }

    /// Compare two values for equality. May invoke `__eq` metamethods.
    ///
    /// - Parameter other: The value to compare against.
    /// - Returns: true if the two values are equal.
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if an `__eq` metamethod
    ///   errored.
    public func equal(_ other: LuaValue) throws -> Bool {
        return try compare(other, .eq)
    }

    /// Compare two values using the given comparison operator. May invoke metamethods.
    ///
    /// - Parameter other: The value to compare against.
    /// - Parameter op: The comparison operator to perform.
    /// - Returns: true if the comparison is satisfied.
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a metamethod errored.
    public func compare(_ other: LuaValue, _ op: LuaState.ComparisonOp) throws -> Bool {
        precondition(L.getMainThread() == other.L.getMainThread(), "Cannot compare LuaValues from different LuaStates")
        L.push(self)
        L.push(other)
        defer {
            L.pop(2)
        }
        return try L.compare(-2, -1, op)
    }

    /// Assuming the value is a function, dump it as a binary chunk.
    ///
    /// Dumps the function represented by this object as a binary chunk.
    ///
    /// - Parameter strip: Whether to strip debug information.
    /// - Returns: The binary chunk, or nil if the value is not a Lua function.
    public func dump(strip: Bool = false) -> [UInt8]? {
        L.push(self)
        defer {
            L.pop()
        }
        return L.dump(strip: strip)
    }
}

internal struct UnownedLuaValue {
    unowned let val: LuaValue
}
