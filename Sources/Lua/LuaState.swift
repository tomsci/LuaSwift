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

/// Provides swift wrappers for the underlying `lua_State` C APIs.
///
/// Due to `LuaState` being an `extension` to `UnsafeMutablePointer<lua_State>`
/// it can be either constructed using the explicit constructor provided, or
/// any C `lua_State` obtained from anywhere can be treated as a `LuaState`
/// Swift object.
///
/// Usage
/// =====
///
/// ```swift
/// let state = LuaState(libraries: .all)
/// state.push(1234)
/// assert(state.toint(-1)! == 1234)
/// ```
public typealias LuaState = UnsafeMutablePointer<lua_State>

public typealias lua_Integer = CLua.lua_Integer

// That this should be necessary is a sad commentary on how string encodings are handled in Swift...
public enum ExtendedStringEncoding {
    case stringEncoding(String.Encoding)
    case cfStringEncoding(CFStringEncodings)
}

public extension String {
    init?(data: Data, encoding: ExtendedStringEncoding) {
        switch encoding {
        case .stringEncoding(let enc):
            self.init(data: data, encoding: enc)
        case .cfStringEncoding(let enc):
            let nsenc =  CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(enc.rawValue))
            if let nsstring = NSString(data: data, encoding: nsenc) {
                self.init(nsstring)
            } else {
                return nil
            }
        }
    }

    func data(using encoding: ExtendedStringEncoding) -> Data? {
        switch encoding {
        case .stringEncoding(let enc):
            return self.data(using: enc)
        case .cfStringEncoding(let enc):
            let nsstring = self as NSString
            let nsenc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(enc.rawValue))
            return nsstring.data(using: nsenc)
        }
    }
}

fileprivate func moduleSearcher(_ L: LuaState!) -> CInt {
    return L.convertThrowToError {
        let pathRoot = L.tostring(lua_upvalueindex(1), encoding: .utf8)!
        let displayPrefix = L.tostring(lua_upvalueindex(2), encoding: .utf8)!
        guard let module = L.tostring(1, encoding: .utf8) else {
            L.pushnil()
            return 1
        }

        let parts = module.split(separator: ".", omittingEmptySubsequences: false)
        let relPath = parts.joined(separator: "/") + ".lua"
        let path = pathRoot + "/" + relPath

        if let data = FileManager.default.contents(atPath: path) {
            try L.load(data: data, name: "@" + displayPrefix + relPath, mode: .text)
            return 1
        } else {
            L.push("\n\tno resource '\(module)'")
            return 1
        }
    }
}

fileprivate func gcUserdata(_ L: LuaState!) -> CInt {
    let rawptr = lua_touserdata(L, 1)!
    let anyPtr = rawptr.bindMemory(to: Any.self, capacity: 1)
    anyPtr.deinitialize(count: 1)
    return 0
}

fileprivate func tracebackFn(_ L: LuaState!) -> CInt {
    let msg = L.tostring(-1)
    luaL_traceback(L, L, msg, 0)
    return 1
}

/// A Swift enum of the Lua types.
public enum LuaType : CInt {
    // Annoyingly can't use LUA_TNIL etc here because the bridge exposes them as `var LUA_TNIL: CInt { get }`
    // which is not acceptable for an enum (which requires the rawValue to be a literal)
    case nilType = 0 // LUA_TNIL
    case boolean = 1 // LUA_TBOOLEAN
    case lightuserdata = 2 // LUA_TLIGHTUSERDATA
    case number = 3 // LUA_TNUMBER
    case string = 4 // LUA_STRING
    case table = 5 // LUA_TTABLE
    case function = 6 // LUA_TFUNCTION
    case userdata = 7 // LUA_TUSERDATA
    case thread = 8 // LUA_TTHREAD
}

fileprivate var StateRegistryKey: Int = 0

public extension UnsafeMutablePointer where Pointee == lua_State {

    struct Libraries: OptionSet {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let package = Libraries(rawValue: 1)
        public static let coroutine = Libraries(rawValue: 2)
        public static let table = Libraries(rawValue: 4)
        public static let io = Libraries(rawValue: 8)
        public static let os = Libraries(rawValue: 16)
        public static let string = Libraries(rawValue: 32)
        public static let math = Libraries(rawValue: 64)
        public static let utf8 = Libraries(rawValue: 128)
        public static let debug = Libraries(rawValue: 256)

        public static let all: Libraries = [.package, .coroutine, .table, .io, .os, .string, .math, .utf8, .debug]
        public static let safe: Libraries = [.coroutine, .table, .string, .math, .utf8]
    }

    // MARK: - State management

    /// Create a new `LuaState`.
    ///
    /// Note that because `LuaState` is defined as `UnsafeMutablePointer<lua_State>`, the state is _not_ automatically
    /// destroyed when it goes out of scope. You must call `close()`.
    ///
    ///     let state = LuaState(libraries: .all)
    ///
    ///     // is equivalent to:
    ///     let state = luaL_newstate()
    ///     luaL_openlibs(state)
    ///
    /// - Parameter libraries: Which of the standard libraries to open.
    init(libraries: Libraries) {
        self = luaL_newstate()
        requiref(name: "_G", function: luaopen_base)
        openLibraries(libraries)
    }

    /// Destroy and clean up the Lua state.
    ///
    /// Must be the last function called on this `LuaState` pointer.
    func close() {
        lua_close(self)
    }

    private class _State {
        var defaultStringEncoding = ExtendedStringEncoding.stringEncoding(.utf8)
        var metatableDict = Dictionary<String, Array<Any.Type>>()
        var userdataMetatables = Set<UnsafeRawPointer>()
        var luaValues = Dictionary<CInt, UnownedLuaValue>()

        deinit {
            for (_, val) in luaValues {
                val.val.L = nil
            }
        }
    }

    private func getState() -> _State {
        if let state = maybeGetState() {
            return state
        }
        let state = _State()
        // Register a metatable for this type with a fixed name to avoid infinite recursion of getMetatableName
        // trying to call getState()
        let mtName = "LuaState._State"
        doRegisterMetatable(typeName: mtName, functions: [:])
        state.userdataMetatables.insert(lua_topointer(self, -1))
        pop() // metatable
        pushuserdata(state, metatableName: mtName)
        lua_rawsetp(self, LUA_REGISTRYINDEX, &StateRegistryKey)

        // While we're here, register ClosureWrapper
        // Are we doing too much non-deferred initialization in getState() now?
        registerMetatable(for: ClosureWrapper.self, functions: [:])

        return state
    }

    private func maybeGetState() -> _State? {
        lua_rawgetp(self, LUA_REGISTRYINDEX, &StateRegistryKey)
        var result: _State? = nil
        // We must call the unchecked version to avoid recursive loops as touserdata calls maybeGetState(). This is
        // safe because we know the value of StateRegistryKey does not need checking.
        if let state: _State = unchecked_touserdata(-1) {
            result = state
        }
        pop()
        return result
    }

    /// Override the default string encoding.
    ///
    /// See `getDefaultStringEncoding()`. If this function is not called, the default encoding is assumed to be UTF-8.
    func setDefaultStringEncoding(_ encoding: ExtendedStringEncoding) {
        getState().defaultStringEncoding = encoding
    }

