// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

#if !LUASWIFT_NO_FOUNDATION
import Foundation
#endif
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

fileprivate func moduleSearcher(_ L: LuaState!) -> CInt {
    return L.convertThrowToError {
        let pathRoot = L.tostringUtf8(lua_upvalueindex(1))!
        let displayPrefix = L.tostringUtf8(lua_upvalueindex(2))!
        guard let module = L.tostringUtf8(1) else {
            L.pushnil()
            return 1
        }

        let parts = module.split(separator: ".", omittingEmptySubsequences: false)
        let relPath = parts.joined(separator: "/") + ".lua"
        let path = pathRoot + "/" + relPath
        let displayPath = displayPrefix == "" ? relPath : displayPrefix + "/" + relPath

        do {
            try L.load(file: path, displayPath: displayPath, mode: .text)
            return 1
        } catch LuaLoadError.fileNotFound {
            L.push("no file '\(displayPath)'")
            return 1
        } // Otherwise throw
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

/// A class which wraps a Swift closure of type `LuaState -> CInt` and can be pushed as a Lua function.
///
/// Normally you would call one of the `L.push(closure:)` overloads rather than using this class directly. It should
/// only ever be pushed onto the Lua stack using the `Pushable` overload, eg `L.push(closureWrapper)` (or
/// `closureWrapper.push(L)`) and not with `push(userdata:)` - it will not be callable when pushed as a `userdata`.
public class ClosureWrapper: Pushable {
    var closure: Optional<(LuaState) throws -> CInt>

    public init(_ closure: @escaping (LuaState) throws -> CInt) {
        self.closure = closure
    }

    private static let callClosure: lua_CFunction = { (L: LuaState!) -> CInt in
        return L.convertThrowToError {
            // In case closure errors, make sure not to increment ref count of ClosureWrapper. We know the instance
            // will remain retained because of the upvalue, so this is safe.
            let wrapper: Unmanaged<ClosureWrapper> = .passUnretained(L.tovalue(lua_upvalueindex(1))!)
            guard let closure = wrapper.takeUnretainedValue().closure else {
                fatalError("Attempt to call a ClosureWrapper after it has been explicitly nilled")
            }
            return try closure(L)
        }
    }

    public func push(state L: LuaState) {
        L.push(userdata: self)
        lua_pushcclosure(L, Self.callClosure, 1)
    }
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
        requiref_unsafe(name: "_G", function: luaopen_base)
        openLibraries(libraries)
    }

    /// Destroy and clean up the Lua state.
    ///
    /// Must be the last function called on this `LuaState` pointer.
    func close() {
        lua_close(self)
    }

    func openLibraries(_ libraries: Libraries) {
        if libraries.contains(.package) {
            requiref_unsafe(name: "package", function: luaopen_package)
        }
        if libraries.contains(.coroutine) {
            requiref_unsafe(name: "coroutine", function: luaopen_coroutine)
        }
        if libraries.contains(.table) {
            requiref_unsafe(name: "table", function: luaopen_table)
        }
        if libraries.contains(.io) {
            requiref_unsafe(name: "io", function: luaopen_io)
        }
        if libraries.contains(.os) {
            requiref_unsafe(name: "os", function: luaopen_os)
        }
        if libraries.contains(.string) {
            requiref_unsafe(name: "string", function: luaopen_string)
        }
        if libraries.contains(.math) {
            requiref_unsafe(name: "math", function: luaopen_math)
        }
        if libraries.contains(.utf8) {
            requiref_unsafe(name: "utf8", function: luaopen_utf8)
        }
        if libraries.contains(.debug) {
            requiref_unsafe(name: "debug", function: luaopen_debug)
        }
    }

    /// Configure the directory to look in when loading modules with `require`.
    ///
    /// This replaces the default system search paths, and also disables native module loading.
    ///
    /// For example `require "foo"` will look for `<path>/foo.lua`, and `require "foo.bar"` will look for
    /// `<path>/foo/bar.lua`.
    ///
    /// - Parameter path: The root directory containing .lua files. Specify `nil` to disable all module loading (except
    ///   for any preloads configured with `addModules()`).
    /// - Parameter displayPath: What to display in stacktraces instead of showing the full `path`. The default `""`
    ///   means stacktraces will contain just the Lua module names. Pass in `path` or `nil` to show the unmodified real
    ///   path.
    /// - Precondition: The `package` standard library must have been opened.
    func setRequireRoot(_ path: String?, displayPath: String? = "") {
        let L = self
        // Now configure the require path
        guard getglobal("package") == .table else {
            fatalError("Cannot use setRequireRoot if package library not opened!")
        }

        // Set package.path even though our moduleSearcher doesn't use it
        if let path {
            L.push(utf8String: path + "/?.lua")
        } else {
            L.pushnil()
        }
        L.rawset(-2, utf8Key: "path")

        L.rawget(-1, utf8Key: "searchers")
        if let path {
            L.push(utf8String: path)
            L.push(utf8String: displayPath ?? path)
            lua_pushcclosure(L, moduleSearcher, 2) // pops path, displayPath
        } else {
            pushnil()
        }
        L.rawset(-2, key: 2) // 2nd searcher is the .lua lookup one
        pushnil()
        L.rawset(-2, key: 3) // And prevent 3 from being used
        pushnil()
        L.rawset(-2, key: 4) // Ditto 4
        pop(2) // searchers, package
    }

    /// Add built-in modules to the [preload](https://www.lua.org/manual/5.4/manual.html#pdf-package.preload) table.
    ///
    /// Such that they can loaded by `require(name)`. The modules are not loaded until `require` is called.
    ///
    /// - Parameter modules: A dictionary of module names to data suitable to be passed to `load(data:)`.
    /// - Parameter mode: The `LoadMode` to be used when loading any of the modules in `modules`.
    func addModules(_ modules: [String: [UInt8]], mode: LoadMode = .binary) {
        luaL_getsubtable(self, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE)
        for (name, data) in modules {
            push(ClosureWrapper({ L in
                let filename = name.replacingOccurrences(of: ".", with: "/")
                try L.load(data: data, name: "@\(filename).lua", mode: mode)
                L.push(name)
                try L.pcall(nargs: 1, nret: 1)
                return 1
            }))
            lua_setfield(self, -2, name)
        }
        pop() // preload table
    }

    /// Add built-in modules to the [preload](https://www.lua.org/manual/5.4/manual.html#pdf-package.preload) table,
    /// removing any others.
    ///
    /// Such that they can loaded by `require(name)`. The modules are not loaded until `require` is called. Any modules
    /// previously in the preload table are removed. Note this will have no effect on modules that have already been
    /// loaded.
    ///
    /// - Parameter modules: A dictionary of module names to data suitable to be passed to `load(data:)`.
    /// - Parameter mode: The `LoadMode` to be used when loading any of the modules in `modules`.
    func setModules(_ modules: [String: [UInt8]], mode: LoadMode = .binary) {
        luaL_getsubtable(self, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE)
        for (_, _) in pairs(-1) {
            pop() // Remove v
            pushnil()
            lua_settable(self, -3)
        }
        pop() // preload table
        addModules(modules, mode: mode)
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

    /// See [lua_isnone](https://www.lua.org/manual/5.4/manual.html#lua_isnone).
    func isnone(_ index: CInt) -> Bool {
        return type(index) == nil
    }

    /// See [lua_isnoneornil](https://www.lua.org/manual/5.4/manual.html#lua_isnoneornil).
    func isnoneornil(_ index: CInt) -> Bool {
        if let t = type(index) {
            return t == .nilType
        } else {
            return true // ie is none
        }
    }

    func pop(_ nitems: CInt = 1) {
        // For performance Lua doesn't check this itself, but it leads to such weird errors further down the line it's
        // worth trying to catch here.
        precondition(gettop() - nitems >= 0, "Attempt to pop more items from the stack than it contains")
        lua_pop(self, nitems)
    }

    /// See [lua_gettop](https://www.lua.org/manual/5.4/manual.html#lua_gettop).
    func gettop() -> CInt {
        return lua_gettop(self)
    }

    /// See [lua_settop](https://www.lua.org/manual/5.4/manual.html#lua_settop).
    func settop(_ top: CInt) {
        lua_settop(self, top)
    }

    /// See [lua_checkstack](https://www.lua.org/manual/5.4/manual.html#lua_checkstack).
    func checkstack(_ n: CInt) {
        if (lua_checkstack(self, n) == 0) {
            // This isn't really recoverable
            fatalError("lua_checkstack failed!")
        }
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

    /// Convert the value at the given stack index into raw bytes.
    ///
    /// If the value is is not a Lua string this returns `nil`.
    ///
    /// - Parameter index: The stack index.
    /// - Returns: the value as a `UInt8` array, or `nil` if the value was not a Lua `string`.
    func todata(_ index: CInt) -> [UInt8]? {
        // Check the type to avoid lua_tolstring potentially mutating a number (why does Lua still do this?)
        if type(index) == .string {
            var len: Int = 0
            let charptr = lua_tolstring(self, index, &len)!
            let lstrbuf = UnsafeBufferPointer(start: charptr, count: len)
            return lstrbuf.withMemoryRebound(to: UInt8.self) { stringBuffer in
                return Array<UInt8>(unsafeUninitializedCapacity: len) { arrayBuffer, initializedCount in
                    let _ = arrayBuffer.initialize(fromContentsOf: stringBuffer)
                    initializedCount = len
                }
            }
        } else {
            return nil
        }
    }

#if LUASWIFT_NO_FOUNDATION
    /// Convert the value at the given stack index into a Swift `String`.
    ///
    /// If the value is is not a Lua string and `convert` is `false`, or if the string data cannot be converted to
    /// UTF-8, this returns `nil`. If `convert` is true, `nil` will only be returned if the string failed to
    /// parse as UTF-8.
    ///
    /// - Parameter index: The stack index.
    /// - Parameter convert: If true and the value at the given index is not a Lua string, it will be converted to a
    ///   string (invoking `__tostring` metamethods if necessary) before being decoded. If a metamethod errors, returns
    ///   `nil`.
    /// - Returns: The value as a `String`, or `nil` if it could not be converted.
    func tostring(_ index: CInt, convert: Bool = false) -> String? {
        if var data = todata(index) {
            data.append(0) // Must be null terminated for String(utf8String:)
            return data.withUnsafeBufferPointer { buf in
                return buf.withMemoryRebound(to: CChar.self) { ccharbuf in
                    return String(utf8String: ccharbuf.baseAddress!)
                }
            }
        } else if convert {
            push({ L in
                var len: Int = 0
                let ptr = luaL_tolstring(L, 1, &len)
                lua_pushlstring(L, ptr, len)
                return 1
            })
            push(index: index)
            do {
                try pcall(nargs: 1, nret: 1)
            } catch {
                return nil
            }
            defer {
                pop()
            }
            return tostring(-1, convert: false)
        } else {
            return nil
        }
    }
#endif

    /// Convert a Lua value to a UTF-8 string.
    ///
    /// - Note: If `LUASWIFT_NO_FOUNDATION` is defined, this function behaves identically to `tostring()`.
    ///
    /// - Parameter index: The stack index.
    /// - Parameter convert: If true and the value at the given index is not a Lua string, it will be converted to a
    ///   string (invoking `__tostring` metamethods if necessary) before being decoded. If a metamethod errors, returns
    ///   `nil`.
    /// - Returns: The value as a `String`, or `nil` if it could not be converted.
    func tostringUtf8(_ index: CInt, convert: Bool = false) -> String? {
#if LUASWIFT_NO_FOUNDATION
        return tostring(index, convert: convert)
#else
        return tostring(index, encoding: .utf8, convert: convert)
#endif
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

    /// Convert a value on the stack to the specified `Decodable` type.
    ///
    /// If `T` is a composite struct or class type, the Lua representation must be a table with members corresponding
    /// to the Swift member names. Userdata values, or tables containing userdatas, are not convertible using this
    /// function - use `touserdata()` ot `tovalue()` instead.
    ///
    /// - Parameter index: The stack index.
    /// - Parameter type: The `Decodable` type to convert to.
    /// - Returns: A value of type `T`, or `nil` if the value at the given stack position cannot be decoded to `T`.
    func todecodable<T: Decodable>(_ index: Int32, _ type: T.Type) -> T? {
        let top = gettop()
        defer {
            settop(top)
        }
        let decoder = LuaDecoder(state: self, index: index, codingPath: [])
        return try? decoder.decode(T.self)
    }

    func todecodable<T: Decodable>(_ index: Int32) -> T? {
        return todecodable(index, T.self)
    }

    // MARK: - Convenience dict fns

    func toint(_ index: CInt, key: String) -> Int? {
        return get(index, key: key, self.toint)
    }

    func tonumber(_ index: CInt, key: String) -> Double? {
        return get(index, key: key, self.tonumber)
    }

    func toboolean(_ index: CInt, key: String) -> Bool {
        return get(index, key: key, self.toboolean) ?? false
    }

    func todata(_ index: CInt, key: String) -> [UInt8]? {
        return get(index, key: key, self.todata)
    }

    func tostring(_ index: CInt, key: String, convert: Bool = false) -> String? {
        return get(index, key: key, { tostring($0, convert: convert) })
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
            let wrapper = ClosureWrapper({ L in
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
                return 0
            })

            // Must ensure closure does not actually escape, since we cannot rely on garbage collection of the upvalue
            // of the closure, explicitly nil it in the ClosureWrapper instead
            defer {
                wrapper.closure = nil
            }

            push(wrapper)
            push(index: absidx) // The value being iterated is the first (and only arg) to wrapper above
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
    /// The indexes to the key and value will always be `top+1` and `top+2`, where `top` is the value of `gettop()`
    /// prior to the call to `pairs()`, thus are provided for convenience only. `-2` and `-1` can be used instead, if
    /// desired.
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
    /// Throws: ``LuaCallError`` if the value had a `__pairs` metafield which errored.
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
        push(index: index) // The value being iterated
        try pushPairsParameters() // pops value, pushes iterfn, state, initval
        try do_for_pairs(block)
    }

    // MARK: - push() functions

    func pushnil() {
        lua_pushnil(self)
    }

    /// Pushes a copy of the element at the given index onto the top of the stack.
    ///
    /// - Parameter index: Stack index of the value to copy.
    func push(index: CInt) {
        lua_pushvalue(self, index)
    }

    func push<T>(_ value: T?) where T: Pushable {
        if let value = value {
            value.push(state: self)
        } else {
            self.pushnil()
        }
    }

    func push(string: String) {
#if LUASWIFT_NO_FOUNDATION
        let data = Array<UInt8>(string.utf8)
        push(data)
#else
        push(string: string, encoding: getDefaultStringEncoding())
#endif
    }

    func push(utf8String string: String) {
#if LUASWIFT_NO_FOUNDATION
        push(string: string)
#else
        push(string: string, encoding: .utf8)
#endif
    }

    func push(_ data: [UInt8]) {
        data.withUnsafeBytes { rawBuf in
            rawBuf.withMemoryRebound(to: CChar.self) { charBuf -> Void in
                lua_pushlstring(self, charBuf.baseAddress, charBuf.count)
            }
        }
    }

    func push(_ fn: lua_CFunction) {
        lua_pushcfunction(self, fn)
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
        push(ClosureWrapper({ L in
            L.push(any: try closure())
            return 1
        }))
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
        push(ClosureWrapper({ L in
            let arg1: Arg1? = try L.checkClosureArgument(index: 1)
            L.push(any: try closure(arg1))
            return 1
        }))
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
        push(ClosureWrapper({ L in
            let arg1: Arg1? = try L.checkClosureArgument(index: 1)
            let arg2: Arg2? = try L.checkClosureArgument(index: 2)
            L.push(any: try closure(arg1, arg2))
            return 1
        }))
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
        push(ClosureWrapper({ L in
            let arg1: Arg1? = try L.checkClosureArgument(index: 1)
            let arg2: Arg2? = try L.checkClosureArgument(index: 2)
            let arg3: Arg3? = try L.checkClosureArgument(index: 3)
            L.push(any: try closure(arg1, arg2, arg3))
            return 1
        }))
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
    /// pushed as Lua functions (using `push(closure:)`). `lua_CFunction` is pushed directly as a function. Any other
    /// closure will be pushed as a `userdata`.
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
#if !LUASWIFT_NO_FOUNDATION
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
        case let data as ContiguousBytes:
            push(bytes: data)
#endif
        case let data as [UInt8]:
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
        case let function as lua_CFunction:
            push(function)
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

    enum MetafieldType {
        case function(lua_CFunction)
        case closure((LuaState) throws -> CInt)
    }

    private func doRegisterMetatable(typeName: String, functions: [String: MetafieldType]) {
        precondition(functions["__gc"] == nil, "__gc function for Swift userdata types is registered automatically")
        if luaL_newmetatable(self, typeName) == 0 {
            fatalError("Metatable for type \(typeName) is already registered!")
        }

        for (name, function) in functions {
            switch function {
            case let .function(cfunction):
                push(cfunction)
            case let .closure(closure):
                push(ClosureWrapper(closure))
            }
            rawset(-2, utf8Key: name)
        }

        if functions["__index"] == nil {
            push(index: -1)
            rawset(-2, utf8Key: "__index")
        }

        push(gcUserdata)
        rawset(-2, utf8Key: "__gc")
    }

    private static let DefaultMetatableName = "SwiftType_Any"

    /// Register a metatable for values of type `T`.
    ///
    /// For when they are pushed using `push(userdata:)` or `push(any:)`. Note, attempting to register a metatable for
    /// types that are bridged to Lua types (such as `Integer,` or `String`), will not work with values pushed with
    /// `push(any:)` - if you really need to do that, they must always be pushed with `push(userdata:)` (at which point
    /// they cannot be used as normal Lua numbers/strings/etc).
    ///
    /// Use `.function` to specify a `lua_CFunction` directly. You can use a Swift closure in lieu of a `lua_CFunction`
    /// pointer providing it does not capture any variables and has the right signature, for example
    /// `.function { (L: LuaState!) -> CInt in ... }`.
    ///
    /// Use `.closure { L in ... }` to specify an arbitrary Swift closure, which is both allowed to capture things, and
    /// allowed to throw (it is called as if wrapped by `convertThrowToError()`).
    ///
    /// For example, to make a type `Foo` callable:
    ///
    ///     L.registerMetatable(for: Foo.self, functions: [
    ///         "__call": .function { L in
    ///            print("TODO call support")
    ///            return 0
    ///        }
    ///     ])
    ///
    /// Do not specify a `_gc` in `functions`, this is created automatically. If `__index` is not specified, one is
    /// created which refers to the metatable, thus additional items in `functions` are accessible Lua-side:
    ///
    ///     L.registerMetatable(for: Foo.self, functions: [
    ///         "bar": .function { L in
    ///             print("This is a call to bar()!")
    ///             return 0
    ///         }
    ///     ])
    ///     // Means you can do foo.bar()
    ///
    /// - Parameter type: Type to register.
    /// - Parameter functions: Map of functions.
    /// - Precondition: There must not already be a metatable defined for `type`.
    func registerMetatable<T>(for type: T.Type, functions: [String: MetafieldType]) {
        doRegisterMetatable(typeName: getMetatableName(for: type), functions: functions)
        getState().userdataMetatables.insert(lua_topointer(self, -1))
        pop() // metatable
    }

    /// Returns true if `registerMetatable()` has already been called for `T`.
    ///
    /// Note, does not consider any metatable set with `registerDefaultMetatable()`.
    func isMetatableRegistered<T>(for type: T.Type) -> Bool {
        let name = getMetatableName(for: type)
        let t = luaL_getmetatable(self, name)
        pop()
        return t == LUA_TTABLE
    }

    /// Register a metatable to be used for all values which have not had an
    /// explicit call to `registerMetatable`.
    ///
    /// - Parameter functions: map of functions
    func registerDefaultMetatable(functions: [String: MetafieldType]) {
        doRegisterMetatable(typeName: Self.DefaultMetatableName, functions: functions)
        getState().userdataMetatables.insert(lua_topointer(self, -1))
        pop() // metatable
    }

    // Kept for compat
    func registerDefaultMetatable(functions: [String: lua_CFunction]) {
        let fns = functions.mapValues { MetafieldType.function($0) }
        registerDefaultMetatable(functions: fns	)
    }

    // MARK: - get/set functions

    /// Wrapper around [lua_rawget](http://www.lua.org/manual/5.4/manual.html#lua_rawget).
    ///
    /// - Precondition: The value at `index` must be a table.
    /// - Parameter index: The stack index of the table.
    /// - Returns: The type of the resulting value.
    @discardableResult
    func rawget(_ index: CInt) -> LuaType {
        precondition(type(index) == .table)
        return LuaType(rawValue: lua_rawget(self, index))!
    }

    /// Convenience function which calls `rawget(_:)` using `key` as the key.
    ///
    /// - Precondition: The value at `index` must be a table.
    /// - Parameter index: The stack index of the table.
    /// - Parameter key: The key to look up in the table.
    /// - Returns: The type of the resulting value.
    @discardableResult
    func rawget<K: Pushable>(_ index: CInt, key: K) -> LuaType {
        let absidx = absindex(index)
        push(key)
        return rawget(absidx)
    }

    @discardableResult
    func rawget(_ index: CInt, utf8Key key: String) -> LuaType {
        let absidx = absindex(index)
        push(utf8String: key)
        return rawget(absidx)
    }

    /// Look up a value using `rawget` and convert it to `T` using the given accessor.
    func rawget<K: Pushable, T>(_ index: CInt, key: K, _ accessor: (CInt) -> T?) -> T? {
        rawget(index, key: key)
        let result = accessor(-1)
        pop()
        return result
    }

    /// Pushes onto the stack the value `tbl[key]`. May invoke metamethods.
    ///
    /// Where `tbl` is the table at `index` on the stack and `key` is the value on the top of the stack.
    ///
    /// - Parameter index: The stack index of the table.
    /// - Returns: The type of the resulting value.
    /// - Throws: `LuaCallError` if a Lua error is raised during the call to `lua_gettable`.
    @discardableResult
    func get(_ index: CInt) throws -> LuaType {
        let absidx = absindex(index)
        push({ L in
            lua_gettable(L, 1)
            return 1
        })
        lua_insert(self, -2) // Move the fn below key
        push(index: absidx)
        lua_insert(self, -2) // move tbl below key
        try pcall(nargs: 2, nret: 1)
        return type(-1)!
    }

    /// Pushes onto the stack the value `tbl[key]`. May invoke metamethods.
    ///
    /// Where `tbl` is the table at `index` on the stack.
    ///
    /// - Parameter index: The stack index of the table.
    /// - Parameter key: The key to look up in the table.
    /// - Returns: The type of the resulting value.
    /// - Throws: `LuaCallError` if a Lua error is raised during the call to `lua_gettable`.
    @discardableResult
    func get<K: Pushable>(_ index: CInt, key: K) throws -> LuaType {
        let absidx = absindex(index)
        push(key)
        return try get(absidx)
    }

    /// Look up a value `tbl[key]` and convert it to `T` using the given accessor.
    ///
    /// Where `tbl` is the table at `index` on the stack. If an error is thrown during the table lookup, `nil` is
    /// returned.
    ///
    /// - Parameter index: The stack index of the table.
    /// - Parameter key: The key to look up in the table.
    /// - Parameter accessor: A function which takes a stack index and returns a `T?`.
    /// - Returns: The resulting value.
    func get<K: Pushable, T>(_ index: CInt, key: K, _ accessor: (CInt) -> T?) -> T? {
        if let _ = try? get(index, key: key) {
            let result = accessor(-1)
            pop()
            return result
        } else {
            return nil
        }
    }

    /// Look up a value `tbl[key]` and decode it using `todecodable<T>()`.
    ///
    /// Where `tbl` is the table at `index` on the stack. If an error is thrown during the table lookup or decode,
    /// `nil` is returned.
    ///
    /// - Parameter index: The stack index of the table.
    /// - Parameter key: The key to look up in the table.
    /// - Parameter accessor: A function which takes a stack index and returns a `T?`.
    /// - Returns: The resulting value.
    func getdecodable<K: Pushable, T: Decodable>(_ index: CInt, key: K) -> T? {
        if let _ = try? get(index, key: key) {
            let result: T? = todecodable(-1)
            pop()
            return result
        } else {
            return nil
        }
    }

    /// Performs `tbl[key] = val` using raw accesses, ie does not invoke metamethods.
    ///
    /// Where `tbl` is the table at `index` on the stack, `val` is the value on the top of the stack, and `key` is the
    /// value just below the top.
    ///
    /// - Precondition: The value at `index` must be a table.
    func rawset(_ index: CInt) {
        precondition(type(index) == .table, "Cannot call rawset on something that isn't a table")
        lua_rawset(self, index)
    }

    /// Performs `tbl[key] = val` using raw accesses, ie does not invoke metamethods.
    ///
    /// Where `tbl` is the table at `index` on the stack, and `val` is the value on the top of the stack.
    ///
    /// - Parameter key: The key to use.
    /// - Precondition: The value at `index` must be a table.
    func rawset<K: Pushable>(_ index: CInt, key: K) {
        let absidx = absindex(index)
        // val on top of stack
        push(key)
        lua_insert(self, -2) // Push key below val
        rawset(absidx)
    }

    func rawset(_ index: CInt, utf8Key key: String) {
        let absidx = absindex(index)
        // val on top of stack
        push(utf8String: key)
        lua_insert(self, -2) // Push key below val
        rawset(absidx)
    }

    /// Performs `tbl[key] = val` using raw accesses, ie does not invoke metamethods.
    ///
    /// Where `tbl` is the table at `index` on the stack.
    ///
    /// - Parameter key: The key to use.
    /// - Parameter value: The value to set.
    /// - Precondition: The value at `index` must be a table.
    func rawset<K: Pushable, V: Pushable>(_ index: CInt, key: K, value: V) {
        let absidx = absindex(index)
        push(key)
        push(value)
        rawset(absidx)
    }

    func rawset<V: Pushable>(_ index: CInt, utf8Key key: String, value: V) {
        let absidx = absindex(index)
        push(utf8String: key)
        push(value)
        rawset(absidx)
    }

    /// Performs `tbl[key] = val`. May invoke metamethods.
    ///
    /// Where `tbl` is the table at `index` on the stack, `val` is the value on the top of the stack, and `key` is the
    /// value just below the top.
    ///
    /// - Throws: `LuaCallError` if a Lua error is raised during the call to `lua_settable`.
    func set(_ index: CInt) throws {
        let absidx = absindex(index)
        push({ L in
            lua_settable(L, 1)
            return 0
        })
        lua_insert(self, -3) // Move the fn below key and val
        push(index: absidx)
        lua_insert(self, -3) // move tbl below key and val
        try pcall(nargs: 3, nret: 0)
    }

    /// Performs `tbl[key] = val`. May invoke metamethods.
    ///
    /// Where `tbl` is the table at `index` on the stack and `val` is the value on the top of the stack
    ///
    /// - Parameter key: The key to use.
    /// - Throws: `LuaCallError` if a Lua error is raised during the call to `lua_settable`.
    func set<K: Pushable>(_ index: CInt, key: K) throws {
        let absidx = absindex(index)
        // val on top of stack
        push(key)
        lua_insert(self, -2) // Push key below val
        try set(absidx)
    }

    /// Performs `tbl[key] = val`. May invoke metamethods.
    ///
    /// Where `tbl` is the table at `index` on the stack and `val` is the value on the top of the stack
    ///
    /// - Parameter key: The key to use.
    /// - Parameter value: The value to set.
    /// - Throws: `LuaCallError` if a Lua error is raised during the call to `lua_settable`.
    func set<K: Pushable, V: Pushable>(_ index: CInt, key: K, value: V) throws {
        let absidx = absindex(index)
        push(key)
        push(value)
        try set(absidx)
    }

    // MARK: - Misc functions

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
    /// Does not leave the module on the stack.
    ///
    /// - Throws: `LuaCallError` if a Lua error is raised during the execution of the function.
    func requiref(name: String, function: lua_CFunction, global: Bool = true) throws {
        push({ L in
            let name = lua_tostring(L, 1)
            let fn = lua_tocfunction(L, 2)
            let global = lua_toboolean(L, 3)
            luaL_requiref(L, name, fn, global)
            return 0
        })
        push(utf8String: name)
        push(function)
        push(global)
        try pcall(nargs: 3, nret: 0)
    }

    /// Load a function pushed by `closure` as if it were a Lua module.
    ///
    /// This is similar to [`luaL_requiref()`](https://www.lua.org/manual/5.4/manual.html#luaL_requiref) but instead of
    /// providing a `lua_CFunction` that when called forms the body of the module, pass in a `closure` which must push a
    /// function on to the Lua stack. It is this resulting function which is called to create the module.
    ///
    /// This allows code like:
    ///
    /// ```swift
    /// try L.requiref(name: "a_module") {
    ///     try L.load(string: "return { ... }")
    /// }
    /// ```
    ///
    /// - Parameter name: The name of the module.
    /// - Parameter global: Whether or not to set _G[name].
    /// - Parameter closure: This closure is called to push the module function onto the stack. Note, it will not be
    ///   called if a module called `name` is already loaded.
    /// - Throws: `LuaCallError` if a Lua error is raised during the execution of the function.
    /// - Throws: rethrows if `closure` throws.
    func requiref(name: String, global: Bool = true, closure: () throws -> Void) throws {
        // There's just no reasonable way to shoehorn this into calling luaL_requiref, we have to unroll it...
        let L = self
        luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_LOADED_TABLE)
        rawget(-1, utf8Key: name)  /* LOADED[modname] */
        let loaded_idx = L.gettop()
        defer {
            // Note unlike luaL_requiref we do not leave the module on the stack
            lua_remove(L, loaded_idx)
        }
        if (lua_toboolean(L, -1) == 0) {  /* package not already loaded? */
            lua_pop(L, 1)  /* remove field */
            
            let top = L.gettop()
            try closure()
            precondition(L.gettop() == top + 1 && L.type(-1) == .function,
                         "requiref closure did not push a function onto the stack!")

            push(utf8String: name)  /* argument to open function */
            try pcall(nargs: 1, nret: 1)  /* call 'openf' to open module */
            lua_pushvalue(L, -1)  /* make copy of module (call result) */
            lua_setfield(L, -3, name)  /* LOADED[modname] = module */
        }
        if (global) {
            lua_pushvalue(L, -1)  /* copy of module */
            lua_setglobal(L, name)  /* _G[modname] = module */
        }
    }

    // unsafe version, function must not error
    private func requiref_unsafe(name: UnsafePointer<CChar>!, function: lua_CFunction, global: Bool = true) {
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
                push(index: -nup)
            }
            lua_pushcclosure(self, fn, nup)
            rawset(-(nup + 2), utf8Key: name)
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

    /// Returns an `Error` wrapping the given string.
    ///
    /// Which when caught by `convertThrowToError` will be converted back to a Lua error with exactly the given string
    /// contents.
    ///
    /// This is useful in combination with `convertThrowToError` inside a `lua_CFunction` to safely throw a Lua error.
    ///
    /// Example:
    ///
    /// ```swift
    /// func myluafn(_ L: LuaState!) -> CInt {
    ///     return L.convertThrowToError {
    ///         // ...
    ///         throw L.error("Something error-worthy happened")
    ///     }
    /// }
    /// ```
    func error(_ string: String) -> some Error {
        return LuaCallError(ref(any: string))
    }

    /// Convert a Lua value on the stack into a Swift object of type `LuaValue`. Does not pop the value from the stack.
    ///
    /// - Parameter index: The stack index of the value.
    /// - Returns: A `LuaValue` representing the value at the given stack index.
    func ref(index: CInt) -> LuaValue {
        push(index: index)
        let type = type(-1)!
        let ref = luaL_ref(self, LUA_REGISTRYINDEX)
        let result = LuaValue(L: self, ref: ref, type: type)
        if type != .nilType {
            getState().luaValues[ref] = UnownedLuaValue(val: result)
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

    /// Returns the raw length of a string, table or userdata.
    ///
    /// - Parameter index: The stack index of the value.
    /// - Returns: the length, or `nil` if the value is not one of the types that has a defined raw length.
    func rawlen(_ index: CInt) -> lua_Integer? {
        switch type(index) {
        case .string, .table, .userdata:
            return lua_Integer(lua_rawlen(self, index))
        default:
            return nil
        }
    }

    /// Returns the length of a value, as per the [length operator](https://www.lua.org/manual/5.4/manual.html#3.4.7).
    ///
    /// - Parameter index: The stack index of the value.
    /// - Returns: the length, or `nil` if the value does not have a defined length or `__len` did not return an
    ///   integer.
    /// - Throws: ``LuaCallError`` if the value had a `__len` metafield which errored.
    func len(_ index: CInt) throws -> lua_Integer? {
        let t = type(index)
        if t == .string {
            // Len on strings cannot fail or error
            return rawlen(index)!
        }
        let mt = luaL_getmetafield(self, index, "__len")
        if mt == LUA_TNIL {
            if t == .table {
                // Raw len also cannot fail
                return rawlen(index)!
            } else {
                // Some other type that doesn't have a length
                return nil
            }
        } else {
            push(index: index)
            try pcall(nargs: 1, nret: 1)
            return tointeger(-1)
        }
    }

    /// See [lua_rawequal](https://www.lua.org/manual/5.4/manual.html#lua_rawequal).
    func rawequal(_ index1: CInt, _ index2: CInt) -> Bool {
        return lua_rawequal(self, index1, index2) != 0
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
    /// - Parameter displayPath: If set, use this instead of `file` in Lua stacktraces.
    /// - Parameter mode: Whether to only allow text files, compiled binary chunks, or either.
    /// - Throws: `LuaLoadError.fileNotFound` if `file` cannot be opened.
    /// - Throws: `LuaLoadError.parseError` if the file cannot be parsed.
    func load(file path: String, displayPath: String? = nil, mode: LoadMode = .text) throws {
        var err: CInt = 0
#if LUASWIFT_NO_FOUNDATION
        var ospath = Array<UInt8>(path.utf8)
        ospath.append(0) // Zero-terminate the path
        ospath.withUnsafeBytes { ptr in
            let cpath = ptr.bindMemory(to: CChar.self)
            err = luaL_loadfilexx(self, cpath.baseAddress!, displayPath ?? path, mode.rawValue)
        }
#else
        err = luaL_loadfilexx(self, FileManager.default.fileSystemRepresentation(withPath: path), displayPath ?? path, mode.rawValue)
#endif
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
    func load(data: [UInt8], name: String?, mode: LoadMode = .text) throws {
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
    /// - Parameter string: The Lua script to load.
    /// - Throws: `LuaLoadError.parseError` if the data cannot be parsed.
    func load(string: String, name: String? = nil) throws {
        try load(data: Array<UInt8>(string.utf8), name: name, mode: .text)
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

    class _State {
#if !LUASWIFT_NO_FOUNDATION
        var defaultStringEncoding = ExtendedStringEncoding.stringEncoding(.utf8)
#endif
        var metatableDict = Dictionary<String, Array<Any.Type>>()
        var userdataMetatables = Set<UnsafeRawPointer>()
        var luaValues = Dictionary<CInt, UnownedLuaValue>()

        deinit {
            for (_, val) in luaValues {
                val.val.L = nil
            }
        }
    }

    func getState() -> _State {
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

    func maybeGetState() -> _State? {
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

    func unref(_ ref: CInt) {
        getState().luaValues[ref] = nil
        luaL_unref(self, LUA_REGISTRYINDEX, ref)
    }

    // Top of stack must have iterfn, state, initval
    func do_for_pairs(_ block: (CInt, CInt) throws -> Bool) throws {
        try withoutActuallyEscaping(block) { escapingBlock in
            let wrapper = ClosureWrapper({ L in
                // IMPORTANT: this closure uses unprotected lua_calls that may error. Therefore it must NOT put
                // any non-trivial type onto the stack or rely on any Swift stack cleanup happening such as
                // defer {...}.

                // Stack: 1 = iterfn, 2 = state, 3 = initval (k)
                assert(L.gettop() == 3)
                while true {
                    L.settop(3)
                    L.push(index: 1)
                    lua_insert(L, 3) // put iterfn before k
                    L.push(index: 2)
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
                return 0
            })

            // Must ensure closure does not actually escape, since we cannot rely on prompt garbage collection of the
            // upvalue, explicitly nil it in the ClosureWrapper instead.
            defer {
                wrapper.closure = nil
            }
            push(wrapper)
            lua_insert(self, -4) // Push wrapper below iterfn, state, initval
            try pcall(nargs: 3, nret: 0)
        }
    }

}