    /// Get the default string encoding.
    ///
    /// This is the encoding which Lua strings are assumed to be in if an explicit encoding is not supplied when
    /// converting strings to or from Lua, for example when calling `tostring()` or `push(<string>)`. By default, it is
    /// assumed all Lua strings are (or should be) UTF-8.
    func getDefaultStringEncoding() -> ExtendedStringEncoding {
        return maybeGetState()?.defaultStringEncoding ?? .stringEncoding(.utf8)
    }

    func openLibraries(_ libraries: Libraries) {
        if libraries.contains(.package) {
            requiref(name: "package", function: luaopen_package)
        }
        if libraries.contains(.coroutine) {
            requiref(name: "coroutine", function: luaopen_coroutine)
        }
        if libraries.contains(.table) {
            requiref(name: "table", function: luaopen_table)
        }
        if libraries.contains(.io) {
            requiref(name: "io", function: luaopen_io)
        }
        if libraries.contains(.os) {
            requiref(name: "os", function: luaopen_os)
        }
        if libraries.contains(.string) {
            requiref(name: "string", function: luaopen_string)
        }
        if libraries.contains(.math) {
            requiref(name: "math", function: luaopen_math)
        }
        if libraries.contains(.utf8) {
            requiref(name: "utf8", function: luaopen_utf8)
        }
        if libraries.contains(.debug) {
            requiref(name: "debug", function: luaopen_debug)
        }
    }

    /// Configure the directory to look in when loading modules with `require`.
    ///
    /// This replaces the default system search paths, and also disables native
    /// module loading.
    ///
    /// For example `require "foo"` will look for `<path>/foo.lua`, and
    /// `require "foo.bar"` will look for `<path>/foo/bar.lua`.
    ///
    /// - Parameter path: The root directory containing .lua files
    /// - Parameter displayPrefix: Optional string to prefix onto paths shown in
    ///   for example error messages.
    /// - Precondition: The `package` standard library must have been opened.
    func setRequireRoot(_ path: String, displayPrefix: String = "") {
        let L = self
        // Now configure the require path
        guard getglobal("package") == .table else {
            fatalError("Cannot use setRequireRoot if package library not opened!")
        }

        // Set package.path even though our moduleSearcher doesn't use it
        L.push(string: path + "/?.lua", encoding: .utf8)
        lua_setfield(L, -2, "path")

        lua_getfield(L, -1, "searchers")
        L.push(string: path, encoding: .utf8)
        L.push(string: displayPrefix, encoding: .utf8)
        lua_pushcclosure(L, moduleSearcher, 2) // pops path.path
        lua_rawseti(L, -2, 2) // 2nd searcher is the .lua lookup one
        pushnil()
        lua_rawseti(L, -2, 3) // And prevent 3 from being used
        pushnil()
        lua_rawseti(L, -2, 4) // Ditto 4
        pop(2) // searchers, package
    }

    enum WhatGarbage: CInt {
        case stop = 0
        case restart = 1
        case collect = 2
    }

    private enum MoreGarbage: CInt {
        case count = 3
        case countb = 4
        case isrunning = 9
    }

    func collectgarbage(_ what: WhatGarbage = .collect) {
        lua_gc0(self, what.rawValue)
    }

    func collectorRunning() -> Bool {
        return lua_gc0(self, MoreGarbage.isrunning.rawValue) != 0
    }

    /// Returns the total amount of memory in bytes that the Lua state is using.
    func collectorCount() -> Int {
        return Int(lua_gc0(self, MoreGarbage.count.rawValue)) * 1024 + Int(lua_gc0(self, MoreGarbage.countb.rawValue))
    }

    // MARK: - Basic stack stuff

    /// Get the type of the value at the given index.
    ///
    /// - Parameter index: The stack index.
    /// - Returns: the type of the value in the given valid index, or `nil` for a non-valid but acceptable index
    /// (`nil` is the equivalent of `LUA_TNONE`).
    func type(_ index: CInt) -> LuaType? {
        let t = lua_type(self, index)
        assert(t >= LUA_TNONE && t <= LUA_TTHREAD)
        return LuaType(rawValue: t)
    }

    func typename(type: CInt) -> String {
        return String(cString: lua_typename(self, type))
    }

    func typename(index: CInt) -> String {
        return typename(type: lua_type(self, index))
    }

    func absindex(_ index: CInt) -> CInt {
        return lua_absindex(self, index)
    }

    func isnone(_ index: CInt) -> Bool {
        return type(index) == nil
    }

    func isnoneornil(_ index: CInt) -> Bool {
        if let t = type(index) {
            return t == .nilType
        } else {
            return true // ie is none
        }
    }

    func pop(_ nitems: CInt = 1) {
        // For performance Lua does check this itself, but it leads to such weird errors further down the line it's
        // worth guarding against here
        precondition(gettop() - nitems >= 0, "Attempt to pop more items from the stack than it contains")
        lua_pop(self, nitems)
    }

    func gettop() -> CInt {
        return lua_gettop(self)
    }

    func settop(_ top: CInt) {
        lua_settop(self, top)
    }

    // MARK: - to...() functions

    func toboolean(_ index: CInt) -> Bool {
        let b = lua_toboolean(self, index)
        return b != 0
    }

    func tointeger(_ index: CInt) -> lua_Integer? {
        let L = self
        var isnum: CInt = 0
        let ret = lua_tointegerx(L, index, &isnum)
        if isnum == 0 {
            return nil
        } else {
            return ret
        }
    }

    func toint(_ index: CInt) -> Int? {
        if let int = tointeger(index) {
            return Int(exactly: int)
        } else {
            return nil
        }
    }

    func tonumber(_ index: CInt) -> Double? {
        let L = self
        var isnum: CInt = 0
        let ret = lua_tonumberx(L, index, &isnum)
        if isnum == 0 {
            return nil
        } else {
            return ret
        }
    }

    /// Convert the value at the given stack index into a Swift `Data`.
    ///
    /// If the value is is not a Lua string this returns `nil`.
    ///
    /// - Parameter index: The stack index.
    /// - Returns: the value as a `Data`, or `nil` if the value was not a Lua `string`.
    func todata(_ index: CInt) -> Data? {
        let L = self
        // Check the type to avoid lua_tolstring potentially mutating a number (why does Lua still do this?)
        if type(index) == .string {
            var len: Int = 0
            let ptr = lua_tolstring(L, index, &len)!
            let buf = UnsafeBufferPointer(start: ptr, count: len)
            return Data(buffer: buf)
        } else {
            return nil
        }
    }

    /// Convert the value at the given stack index into a Swift `String`.
    ///
    /// If the value is is not a Lua string and `convert` is false, or if the
    /// string data cannot be converted to the specified encoding, this returns
    /// `nil`. If `convert` is true, `nil` will only be returned if the string
    /// failed to be decoded using `encoding`.
    ///
    /// - Parameter index: The stack index.
    /// - Parameter encoding: The encoding to use to decode the string data, or `nil` to use the default encoding.
    /// - Parameter convert: If true and the value at the given index is not a
    ///   Lua string, it will be converted to a string (invoking `__tostring`
    ///   metamethods if necessary) before being decoded.
    /// - Returns: the value as a String, or `nil` if it could not be converted.
    func tostring(_ index: CInt, encoding: ExtendedStringEncoding? = nil, convert: Bool = false) -> String? {
        let enc = encoding ?? getDefaultStringEncoding()
        if let data = todata(index) {
            return String(data: data, encoding: enc)
        } else if convert {
            var len: Int = 0
            let ptr = luaL_tolstring(self, index, &len)!
            let buf = UnsafeBufferPointer(start: ptr, count: len)
            let result = String(data: Data(buffer: buf), encoding: enc)
            pop() // the val from luaL_tolstring
            return result
        } else {
            return nil
        }
    }

    func tostring(_ index: CInt, encoding: String.Encoding, convert: Bool = false) -> String? {
        return tostring(index, encoding: .stringEncoding(encoding), convert: convert)
    }

    func tostringarray(_ index: CInt, encoding: ExtendedStringEncoding? = nil, convert: Bool = false) -> [String]? {
        guard type(index) == .table else {
            return nil
        }
        var result: [String] = []
        for _ in ipairs(index) {
            if let val = tostring(-1, encoding: encoding, convert: convert) {
                result.append(val)
            } else {
                break
            }
        }
        return result
    }

    func tostringarray(_ index: CInt, encoding: String.Encoding, convert: Bool = false) -> [String]? {
        return tostringarray(index, encoding: .stringEncoding(encoding), convert: convert)
    }

    /// Convert a value on the Lua stack to a Swift `Any`.
    ///
    /// Lua types with a one-to-one correspondence to Swift types are converted and returned `as Any`.
    ///
    /// If `guessType` is true, `table` and `string` values are automatically converted to
    /// `Array`/`Dictionary`/`String`/`Data` based on their contents:
    ///
    /// * `string` is converted to `String` if the bytes are valid in the default string encoding, otherwise to `Data`.
    /// * `table` is converted to `Dictionary<AnyHashable, Any>` if there are any non-integer keys in the table,
    ///   otherwise to `Array<Any>`.
    ///
    /// If `guessType` is `false`, the placeholder types `LuaStringRef` and `LuaTableRef` are used for `string` and
    /// `table` values respectively.
    ///
    /// Regardless of `guessType`, `LuaValue` may be used to represent values that cannot be expressed as Swift types.
    ///
    /// - Parameter index: The stack index.
    /// - Parameter guessType: Whether to automatically convert `string` and `table` values based on heuristics.
    /// - Returns: An `Any` representing the given index. Will only return `nil` if `index` refers to a `nil`
    ///   Lua value, all non-nil values will be converted to _some_ sort of `Any`.
    func toany(_ index: CInt, guessType: Bool = true) -> Any? {
        guard let t = type(index) else {
            return nil
        }
        switch (t) {
        case .nilType:
            return nil
        case .boolean:
            return toboolean(index)
        case .lightuserdata:
            return lua_topointer(self, index)
        case .number:
            if let intVal = toint(index) {
                return intVal
            } else {
                return tonumber(index)
            }
        case .string:
            let ref = LuaStringRef(L: self, index: index)
            if guessType {
                return ref.guessType()
            } else {
                return ref
            }
        case .table:
            let ref = LuaTableRef(L: self, index: index)
            if guessType {
                return ref.guessType()
            } else {
                return ref
            }
        case .function:
            if let fn = lua_tocfunction(self, index) {
                return fn
            } else {
                return ref(index: index)
            }
        case .userdata:
            return touserdata(index)
        case .thread:
            return lua_tothread(self, index)
        }
    }

    /// Attempt to convert the value at the given stack index to type `T`.
    ///
    /// The types of value that are convertible are:
    /// * `number` converts to `Int` if representable, otherwise `Double`
    /// * `boolean` converts to `Bool`
    /// * `thread` converts to `LuaState`
    /// * `string` converts to `String` or `Data` depending on which `T` is
    /// * `table` converts to either an `Array` or a `Dictionary` depending on `T`. The table contents are recursively
    ///   converted to match the type of `T`.
    /// * `userdata` any conversion that `as?` can perform on an `Any` referring to that type.
    func tovalue<T>(_ index: CInt) -> T? {
        let value = toany(index, guessType: false)
        if value == nil {
            // Explicit check for value being nil, without it if T is Any then the result ends up being some(nil)
            // because `value as? Any` succeeds in creating an Any containing a nil (which is then wrapped in an
            // optional).
            return nil
        } else if let directCast = value as? T {
            return directCast
        } else if let ref = value as? LuaStringRef {
            if T.self == String.self {
                return ref.toString() as? T
            } else /*if T.self == Data.self*/ {
                return ref.toData() as? T
            }
        } else if let ref = value as? LuaTableRef {
            return ref.resolve()
        }
        return nil
    }

    /// Convert a Lua userdata which was created with `push(userdata:)` back to a value of type `T`.
    ///
    /// - Parameter index: The stack index.
    /// - Returns: A value of type `T`, or `nil` if the value at the given stack position is not a `userdata` created
    ///   with `push(userdata:)` or it cannot be cast to `T`.
    func touserdata<T>(_ index: CInt) -> T? {
        // We don't need to check the metatable name with eg luaL_testudata because we store everything as Any
        // so the final as? check takes care of that. But we should check that the userdata has a metatable we
        // know about, to verify that it is safely convertible to an Any, and not an unrelated userdata some caller has
        // created directly with lua_newuserdatauv().
        guard lua_getmetatable(self, index) == 1 else {
            // userdata without a metatable can't be one of ours
            return nil
        }
        let mtPtr = lua_topointer(self, -1)
        pop() // metatable
        guard let mtPtr,
              let state = maybeGetState(),
              state.userdataMetatables.contains(mtPtr) else {
            // Not a userdata metatable we registered
            return nil
        }

        return unchecked_touserdata(index)
    }

    private func unchecked_touserdata<T>(_ index: CInt) -> T? {
        guard let rawptr = lua_touserdata(self, index) else {
            return nil
        }
        let typedPtr = rawptr.bindMemory(to: Any.self, capacity: 1)
        return typedPtr.pointee as? T
    }

    // MARK: - Convenience dict fns
    // assumes key is an ascii string

    func toint(_ index: CInt, key: String) -> Int? {
        return getfield(index, key: key, self.toint)
    }

    func tonumber(_ index: CInt, key: String) -> Double? {
        return getfield(index, key: key, self.tonumber)
    }

    func toboolean(_ index: CInt, key: String) -> Bool {
        return getfield(index, key: key, self.toboolean) ?? false
    }

    func todata(_ index: CInt, key: String) -> Data? {
        return getfield(index, key: key, self.todata)
    }

    func tostring(_ index: CInt, key: String, encoding: String.Encoding, convert: Bool = false) -> String? {
        return tostring(index, key: key, encoding: .stringEncoding(encoding), convert: convert)
    }

    func tostring(_ index: CInt, key: String, encoding: ExtendedStringEncoding? = nil, convert: Bool = false) -> String? {
        return getfield(index, key: key, { tostring($0, encoding: encoding, convert: convert) })
    }

    func tostringarray(_ index: CInt, key: String, encoding: ExtendedStringEncoding? = nil, convert: Bool = false) -> [String]? {
        return getfield(index, key: key, { tostringarray($0, encoding: encoding, convert: convert) })
    }

    func tostringarray(_ index: CInt, key: String, encoding: String.Encoding, convert: Bool = false) -> [String]? {
        return tostringarray(index, key: key, encoding: .stringEncoding(encoding), convert: convert)
    }

    // MARK: - Iterators

    private class IPairsRawIterator: Sequence, IteratorProtocol {
        let L: LuaState
        let index: CInt
        let top: CInt?
        var i: lua_Integer
        init(_ L: LuaState, _ index: CInt, start: lua_Integer?, resetTop: Bool) {
            self.L = L
            self.index = L.absindex(index)
            top = resetTop ? lua_gettop(L) : nil
            i = (start ?? 1) - 1
        }
        public func next() -> lua_Integer? {
            if let top {
                L.settop(top)
            }
            i = i + 1
            let t = lua_rawgeti(L, index, i)
            if t == LUA_TNIL {
                L.pop()
                return nil
            }

            return i
        }
        deinit {
            if let top {
                L.settop(top)
            }
        }
    }

    /// Return a for-iterator that iterates the array part of a table.
    ///
    /// Inside the for loop, each element will on the top of the stack and can be accessed using stack index -1. Indexes
    /// are done raw, in other words the `__index` metafield is ignored if the table has one.
    ///
    ///     // Assuming { 11, 22, 33 } is on the top of the stack
    ///     for i in L.ipairs(-1) {
    ///         print("Index \(i) is \(L.toint(-1)!)")
    ///     }
    ///     // Prints:
    ///     // Index 1 is 11
    ///     // Index 2 is 22
    ///     // Index 3 is 33
    ///
    /// - Parameter index:Stack index of the table to iterate.
    /// - Parameter start: If set, start iteration at this index rather than the
    ///   beginning of the array.
    /// - Parameter resetTop: By default, the stack top is reset on exit and
    ///   each time through the iterator to what it was at the point of calling
    ///   `ipairs`. Occasionally (such as when using `luaL_Buffer`) this is not
    ///   desirable and can be disabled by setting `resetTop` to false.
    /// - Precondition: `requiredType` must not be `.nilType`
    /// - Precondition: `index` must refer to a table value.
    func ipairs(_ index: CInt, start: lua_Integer? = nil, resetTop: Bool = true) -> some Sequence<lua_Integer> {
        precondition(type(index) == .table, "Value must be a table to iterate with ipairs()")
        return IPairsRawIterator(self, index, start: start, resetTop: resetTop)
    }

    /// Iterates a Lua array, observing `__index` metafields.
    ///
    /// Because `__index` metafields can error, and `IteratorProtocol` is not allowed to, the iteration code must be
    /// passed in as a block. The block should return `true` to continue iteration, or `false` to break.
    ///
    /// ```swift
    /// for i in L.ipairs(-1) {
    ///     // top of stack contains `rawget(value, i)`
    /// }
    ///
    /// // Compared to:
    /// try L.for_ipairs(-1) { i in
    ///     // top of stack contains `value[i]`
    ///     return true // continue iteration
    /// }
    /// ```
    ///
    /// - Parameter index: Stack index of the table to iterate.
    /// - Parameter start: If set, start iteration at this index rather than the
    ///   beginning of the array.
    /// - Parameter block: The code to execute.
    /// - Throws: `LuaCallError` if a Lua error is raised during the execution a `__index` metafield or if the value
    ///   does not support indexing.
    func for_ipairs(_ index: CInt, start: lua_Integer? = nil, _ block: (lua_Integer) throws -> Bool) throws {
        let absidx = absindex(index)
        try withoutActuallyEscaping(block) { escapingBlock in
            let wrapper = makeClosureWrapper({ L in
                var i = start ?? 1
                while true {
                    L.settop(1)
                    let t = lua_geti(L, 1, i)
                    if t == LUA_TNIL {
                        break
                    }
                    let shouldContinue = try escapingBlock(i)
                    if !shouldContinue {
                        break
                    }
                    i = i + 1
                }
                L.pushnil() // ClosureWrapper.callClosure expects a result val, bah
            })

            // Must ensure closure does not actually escape, since we cannot rely on garbage collection of the upvalue
            // of the closure, explicitly nil it in the ClosureWrapper instead
            defer {
                wrapper.closure = nil
            }

            lua_pushvalue(self, absidx) // The value being iterated is the first (and only arg) to wrapper above
            try pcall(nargs: 1, nret: 0)
        }
    }

    private class PairsRawIterator : Sequence, IteratorProtocol {
        let L: LuaState
        let index: CInt
        let top: CInt
        init(_ L: LuaState, _ index: CInt) {
            self.L = L
            self.index = L.absindex(index)
            top = lua_gettop(L)
            lua_pushnil(L) // initial k
        }
        public func next() -> (CInt, CInt)? {
            if L.gettop() < top + 1 {
                // The loop better not have messed up the stack, we rely on k staying valid
                fatalError("Iteration popped more items from the stack than it pushed")
            }
            L.settop(top + 1) // Pop everything except k
            let t = lua_next(L, index)
            if t == 0 {
                // No more items
                return nil
            }
            return (top + 1, top + 2) // k and v indexes
        }
        deinit {
            L.settop(top)
        }
    }

    /// Return a for-iterator that will iterate all the members of a table.
    ///
    /// The values in the table are iterated in an unspecified order. Each time
    /// through the for loop, the iterator returns the indexes of the key and
    /// value which are pushed onto the stack. The stack is reset each time
    /// through the loop, and on exit. The `__pairs` metafield is ignored if the
    /// table has one, that is to say raw accesses are used.
    ///
    /// ```swift
    /// // Assuming top of stack is a table { a = 1, b = 2, c = 3 }
    /// for (k, v) in L.pairs(-1) {
    ///     print("\(L.tostring(k)!) \(L.toint(v)!)")
    /// }
    /// // ...might output the following:
    /// // b 2
    /// // c 3
    /// // a 1
    /// ```
    /// 
    /// The Lua stack may be used during the loop providing the indexes `1` to `k` inclusive are not modified.
    ///
    /// - Parameter index: Stack index of the table to iterate.
    /// - Precondition: `index` must refer to a table value.
    func pairs(_ index: CInt) -> some Sequence<(CInt, CInt)> {
        precondition(type(index) == .table, "Value must be a table to iterate with pairs()")
        return PairsRawIterator(self, index)
    }

    /// Push the 3 values needed to iterate the value at the top of the stack.
    ///
    /// The value is popped from the stack.
    ///
    /// Returns: false (and pushes `next, value, nil`) if the value isn't iterable, otherwise `true`.
    @discardableResult
    func pushPairsParameters() throws -> Bool {
        let L = self
        if luaL_getmetafield(L, -1, "__pairs") == LUA_TNIL {
            let isTable = L.type(-1) == .table
            // Use next, value, nil
            L.push({ (L: LuaState!) in
                if lua_next(L, 1) == 0 {
                    return 0
                } else {
                    return 2
                }
            })
            lua_insert(L, -2) // push next below value
            L.pushnil()
            return isTable
        } else {
            lua_insert(L, -2) // Push __pairs below value
            try L.pcall(nargs: 1, nret: 3)
            return true
        }
    }

    /// Iterate a Lua table-like value, calling `block` for each member.
    ///
    /// This function observes `__pairs` metatables if present. `block` should
    /// return `true` to continue iteration, or `false` otherwise. `block` is
    /// called with the stack indexes of each key and value.
    ///
    /// ```swift
    /// for (k, v) in L.pairs(-1) {
    ///     // iterates table with raw accesses
    /// }
    ///
    /// // Compared to:
    /// try L.for_pairs(-1) { k, v in
    ///     // iterates table observing __pairs if present.
    ///     return true // continue iteration
    /// }
    /// ```
    ///
    /// - Parameter index: Stack index of the table to iterate.
    /// - Parameter block: The code to execute.
    /// - Throws: `LuaCallError` if a Lua error is raised during the execution of an iterator function or a `__pairs`
    ///   metafield, or if the value at `index` does not support indexing.
    func for_pairs(_ index: CInt, _ block: (CInt, CInt) throws -> Bool) throws {
        let absidx = absindex(index)
        try withoutActuallyEscaping(block) { escapingBlock in
            let wrapper = makeClosureWrapper({ L in
                // IMPORTANT: this closure uses unprotected lua_calls that may error. Therefore it must NOT put
                // any non-trivial type onto the stack or rely on any Swift stack cleanup happening such as
                // defer {...}.

                // Stack: 1 = iterfn, 2 = state, 3 = initval (k)
                assert(L.gettop() == 3)
                while true {
                    L.settop(3)
                    lua_pushvalue(L, 1)
                    lua_insert(L, 3) // put iterfn before k
                    lua_pushvalue(L, 2)
                    lua_insert(L, 4) // put state before k
                    // 3, 4, 5 is now iterfn copy, state copy, k
                    lua_call(L, 2, 2) // k, v = iterfn(state, k)
                    // Stack is now 1 = iterfn, 2 = state, 3 = k, 4 = v
                    if L.isnoneornil(3) {
                        break
                    }
                    let shouldContinue = try escapingBlock(3, 4)
                    if !shouldContinue {
                        break
                    }
                    // new k is in position 3 ready to go round loop again
                }
                L.settop(0)
                L.pushnil() // ClosureWrapper.callClosure expects a result val, bah
            })

            // Must ensure closure does not actually escape, since we cannot rely on prompt garbage collection of the
            // upvalue, explicitly nil it in the ClosureWrapper instead.
            defer {
                wrapper.closure = nil
            }

            lua_pushvalue(self, absidx) // The value being iterated
            try pushPairsParameters() // pops value, pushes iterfn, state, initval
            try pcall(nargs: 3, nret: 0)
        }
    }

    // MARK: - push() functions

    func pushnil() {
        lua_pushnil(self)
    }

    func push<T>(_ value: T?) where T: Pushable {
        if let value = value {
            value.push(state: self)
        } else {
            self.pushnil()
        }
    }

    func push(string: String, encoding: String.Encoding) {
        push(string: string, encoding: .stringEncoding(encoding))
    }

    func push(string: String, encoding: ExtendedStringEncoding) {
        guard let data = string.data(using: encoding) else {
            assertionFailure("Cannot represent string in the given encoding?!")
            pushnil()
            return
        }
        push(data)
    }

    func push(_ fn: lua_CFunction) {
        lua_pushcfunction(self, fn)
    }

    private class ClosureWrapper {
        var closure: Optional<(LuaState) throws -> Void>

        init(_ closure: @escaping (LuaState) throws -> Void) {
            self.closure = closure
        }

        static let callClosure: lua_CFunction = { (L: LuaState!) -> CInt in
            return L.convertThrowToError {
                // In case closure errors, make sure not to increment ref count of ClosureWrapper. We know the instance
                // will remain retained because of the upvalue, so this is safe.
                let wrapper: Unmanaged<ClosureWrapper> = .passUnretained(L.tovalue(lua_upvalueindex(1))!)
                try wrapper.takeUnretainedValue().closure!(L)
                return 1
            }
        }
    }

    /// Pushes a zero-arguments closure on to the stack as a Lua function.
    ///
    /// The Lua function when called will call the `closure`, and convert any result to a Lua value using
    /// `push(any:)`. If `closure` throws an error, it will be converted to a Lua error using
    /// `convertThrowToError(:)`.
    ///
    /// If `closure` does not return a value, the Lua function will return `nil`.
    ///
    /// ```swift
    /// L.push(closure: {
    ///     print("I am callable from Lua!")
    /// })
    /// L.push(closure: {
    ///     return "I am callable and return a result")
    /// })
    /// ```
    func push(closure: @escaping () throws -> Any?) {
        push(closureWrapper: { L in
            L.push(any: try closure())
        })
    }

    /// Pushes a one-argument closure on to the stack as a Lua function.
    ///
    /// The Lua function when called will call `closure`, converting its arguments to match the signature of `closure`,
    /// and convert any result to a Lua value using `push(any:)`. If arguments cannot be converted, a Lua error will be
    /// thrown. As with standard Lua function calls, excess arguments are discarded and any shortfall are filled in with
    /// `nil`.
    ///
    ///  If `closure` throws an error, it will be converted to a Lua error using `convertThrowToError(:)`. If
    /// `closure` does not return a value, the Lua function will return `nil`.
    ///
    /// ```swift
    /// L.push(closure: { (arg: String?) in
    ///     // ...
    /// })
    /// L.push(closure: { (arg: String?) -> Int in
    ///     // ...
    /// })
    /// ```
    /// - Note: Arguments to `closure` must all be optionals, of a type `tovalue()` can return.
    func push<Arg1>(closure: @escaping (Arg1?) throws -> Any?) {
        push(closureWrapper: { L in
            let arg1: Arg1? = try L.checkClosureArgument(index: 1)
            L.push(any: try closure(arg1))
        })
    }

    /// Pushes a two-argument closure on to the stack as a Lua function.
    ///
    /// The Lua function when called will call `closure`, converting its arguments to match the signature of `closure`,
    /// and convert any result to a Lua value using `push(any:)`. If arguments cannot be converted, a Lua error will be
    /// thrown. As with standard Lua function calls, excess arguments are discarded and any shortfall are filled in with
    /// `nil`.
    ///
    ///  If `closure` throws an error, it will be converted to a Lua error using `convertThrowToError(:)`. If
    /// `closure` does not return a value, the Lua function will return `nil`.
    ///
    /// ```swift
    /// L.push(closure: { (arg1: String?, arg2: Int?) in
    ///     // ...
    /// })
    /// L.push(closure: { (arg1: String?, arg2: Int?) -> Int in
    ///     // ...
    /// })
    /// ```
    /// - Note: Arguments to `closure` must all be optionals, of a type `tovalue()` can return.
    func push<Arg1, Arg2>(closure: @escaping (Arg1?, Arg2?) throws -> Any?) {
        push(closureWrapper: { L in
            let arg1: Arg1? = try L.checkClosureArgument(index: 1)
            let arg2: Arg2? = try L.checkClosureArgument(index: 2)
            L.push(any: try closure(arg1, arg2))
        })
    }

    /// Pushes a three-argument closure on to the stack as a Lua function.
    ///
    /// The Lua function when called will call `closure`, converting its arguments to match the signature of `closure`,
    /// and convert any result to a Lua value using `push(any:)`. If arguments cannot be converted, a Lua error will be
    /// thrown. As with standard Lua function calls, excess arguments are discarded and any shortfall are filled in with
    /// `nil`.
    ///
    ///  If `closure` throws an error, it will be converted to a Lua error using `convertThrowToError(:)`. If
    /// `closure` does not return a value, the Lua function will return `nil`.
    ///
    /// ```swift
    /// L.push(closure: { (arg1: String?, arg2: Int?, arg3: Any?) in
    ///     // ...
    /// })
    /// L.push(closure: { (arg1: String?, arg2: Int?, arg3: Any?) -> Int in
    ///     // ...
    /// })
    /// ```
    /// - Note: Arguments to `closure` must all be optionals, of a type `tovalue()` can return.
    func push<Arg1, Arg2, Arg3>(closure: @escaping (Arg1?, Arg2?, Arg3?) throws -> Any?) {
        push(closureWrapper: { L in
            let arg1: Arg1? = try L.checkClosureArgument(index: 1)
            let arg2: Arg2? = try L.checkClosureArgument(index: 2)
            let arg3: Arg3? = try L.checkClosureArgument(index: 3)
            L.push(any: try closure(arg1, arg2, arg3))
        })
    }

    /// Helper function used by implementations of `push(closure:)`.
    func push(closureWrapper: @escaping (LuaState) throws -> Void) {
        makeClosureWrapper(closureWrapper)
    }

    @discardableResult
    private func makeClosureWrapper(_ closureWrapper: @escaping (LuaState) throws -> Void) -> ClosureWrapper {
        let wrapper = ClosureWrapper(closureWrapper)
        push(userdata: wrapper)
        lua_pushcclosure(self, ClosureWrapper.callClosure, 1)
        return wrapper
    }

    /// Helper function used by implementations of `push(closure:)`.
    func checkClosureArgument<T>(index: CInt) throws -> T? {
        let val: T? = tovalue(index)
        if val == nil && !isnoneornil(index) {
            let t = typename(index: index)
            let err = "Type of argument \(index) (\(t)) does not match type required by Swift closure (\(T.self))"
            throw LuaCallError(ref(any: err))
        } else {
            return val
        }
    }

    /// Push any value representable using `Any` onto the stack as a `userdata`.
    ///
    /// From a lifetime perspective, this function behaves as if `val` were
    /// assigned to another variable of type `Any`, and when the Lua userdata is
    /// garbage collected, this variable goes out of scope.
    ///
    /// To make the object usable from Lua, declare a metatable for the type of `val` using `registerMetatable()`. Note
    /// that this function always uses the dynamic type of `val`, and not whatever `T` is, when calculating what
    /// metatable to assign the object. Thus `push(userdata: foo)` and `push(userdata: foo as Any)` will behave
    /// identically. Pushing a value of a type which has no metatable previously registered will generate a warning,
    /// and the object will have no metamethods declared on it (except for `__gc` which is always defined in order that
    /// Swift object lifetimes are preserved).
    ///
    /// - Parameter val: The value to push onto the Lua stack.
    /// - Note: This function always pushes a `userdata` - if `val` represents
    ///   any other type (for example, an integer) it will not be converted to
    ///   that type in Lua. Use `push(any:)` instead to automatically convert
    ///   types to their Lua native representation where possible.
    func push<T>(userdata: T) {
        let anyval = userdata as Any
        let tname = getMetatableName(for: Swift.type(of: anyval))
        pushuserdata(anyval, metatableName: tname)
    }

    private func pushuserdata(_ val: Any, metatableName: String) {
        let udata = lua_newuserdatauv(self, MemoryLayout<Any>.size, 0)!
        let udataPtr = udata.bindMemory(to: Any.self, capacity: 1)
        udataPtr.initialize(to: val)

        if luaL_getmetatable(self, metatableName) == LUA_TNIL {
            pop()
            if luaL_getmetatable(self, Self.DefaultMetatableName) == LUA_TTABLE {
                // The stack is now right for the lua_setmetatable call below
            } else {
                pop()
                print("Implicitly registering empty metatable for type \(metatableName)")
                doRegisterMetatable(typeName: metatableName, functions: [:])
                getState().userdataMetatables.insert(lua_topointer(self, -1))
            }
        }
        lua_setmetatable(self, -2) // pops metatable
    }

    /// Convert any Swift value to a Lua value and push on to the stack.
    ///
    /// If `value` refers to a type that can be natively represented in Lua, such as `String`, `Array`, `Dictionary`
    /// etc, then the value is converted to the native type (ie an `Int` is converted to a `number`). Array and
    /// Dictionary members are recursively converted using `push(any:)`. `Void` (ie the empty tuple) is pushed as `nil`.
    ///
    /// Note, due to limitations in Swift type inference only zero-argument closures that return `Void` or `Any?` can be
    /// pushed as Lua functions (using `push(closure:)`), any other closure will be pushed as a `userdata`.
    ///
    /// Any other type is pushed as a `userdata` using `push(userdata:)`.
    ///
    /// - Parameter value: The value to push, or nil (which is pushed as the Lua `nil` value).
    func push(any value: Any?) {
        guard let value else {
            pushnil()
            return
        }
        if value as? Void != nil {
            pushnil()
            return
        }
        switch value {
        case let pushable as Pushable:
            push(pushable)
        case let str as String: // HACK for _NSCFString not being Pushable??
            push(str)
        case let num as NSNumber: // Ditto for _NSCFNumber
            if let int = num as? Int {
                push(int)
            } else {
                // Conversion to Double cannot fail
                // Curiously the Swift compiler knows enough to know this won't fail and tells us off for using the `!`
                // in a scenario when it won't fail, but helpfully doesn't provide us with a mechanism to actually get
                // a non-optional Double. The double-parenthesis tells it we know what we're doing.
                push((num as! Double))
            }
        case let data as Data: // Presumably this is needed too for NSData...
            push(data)
        case let array as Array<Any>:
            lua_createtable(self, CInt(array.count), 0)
            for (i, val) in array.enumerated() {
                push(any: val)
                lua_rawseti(self, -2, lua_Integer(i + 1))
            }
        case let dict as Dictionary<AnyHashable, Any>:
            lua_createtable(self, 0, CInt(dict.count))
            for (k, v) in dict {
                push(any: k)
                push(any: v)
                lua_settable(self, -3)
            }
        case let closure as () throws -> ():
            push(closure: closure)
        case let closure as () throws -> (Any?):
            push(closure: closure)
        default:
            push(userdata: value)
        }
    }

    // MARK: - Calling into Lua

    /// Make a protected call to a Lua function.
    ///
    /// The function and any arguments must already be pushed to the stack in the same way as for
    /// [`lua_pcall()`](https://www.lua.org/manual/5.4/manual.html#lua_pcall)
    /// and are popped from the stack by this call. Unless the function errors,
    /// `nret` result values are then pushed to the stack.
    ///
    /// - Parameter nargs: The number of arguments to pass to the function.
    /// - Parameter nret: The number of expected results. Can be `LUA_MULTRET`
    ///   to keep all returned values.
    /// - Parameter traceback: If true, any errors thrown will include a
    ///   full stack trace.
    /// - Throws: `LuaCallError` if a Lua error is raised during the execution
    ///   of the function.
    /// - Precondition: The top of the stack must contain a function and `nargs`
    ///   arguments.
    func pcall(nargs: CInt, nret: CInt, traceback: Bool = true) throws {
        let index: CInt
        if traceback {
            index = gettop() - nargs
            lua_pushcfunction(self, tracebackFn)
            lua_insert(self, index) // Move traceback before nargs and fn
        } else {
            index = 0
        }
        let err = lua_pcall(self, nargs, nret, index)
        if traceback {
            // Keep the stack balanced
            lua_remove(self, index)
        }
        if err != LUA_OK {
            let errRef = popref()
            // print(errRef.tostring(convert: true)!)
            throw LuaCallError(errRef)
        }
    }

    /// Convenience zero-result wrapper around `pcall(nargs:nret:traceback)`
    ///
    /// Make a protected call to a Lua function that must already be pushed
    /// onto the stack. Each of `arguments` is pushed using `push(any:)`. The
    /// function is popped from the stack and any results are discarded.
    ///
    /// - Parameter arguments: Arguments to pass to the Lua function.
    /// - Parameter traceback: If true, any errors thrown will include a
    ///   full stack trace.
    /// - Throws: `LuaCallError` if a Lua error is raised during the execution
    ///   of the function.
    /// - Precondition: The value at the top of the stack must refer to a Lua
    ///   function or callable.
    func pcall(_ arguments: Any?..., traceback: Bool = true) throws {
        try pcall(arguments: arguments, traceback: traceback)
    }

    func pcall(arguments: [Any?], traceback: Bool = true) throws {
        for arg in arguments {
            push(any: arg)
        }
        try pcall(nargs: CInt(arguments.count), nret: 0, traceback: traceback)
    }

    /// Convenience one-result wrapper around `pcall(nargs:nret:traceback)`
    ///
    /// Make a protected call to a Lua function that must already be pushed
    /// onto the stack. Each of `arguments` is pushed using `push(any:)`. The
    /// function is popped from the stack. All results are popped from the stack
    /// and the first one is converted to `T` using `tovalue<T>()`. `nil` is
    /// returned if the result could not be converted to `T`.
    ///
    /// - Parameter arguments: Arguments to pass to the Lua function.
    /// - Parameter traceback: If true, any errors thrown will include a
    ///   full stack trace.
    /// - Returns: The first result of the function, converted if possible to a
    ///   `T`.
    /// - Throws: `LuaCallError` if a Lua error is raised during the execution
    ///   of the function.
    /// - Precondition: The value at the top of the stack must refer to a Lua
    ///   function or callable.
    func pcall<T>(_ arguments: Any?..., traceback: Bool = true) throws -> T? {
        return try pcall(arguments: arguments, traceback: traceback)
    }

    func pcall<T>(arguments: [Any?], traceback: Bool = true) throws -> T? {
        for arg in arguments {
            push(any: arg)
        }
        try pcall(nargs: CInt(arguments.count), nret: 1, traceback: traceback)
        let result: T? = tovalue(-1)
        pop(1)
        return result
    }

    // MARK: - Registering metatables

    private func getMetatableName(for type: Any.Type) -> String {
        let prefix = "SwiftType_" + String(describing: type)
        let state = getState()
        if state.metatableDict[prefix] == nil {
            state.metatableDict[prefix] = []
        }
        var index = state.metatableDict[prefix]!.firstIndex(where: { $0 == type })
        if index == nil {
            state.metatableDict[prefix]!.append(type)
            index = state.metatableDict[prefix]!.count - 1
        }
        return index! == 0 ? prefix : "\(prefix)[\(index!)]"
    }

    private func doRegisterMetatable(typeName: String, functions: [String: lua_CFunction]) {
        precondition(functions["__gc"] == nil, "__gc function for Swift userdata types is registered automatically")
        if luaL_newmetatable(self, typeName) == 0 {
            fatalError("Metatable for type \(typeName) is already registered!")
        }

        for (name, fn) in functions {
            lua_pushcfunction(self, fn)
            lua_setfield(self, -2, name)
        }

        if functions["__index"] == nil {
            lua_pushvalue(self, -1)
            lua_setfield(self, -2, "__index")
        }

        lua_pushcfunction(self, gcUserdata)
        lua_setfield(self, -2, "__gc")
    }

    private static let DefaultMetatableName = "SwiftType_Any"

    /// Register a metatable for values of type `T` when they are pushed using
    /// `push(userdata:)` or `push(any:)`. Note, attempting to register a
    /// metatable for types that are bridged to Lua types (such as `Integer,`
    /// or `String`), will not work with values pushed with `push(any:)` - if
    /// you really need to do that, they must always be pushed with
    /// `push(userdata:)` (at which point they cannot be used as normal Lua
    /// numbers/strings/etc).
    ///
    /// For example, to make a type `Foo` callable:
    ///
    ///     L.registerMetatable(for: Foo.self, functions: [
    ///         "__call": : { L in
    ///            print("TODO call support")
    ///            return 0
    ///        }
    ///     ])
    ///
    /// Do not specify a `_gc` in `functions`, this is created automatically. If `__index` is not specified, one is
    /// created which refers to the metatable, thus additional items in `functions` are accessible Lua-side:
    ///
    ///     L.registerMetatable(for: Foo.self, functions: [
    ///         "bar": : { L in
    ///             print("This is a call to bar()!")
    ///             return 0
    ///         }
    ///     ])
    ///     // Means you can do foo.bar()
    ///
    /// - Parameter type: Type to register.
    /// - Parameter functions: Map of functions.
    /// - Precondition: There must not already be a metatable defined for `type`.
    func registerMetatable<T>(for type: T.Type, functions: [String: lua_CFunction]) {
        doRegisterMetatable(typeName: getMetatableName(for: type), functions: functions)
        getState().userdataMetatables.insert(lua_topointer(self, -1))
        pop() // metatable
    }

    /// Register a metatable to be used for all values which have not had an
    /// explicit call to `registerMetatable`.
    ///
    /// - Parameter functions: map of functions
    func registerDefaultMetatable(functions: [String: lua_CFunction]) {
        doRegisterMetatable(typeName: Self.DefaultMetatableName, functions: functions)
        getState().userdataMetatables.insert(lua_topointer(self, -1))
        pop() // metatable
    }

    // MARK: - Misc functions

    func getfield<T>(_ index: CInt, key: String, _ accessor: (CInt) -> T?) -> T? {
        let absidx = absindex(index)
        let t = self.type(absidx)
        if t != .table && t != .userdata {
            return nil // Prevent lua_gettable erroring
        }
        push(string: key, encoding: .ascii)
        let _ = lua_gettable(self, absidx)
        let result = accessor(-1)
        pop()
        return result
    }

    /// Sets a key on the table on the top of the stack.
    ///
    /// Does not invoke metamethods, thus will not error.
    ///
    /// - Precondition: The value on the top of the stack must be a table.
    func setfield<S, T>(_ key: S, _ value: T) where S: Pushable, T: Pushable {
        precondition(type(-1) == .table, "Cannot call setfield on something that isn't a table")
        self.push(key)
        self.push(value)
        lua_rawset(self, -3)
    }

    @discardableResult
    func getglobal(_ name: UnsafePointer<CChar>) -> LuaType {
        return LuaType(rawValue: lua_getglobal(self, name))!
    }

    /// Pushes the globals table (`_G`) onto the stack.
    func pushGlobals() {
        lua_pushglobaltable(self)
    }

    /// Wrapper around [`luaL_requiref()`](https://www.lua.org/manual/5.4/manual.html#luaL_requiref).
    ///
    /// Pops the module from the stack.
    func requiref(name: UnsafePointer<CChar>!, function: lua_CFunction, global: Bool = true) {
        luaL_requiref(self, name, function, global ? 1 : 0)
        pop()
    }

    /// Wrapper around [`luaL_setfuncs()`](https://www.lua.org/manual/5.4/manual.html#luaL_setfuncs).
    func setfuncs(_ fns: [String: lua_CFunction], nup: CInt = 0) {
        precondition(nup >= 0)
        // It's easier to just do what luaL_setfuncs does rather than massage
        // fns in to a format that would work with it
        for (name, fn) in fns {
            for _ in 0 ..< nup {
                // copy upvalues to the top
                lua_pushvalue(self, -nup)
            }
            lua_pushcclosure(self, fn, nup)
            lua_setfield(self, -(nup + 2), name)
        }
        if nup > 0 {
            pop(nup)
        }
    }

    /// Call `block` wrapped in a `do { ... } catch {}` and convert any Swift
    /// errors into a `lua_error()` call.
    ///
    /// This function special-cases ``LuaCallError`` and `LuaLoadError.parseError` and passes through the original
    /// underlying Lua error value unmodified. Otherwise `"Swift error: \(error.localizedDescription)"` is used.
    ///
    /// - Note: Is is important not to leave anything on the stack outside of `block` when calling this function,
    ///  because Lua errors do not unwind the stack. Therefore the normal way to use this function is to make it the
    ///  only call in a `lua_CFunction`:
    ///
    /// ```swift
    ///     func myNativeFn(_ L: LuaState!) -> CInt {
    ///         return L.convertThrowToError {
    ///             // Things that can throw
    ///             // ...
    ///         }
    ///     }
    /// ```
    ///
    /// - Returns: The result of `block` if there was no error. On error,
    ///   converts the error to a string then calls `lua_error()` (and therefore
    ///   does not return).
    func convertThrowToError(_ block: () throws -> CInt) -> CInt {
        do {
            return try block()
        } catch let error as LuaCallError {
            push(error.error)
        } catch LuaLoadError.parseError(let str) {
            push(str)
        } catch {
            push("Swift error: \(error.localizedDescription)")
        }

        // If we got here, we errored.

        // Be careful not to leave a String (or anything else) in the stack frame here, because it won't get cleaned up,
        // hence why we push the string in the catch block above.
        self.lua_error()
    }

    /// Wrapper around `lua_error(lua_State *L)` which adds the noreturn `Never` annotation.
    func lua_error() -> Never {
        CLua.lua_error(self)
        fatalError() // Not reached
    }

    /// Convert a Lua value on the stack into a Swift object of type `LuaValue`. Does not pop the value from the stack.
    ///
    /// - Parameter index: The stack index of the value.
    /// - Returns: A `LuaValue` representing the value at the given stack index.
    func ref(index: CInt) -> LuaValue {
        let result = LuaValue(L: self, index: index)
        if result.type != .nilType {
            getState().luaValues[result.ref] = UnownedLuaValue(val: result)
        }
        return result
    }

    /// Convert any Swift value to a `LuaValue`.
    ///
    /// Equivalent to:
    ///
    /// ```swift
    /// L.push(any: val)
    /// return L.popref()
    /// ```
    ///
    /// - Parameter any: The value to convert
    /// - Returns: A `LuaValue` representing the specified value.
    func ref(any: Any?) -> LuaValue {
        push(any: any)
        return popref()
    }

    /// Convert the value on the top of the Lua stack into a Swift object of type `LuaValue` and pops it.
    ///
    /// - Returns: A `LuaValue` representing the value on the top of the stack.
    func popref() -> LuaValue {
        let result = ref(index: -1)
        pop()
        return result
    }

    /// Returns a `LuaValue` representing the global environment.
    ///
    /// Equivalent to (but more efficient than):
    ///
    ///     L.pushGlobals()
    ///     let globals = L.ref(-1)
    ///     L.pop()
    ///
    /// For example:
    ///
    ///     try L.globals["print"].pcall("Hello world!")
    var globals: LuaValue {
        // Note, LUA_RIDX_GLOBALS doesn't need to be freed so doesn't need to be added to luaValues
        return LuaValue(L: self, ref: LUA_RIDX_GLOBALS, type: .table)
    }

    // MARK: - Loading code

    enum LoadMode: String {
        case text = "t"
        case binary = "b"
        case either = "bt"
    }

    /// Load a Lua chunk from a file, without executing it.
    ///
    /// On return, the function representing the file is left on the top of the stack.
    ///
    /// - Parameter file: Path to a Lua text or binary file.
    /// - Parameter mode: Whether to only allow text files, compiled binary chunks, or either.
    /// - Throws: `LuaLoadError.fileNotFound` if `file` cannot be opened.
    /// - Throws: `LuaLoadError.parseError` if the file cannot be parsed.
    func load(file path: String, mode: LoadMode = .text) throws {
        let err = luaL_loadfilex(self, FileManager.default.fileSystemRepresentation(withPath: path), mode.rawValue)
        if err == LUA_ERRFILE {
            throw LuaLoadError.fileNotFound
        } else if err == LUA_ERRSYNTAX {
            let errStr = tostring(-1)!
            pop()
            throw LuaLoadError.parseError(errStr)
        } else if err != LUA_OK {
            fatalError("Unexpected error from luaL_loadfilex")
        }
    }

    /// Load a Lua chunk from memory, without executing it.
    ///
    /// On return, the function representing the file is left on the top of the stack.
    ///
    /// - Parameter data: The data to load.
    /// - Parameter name: The name of the chunk, for use in stacktraces. Optional.
    /// - Parameter mode: Whether to only allow text, compiled binary chunks, or either.
    /// - Throws: `LuaLoadError.parseError` if the data cannot be parsed.
    func load(data: Data, name: String?, mode: LoadMode = .text) throws {
        var err: CInt = 0
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Void in
            let chars = ptr.bindMemory(to: CChar.self)
            err = luaL_loadbufferx(self, chars.baseAddress, chars.count, name, mode.rawValue)
        }
        if err == LUA_ERRSYNTAX {
            let errStr = tostring(-1)!
            pop()
            throw LuaLoadError.parseError(errStr)
        } else if err != LUA_OK {
            fatalError("Unexpected error from luaL_loadbufferx")
        }
    }

    /// Load a Lua chunk from memory, without executing it.
    ///
    /// On return, the function representing the file is left on the top of the stack.
    ///
    /// - Parameter data: The data to load.
    /// - Throws: `LuaLoadError.parseError` if the data cannot be parsed.
    func load(string: String, name: String? = nil) throws {
        try load(data: string.data(using: .utf8)!, name: name, mode: .text)
    }

    /// Load a Lua chunk from file with `load(file:mode:)` and execute it.
    ///
    /// Any values returned from the file are left on the top of the stack.
    ///
    /// - Parameter file: Path to a Lua text or binary file.
    /// - Parameter mode: Whether to only allow text files, compiled binary chunks, or either.
    /// - Throws: `LuaLoadError.fileNotFound` if `file` cannot be opened.
    /// - Throws: `LuaLoadError.parseError` if the file cannot be parsed.
    func dofile(_ path: String, mode: LoadMode = .text) throws {
        try load(file: path, mode: mode)
        try pcall(nargs: 0, nret: LUA_MULTRET)
    }
}

// package internal (but not private) API
extension UnsafeMutablePointer where Pointee == lua_State {
    func unref(_ ref: CInt) {
        getState().luaValues[ref] = nil
        luaL_unref(self, LUA_REGISTRYINDEX, ref)
    }
}
