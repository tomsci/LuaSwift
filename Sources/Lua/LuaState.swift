// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

#if !LUASWIFT_NO_FOUNDATION
import Foundation
#endif
import CLua

public typealias LuaState = UnsafeMutablePointer<lua_State>

public typealias LuaClosure = (LuaState) throws -> CInt

public typealias lua_Integer = CLua.lua_Integer

/// Special value for ``Lua/Swift/UnsafeMutablePointer/pcall(nargs:nret:traceback:)`` to indicate
/// that all results should be returned unadjusted.
public let LUA_MULTRET: CInt = CLua.LUA_MULTRET

/// Redeclaration of the underlying `lua_CFunction` type with easier-to-read types.
public typealias lua_CFunction = @convention(c) (LuaState?) -> CInt

/// The type of the ``LUA_VERSION`` constant.
public struct LuaVer {
    /// The Lua major version number (eg 5)
    public let major: CInt
    /// The Lua minor version number (eg 4)
    public let minor: CInt
    /// The Lua release number (eg 6, for 5.4.6)
    public let release: CInt
    /// The complete Lua version number as an int (eg 50406 for 5.4.6)
    public var releaseNum: CInt {
        return (major * 100 + minor) * 100 + release
    }

    public func is54orLater() -> Bool {
        return major >= 5 && minor >= 4
    }

    // 5.4 constructor
    init(major: CInt, minor: CInt, release: CInt) {
        self.major = major
        self.minor = minor
        self.release = release
    }

    // 5.3 and earlier constructor
    init(major: String, minor: String, release: String) {
        self.major = CInt(major)!
        self.minor = CInt(minor)!
        self.release = CInt(release)!
    }

}

/// The version of Lua being used.
public let LUA_VERSION = LuaVer(major: LUASWIFT_LUA_VERSION_MAJOR, minor: LUASWIFT_LUA_VERSION_MINOR,
    release: LUASWIFT_LUA_VERSION_RELEASE)

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

// Because getting a raw pointer to a var to use with lua_rawsetp(L, LUA_REGISTRYINDEX) is so awkward in Swift, we use a
// function instead as the registry key we stash the State in, because we _can_ reliably generate file-unique
// lua_CFunctions.
fileprivate func stateLookupKey(_ L: LuaState!) -> CInt {
    return 0
}

/// A Swift enum of the Lua types.
public enum LuaType : CInt, CaseIterable {
    // Annoyingly can't use LUA_TNIL etc here because the bridge exposes them as `var LUA_TNIL: CInt { get }`
    // which is not acceptable for an enum (which requires the rawValue to be a literal)
    case `nil` = 0 // LUA_TNIL
    case boolean = 1 // LUA_TBOOLEAN
    case lightuserdata = 2 // LUA_TLIGHTUSERDATA
    case number = 3 // LUA_TNUMBER
    case string = 4 // LUA_STRING
    case table = 5 // LUA_TTABLE
    case function = 6 // LUA_TFUNCTION
    case userdata = 7 // LUA_TUSERDATA
    case thread = 8 // LUA_TTHREAD
}

extension LuaType {
    /// Returns the type as a String.
    ///
    /// In the same format as used by [`type()`](https://www.lua.org/manual/5.4/manual.html#pdf-type) and
    /// [`lua_typename()`](https://www.lua.org/manual/5.4/manual.html#lua_typename).
    public func tostring() -> String {
        switch self {
        case .nil: return "nil"
        case .boolean: return "boolean"
        case .lightuserdata: return "userdata"
        case .number: return "number"
        case .string: return "string"
        case .table: return "table"
        case .function: return "function"
        case .userdata: return "userdata"
        case .thread: return "thread"
        }
    }

    /// Returns the type as a String.
    ///
    /// As per ``tostring()``, but including handling `nil` (ie `LUA_TNONE`).
    public static func tostring(_ type: LuaType?) -> String {
        return type?.tostring() ?? "no value"
    }
}

extension UnsafeMutablePointer where Pointee == lua_State {

    /// OptionSet representing the standard Lua libraries. 
    public struct Libraries: OptionSet {
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

        /// The set of all standard Lua libraries.
        public static let all: Libraries = [.package, .coroutine, .table, .io, .os, .string, .math, .utf8, .debug]

        /// The subset of libraries which do not permit undefined or sandbox-escaping behavior.
        ///
        /// Note that `package` is not a 'safe' library by this definition because it permits arbitrary DLLs to be
        /// loaded. `package` is safe if ``Lua/Swift/UnsafeMutablePointer/setRequireRoot(_:displayPath:)`` is called,
        /// however.
        public static let safe: Libraries = [.coroutine, .table, .string, .math, .utf8]
    }

    // MARK: - State management

    /// Create a new `LuaState`.
    ///
    /// Note that because `LuaState` is defined as `UnsafeMutablePointer<lua_State>`, the state is _not_ automatically
    /// destroyed when it goes out of scope. You must call ``close()``.
    ///
    /// ```swift
    /// let state = LuaState(libraries: .all)
    ///
    /// // is equivalent to:
    /// let state = luaL_newstate()
    /// luaL_openlibs(state)
    /// ```
    ///
    /// - Parameter libraries: Which of the standard libraries to open.
    public init(libraries: Libraries) {
        self = luaL_newstate()
        requiref_unsafe(name: "_G", function: luaopen_base)
        openLibraries(libraries)
    }

    /// Destroy and clean up the Lua state.
    ///
    /// Must be the last function called on this `LuaState` pointer. For example:
    ///
    /// ```swift
    /// class MyLuaWrapperClass {
    ///     let L: LuaState
    ///
    ///     init() {
    ///         L = LuaState(libraries: .all)
    ///     }
    ///     deinit {
    ///         L.close()
    ///     }
    /// }
    /// ```
    public func close() {
        lua_close(self)
    }

    /// Open some or all of the standard Lua libraries.
    ///
    /// Example:
    /// ```swift
    /// L.openLibraries(libraries: .all)
    /// // is equivalent to:
    /// luaL_openlibs(L)
    /// ```
    ///
    /// - Parameter libraries: Which of the standard libraries to open.
    public func openLibraries(_ libraries: Libraries) {
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
    ///   for any preloads configured with ``addModules(_:mode:)``.
    /// - Parameter displayPath: What to display in stacktraces instead of showing the full `path`. The default `""`
    ///   means stacktraces will contain just the Lua module names. Pass in `path` or `nil` to show the unmodified real
    ///   path.
    /// - Precondition: The `package` standard library must have been opened.
    public func setRequireRoot(_ path: String?, displayPath: String? = "") {
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
        if path != nil {
            let searcher: LuaClosure = { L in
                let pathRoot = path!
                let displayPrefix = displayPath ?? pathRoot
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
            L.push(searcher)
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
    /// See <doc:EmbedLua> for one way to produce a suitable `modules` value.
    ///
    /// - Parameter modules: A dictionary of module names to data suitable to be passed to ``load(data:name:mode:)``.
    /// - Parameter mode: The `LoadMode` to be used when loading any of the modules in `modules`.
    public func addModules(_ modules: [String: [UInt8]], mode: LoadMode = .binary) {
        luaL_getsubtable(self, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE)
        for (name, data) in modules {
            push({ L in
                let filename = name.map { $0 == "." ? "/" : $0 }
                try L.load(data: data, name: "@\(filename).lua", mode: mode)
                L.push(name)
                try L.pcall(nargs: 1, nret: 1)
                return 1
            })
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
    /// See <doc:EmbedLua> for one way to produce a suitable `modules` value.
    ///
    /// - Parameter modules: A dictionary of module names to data suitable to be passed to ``load(data:name:mode:)``.
    /// - Parameter mode: The `LoadMode` to be used when loading any of the modules in `modules`.
    public func setModules(_ modules: [String: [UInt8]], mode: LoadMode = .binary) {
        luaL_getsubtable(self, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE)
        for (_, _) in pairs(-1) {
            pop() // Remove v
            pushnil()
            lua_settable(self, -3)
        }
        pop() // preload table
        addModules(modules, mode: mode)
    }

    public enum GcWhat: CInt {
        /// When passed to ``Lua/Swift/UnsafeMutablePointer/collectgarbage(_:)``, stops the garbage collector.
        case stop = 0
        /// When passed to ``Lua/Swift/UnsafeMutablePointer/collectgarbage(_:)``, restart the garbage collector.
        case restart = 1
        /// When passed to ``Lua/Swift/UnsafeMutablePointer/collectgarbage(_:)``, performs a full garbage-collection cycle.
        case collect = 2
    }

    enum MoreGarbage: CInt {
        case count = 3
        case countb = 4
        case isrunning = 9
    }

    /// Call the garbage collector according to the `what` parameter.
    ///
    /// When called with no arguments, performs a full garbage-collection cycle.
    public func collectgarbage(_ what: GcWhat = .collect) {
        luaswift_gc0(self, what.rawValue)
    }

    /// Returns true if the garbage collector is running.
    ///
    /// Equivalent to `lua_gc(L, LUA_GCISRUNNING)` in C.
    public func collectorRunning() -> Bool {
        return luaswift_gc0(self, MoreGarbage.isrunning.rawValue) != 0
    }

    /// Returns the total amount of memory in bytes that the Lua state is using.
    public func collectorCount() -> Int {
        return Int(luaswift_gc0(self, MoreGarbage.count.rawValue)) * 1024 + Int(luaswift_gc0(self, MoreGarbage.countb.rawValue))
    }

    class _State {
#if !LUASWIFT_NO_FOUNDATION
        var defaultStringEncoding: LuaStringEncoding = .stringEncoding(.utf8)
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
        let mtName = "LuaSwift_State"
        doRegisterMetatable(typeName: mtName, functions: [:])
        state.userdataMetatables.insert(lua_topointer(self, -1))
        pop() // metatable
        push(function: stateLookupKey)
        pushuserdata(state, metatableName: mtName)
        rawset(LUA_REGISTRYINDEX)

        // While we're here, register ClosureWrapper
        // Are we doing too much non-deferred initialization in getState() now?
        registerMetatable(for: LuaClosureWrapper.self, functions: [:])

        return state
    }

    func maybeGetState() -> _State? {
        push(function: stateLookupKey)
        rawget(LUA_REGISTRYINDEX)
        var result: _State? = nil
        // We must call the unchecked version to avoid recursive loops as touserdata calls maybeGetState(). This is
        // safe because we know the value of StateRegistryKey does not need checking.
        if let state: _State = unchecked_touserdata(-1) {
            result = state
        }
        pop()
        return result
    }

    // MARK: - Basic stack stuff

    /// Get the type of the value at the given index.
    ///
    /// - Parameter index: The stack index of the value.
    /// - Returns: The type of the value at `index`, or `nil` for a non-valid but acceptable index.
    ///   `nil` is the equivalent of `LUA_TNONE`, whereas ``LuaType/nil`` is the equivalent of `LUA_TNIL`.
    public func type(_ index: CInt) -> LuaType? {
        let t = lua_type(self, index)
        assert(t >= LUA_TNONE && t <= LUA_TTHREAD)
        return LuaType(rawValue: t)
    }

    /// Get the type of the value at the given stack index, as a String.
    ///
    ///This is primarily a convenience for:
    /// ```swift
    /// LuaType.tostring(L.type(index: index))
    /// ```
    ///
    /// - Parameter index: The stack index of the value.
    /// - Returns: The type of the value at `index` as a String, as per
    ///   [`lua_typename()`](https://www.lua.org/manual/5.4/manual.html#lua_typename).
    public func typename(index: CInt) -> String {
        return String(cString: luaL_typename(self, index))
    }

    /// See [lua_absindex](https://www.lua.org/manual/5.4/manual.html#lua_absindex).
    public func absindex(_ index: CInt) -> CInt {
        return lua_absindex(self, index)
    }

    /// See [lua_isnone](https://www.lua.org/manual/5.4/manual.html#lua_isnone).
    public func isnone(_ index: CInt) -> Bool {
        return type(index) == nil
    }

    /// See [lua_isnoneornil](https://www.lua.org/manual/5.4/manual.html#lua_isnoneornil).
    public func isnoneornil(_ index: CInt) -> Bool {
        if let t = type(index) {
            return t == .nil
        } else {
            return true // ie is none
        }
    }

    /// Pops `nitems` elements from the stack.
    ///
    /// - Parameter nitems: The number of items to pop from the stack.
    /// - Precondition: There must be at least `nitems` on the stack.
    public func pop(_ nitems: CInt = 1) {
        // For performance Lua doesn't check this itself, but it leads to such weird errors further down the line it's
        // worth trying to catch here.
        precondition(gettop() - nitems >= 0, "Attempt to pop more items from the stack than it contains")
        lua_pop(self, nitems)
    }

    /// See [lua_gettop](https://www.lua.org/manual/5.4/manual.html#lua_gettop).
    public func gettop() -> CInt {
        return lua_gettop(self)
    }

    /// See [lua_settop](https://www.lua.org/manual/5.4/manual.html#lua_settop).
    public func settop(_ top: CInt) {
        lua_settop(self, top)
    }

    /// See [lua_checkstack](https://www.lua.org/manual/5.4/manual.html#lua_checkstack).
    public func checkstack(_ n: CInt) {
        if (lua_checkstack(self, n) == 0) {
            // This isn't really recoverable
            fatalError("lua_checkstack failed!")
        }
    }

    /// Create a new table on top of the stack.
    ///
    /// - Parameter narr: If specified, preallocate space in the table for this many array elements.
    /// - Parameter nrec: If specified, preallocate space in the table for this many non-array elements.
    public func newtable(narr: CInt = 0, nrec: CInt = 0) {
        lua_createtable(self, narr, nrec)
    }

    // MARK: - to...() functions

    public func toboolean(_ index: CInt) -> Bool {
        let b = lua_toboolean(self, index)
        return b != 0
    }

    /// Return the value at the given index as an integer, if it is a number convertible to one.
    ///
    /// - Note: Strings are not automatically converted, unlike
    ///   [`lua_tointegerx()`](http://www.lua.org/manual/5.4/manual.html#lua_tointegerx).
    ///
    /// - Parameter index: The stack index.
    /// - Returns: The integer value, or `nil` if the value was not a number or not convertible to an integer.
    public func tointeger(_ index: CInt) -> lua_Integer? {
        guard type(index) == .number else {
            return nil
        }
        var isnum: CInt = 0
        let ret = lua_tointegerx(self, index, &isnum)
        if isnum == 0 {
            return nil
        } else {
            return ret
        }
    }

    /// Return the value at the given index as an integer, if it is a number convertible to one.
    ///
    /// - Note: Strings are not automatically converted, unlike
    ///   [`lua_tointegerx()`](http://www.lua.org/manual/5.4/manual.html#lua_tointegerx).
    ///
    /// - Parameter index: The stack index.
    /// - Returns: The integer value, or `nil` if the value was not a number or not convertible to an integer.
    public func toint(_ index: CInt) -> Int? {
        if let int = tointeger(index) {
            return Int(exactly: int)
        } else {
            return nil
        }
    }

    public func tonumber(_ index: CInt) -> Double? {
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
    /// Does not include a null terminator. If the value is is not a Lua string this returns `nil`.
    ///
    /// - Parameter index: The stack index.
    /// - Returns: the value as a `UInt8` array, or `nil` if the value was not a Lua `string`.
    public func todata(_ index: CInt) -> [UInt8]? {
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
    public func tostring(_ index: CInt, convert: Bool = false) -> String? {
        if var data = todata(index) {
            data.append(0) // Must be null terminated for String(utf8String:)
            return data.withUnsafeBufferPointer { buf in
                return buf.withMemoryRebound(to: CChar.self) { ccharbuf in
                    return String(validatingUTF8: ccharbuf.baseAddress!)
                }
            }
        } else if convert {
            push(function: luaswift_tostring)
            push(index: index)
            do {
                try pcall(nargs: 1, nret: 1, traceback: false)
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
    public func tostringUtf8(_ index: CInt, convert: Bool = false) -> String? {
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
    /// If `guessType` is `false`, the placeholder types ``LuaStringRef`` and ``LuaTableRef`` are used for `string` and
    /// `table` values respectively.
    ///
    /// Regardless of `guessType`, `LuaValue` may be used to represent values that cannot be expressed as Swift types.
    ///
    /// - Parameter index: The stack index.
    /// - Parameter guessType: Whether to automatically convert `string` and `table` values based on heuristics.
    /// - Returns: An `Any` representing the given index. Will only return `nil` if `index` refers to a `nil`
    ///   Lua value, all non-nil values will be converted to _some_ sort of `Any`.
    public func toany(_ index: CInt, guessType: Bool = true) -> Any? {
        guard let t = type(index) else {
            return nil
        }
        switch (t) {
        case .nil:
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
    public func tovalue<T>(_ index: CInt) -> T? {
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
    public func touserdata<T>(_ index: CInt) -> T? {
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
    public func todecodable<T: Decodable>(_ index: CInt, _ type: T.Type) -> T? {
        let top = gettop()
        defer {
            settop(top)
        }
        let decoder = LuaDecoder(state: self, index: index, codingPath: [])
        return try? decoder.decode(T.self)
    }

    /// Convert a value on the stack to a `Decodable` type inferred from the return type.
    ///
    /// If `T` is a composite struct or class type, the Lua representation must be a table with members corresponding
    /// to the Swift member names. Userdata values, or tables containing userdatas, are not convertible using this
    /// function - use `touserdata()` ot `tovalue()` instead.
    ///
    /// - Parameter index: The stack index.
    /// - Returns: A value of type `T`, or `nil` if the value at the given stack position cannot be decoded to `T`.
    public func todecodable<T: Decodable>(_ index: CInt) -> T? {
        return todecodable(index, T.self)
    }

    // MARK: - Convenience dict fns

    /// Convenience function that gets a key from the table at `index` and returns it as an `Int`.
    ///
    /// This function may invoke metamethods, and will return `nil` if one errors.
    ///
    /// - Parameter index: The stack index of the table (or table-like object with a `__index` metafield).
    /// - Parameter key: The key to look up.
    /// - Returns: The value as an `Int`, or `nil` if the key was not found, the value was not an integer
    ///   or if a metamethod errored.
    public func toint(_ index: CInt, key: String) -> Int? {
        return get(index, key: key, self.toint)
    }

    /// Convenience function that gets a key from the table at `index` and returns it as a `Double`.
    ///
    /// This function may invoke metamethods, and will return `nil` if one errors.
    ///
    /// - Parameter index: The stack index of the table (or table-like object with a `__index` metafield).
    /// - Parameter key: The key to look up.
    /// - Returns: The value as a `Double`, or `nil` if the key was not found, the value was not a number
    ///   or if a metamethod errored.
    public func tonumber(_ index: CInt, key: String) -> Double? {
        return get(index, key: key, self.tonumber)
    }

    /// Convenience function that gets a key from the table at `index` and returns it as a `Bool`.
    ///
    /// This function may invoke metamethods, and will return `false` if one errors.
    ///
    /// - Parameter index: The stack index of the table (or table-like object with a `__index` metafield).
    /// - Parameter key: The key to look up.
    /// - Returns: The value as a `Bool`, or `false` if the key was not found, the value was a false value,
    ///   or if a metamethod errored.
    public func toboolean(_ index: CInt, key: String) -> Bool {
        return get(index, key: key, self.toboolean) ?? false
    }

    /// Convenience function that gets a key from the table at `index` and returns it as a byte array.
    ///
    /// This function may invoke metamethods, and will return `nil` if one errors.
    ///
    /// - Parameter index: The stack index of the table (or table-like object with a `__index` metafield).
    /// - Parameter key: The key to look up.
    /// - Returns: The value as a byte array or `nil` if the key was not found, the value was not a string,
    ///   or if a metamethod errored.
    public func todata(_ index: CInt, key: String) -> [UInt8]? {
        return get(index, key: key, self.todata)
    }

    /// Convenience function that gets a key from the table at `index` and returns it as a `String`.
    ///
    /// This function may invoke metamethods, and will return `nil` if one errors.
    ///
    /// - Parameter index: The stack index of the table (or table-like object with a `__index` metafield).
    /// - Parameter key: The key to look up.
    /// - Returns: The value as a `String`, or `nil` if: the key was not found; the value was not a string (and
    ///   `convert` was false); the value could not be converted to a String using the default encoding; or if a
    ///   metamethod errored.
    public func tostring(_ index: CInt, key: String, convert: Bool = false) -> String? {
        return get(index, key: key, { tostring($0, convert: convert) })
    }

    // MARK: - Iterators

    private class IPairsRawIterator: Sequence, IteratorProtocol {
        let L: LuaState
        let index: CInt
        let top: CInt?
        var i: lua_Integer
        init(_ L: LuaState, _ index: CInt, start: lua_Integer, resetTop: Bool) {
            self.L = L
            self.index = L.absindex(index)
            top = resetTop ? lua_gettop(L) : nil
            i = start - 1
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

    /// Return a for-iterator that iterates the array part of a table, using raw accesses.
    ///
    /// Inside the for loop, each element will on the top of the stack and can be accessed using stack index -1. Indexes
    /// are done raw, in other words the `__index` metafield is ignored if the table has one.
    ///
    /// ```swift
    /// // Assuming { 11, 22, 33 } is on the top of the stack
    /// for i in L.ipairs(-1) {
    ///     print("Index \(i) is \(L.toint(-1)!)")
    /// }
    /// // Prints:
    /// // Index 1 is 11
    /// // Index 2 is 22
    /// // Index 3 is 33
    /// ```
    ///
    /// - Parameter index: Stack index of the table to iterate.
    /// - Parameter start: What table index to start iterating from. Default is `1`, ie the start of the array.
    /// - Parameter resetTop: By default, the stack top is reset on exit and
    ///   each time through the iterator to what it was at the point of calling
    ///   `ipairs`. Occasionally (such as when using `luaL_Buffer`) this is not
    ///   desirable and can be disabled by setting `resetTop` to false.
    /// - Precondition: `index` must refer to a table value.
    public func ipairs(_ index: CInt, start: lua_Integer = 1, resetTop: Bool = true) -> some Sequence<lua_Integer> {
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
    /// - Parameter start: What table index to start iterating from. Default is `1`, ie the start of the array.
    /// - Parameter block: The code to execute.
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the execution a `__index` metafield or if the value
    ///   does not support indexing.
    public func for_ipairs(_ index: CInt, start: lua_Integer = 1, _ block: (lua_Integer) throws -> Bool) throws {
        let absidx = absindex(index)
        try withoutActuallyEscaping(block) { escapingBlock in
            let wrapper = LuaClosureWrapper({ L in
                var i = start
                while true {
                    L.settop(1)
                    let t = try L.get(1, key: i)
                    if t == .nil {
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
                wrapper._closure = nil
            }

            push(wrapper)
            push(index: absidx) // The value being iterated is the first (and only arg) to wrapper above
            try pcall(nargs: 1, nret: 0, traceback: false)
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

    /// Return a for-iterator that will iterate all the members of a table, using raw accesses.
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
    public func pairs(_ index: CInt) -> some Sequence<(CInt, CInt)> {
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
    public func pushPairsParameters() throws -> Bool {
        let L = self
        if luaL_getmetafield(L, -1, "__pairs") == LUA_TNIL {
            let isTable = L.type(-1) == .table
            // Use next, value, nil
            L.push(function: { (L: LuaState!) in
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
            try L.pcall(nargs: 1, nret: 3, traceback: false)
            return true
        }
    }

    /// Iterate a Lua table-like value, calling `block` for each member.
    ///
    /// This function observes `__pairs` metafields if present. `block` should
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
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the execution of an iterator function or a `__pairs`
    ///   metafield, or if the value at `index` does not support indexing.
    public func for_pairs(_ index: CInt, _ block: (CInt, CInt) throws -> Bool) throws {
        push(index: index) // The value being iterated
        try pushPairsParameters() // pops value, pushes iterfn, state, initval
        try do_for_pairs(block)
    }

    // Top of stack must have iterfn, state, initval
    func do_for_pairs(_ block: (CInt, CInt) throws -> Bool) throws {
        try withoutActuallyEscaping(block) { escapingBlock in
            let wrapper = LuaClosureWrapper({ L in
                // Stack: 1 = iterfn, 2 = state, 3 = initval (k)
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
                wrapper._closure = nil
            }
            push(wrapper)
            lua_insert(self, -4) // Push wrapper below iterfn, state, initval
            try pcall(nargs: 3, nret: 0)
        }
    }

    // MARK: - push() functions

    /// Push a nil value onto the stack.
    public func pushnil() {
        lua_pushnil(self)
    }

    /// Push the **fail** value onto the stack.
    ///
    /// Currently (in Lua 5.4) this function behaves identically to `pushnil()`.
    public func pushfail() {
        pushnil()
    }

    /// Pushes a copy of the element at the given index onto the top of the stack.
    ///
    /// - Parameter index: Stack index of the value to copy.
    public func push(index: CInt) {
        lua_pushvalue(self, index)
    }

    /// Push anything which conforms to ``Pushable`` onto the stack.
    ///
    /// Parameter value: Any Swift value which conforms to ``Pushable``.
    public func push<T>(_ value: T?) where T: Pushable {
        if let value = value {
            value.push(onto: self)
        } else {
            self.pushnil()
        }
    }

    /// Push a String onto the stack, using the default string encoding.
    ///
    /// See ``getDefaultStringEncoding()``.
    public func push(string: String) {
#if LUASWIFT_NO_FOUNDATION
        let data = Array<UInt8>(string.utf8)
        push(data)
#else
        push(string: string, encoding: getDefaultStringEncoding())
#endif
    }

    /// Push a String onto the stack, using UTF-8 string encoding.
    ///
    /// - Note: If `LUASWIFT_NO_FOUNDATION` is defined, this function behaves identically to ``push(string:)``.
    ///
    public func push(utf8String string: String) {
#if LUASWIFT_NO_FOUNDATION
        push(string: string)
#else
        push(string: string, encoding: .utf8)
#endif
    }

    /// Push a byte array onto the stack, as a Lua `string`.
    ///
    /// - Parameter data: the data to push.
    public func push(_ data: [UInt8]) {
        data.withUnsafeBytes { rawBuf in
            push(rawBuf)
        }
    }

    /// Push a `lua_CFunction` onto the stack.
    ///
    /// Functions or closures implemented in Swift that conform to `(LuaState?) -> CInt` may be pushed using this API
    /// only if they:
    ///
    /// * Do not throw Swift or Lua errors
    /// * Do not capture any variables
    public func push(function: lua_CFunction) {
        lua_pushcfunction(self, function)
    }

    /// Push a closure of type ``LuaClosure`` onto the stack as a Lua function.
    ///
    /// See ``LuaClosure`` for a discussion of how LuaClosures behave.
    ///
    /// `closure` may use upvalues in the same was as
    /// [`lua_pushcclosure`](https://www.lua.org/manual/5.4/manual.html#lua_pushcclosure) with one exception: They start
    /// at index 1 plus ``LuaClosureWrapper/NumInternalUpvalues``, rather than `1`, due to the housekeeping required to
    /// perform the Lua-Swift bridging. Normally however, you would use Swift captures rather than Lua upvalues to
    /// access variables from within `closure` and thus `numUpvalues` would normally be omitted or `0`.
    public func push(_ closure: @escaping LuaClosure, numUpvalues: CInt = 0) {
        LuaClosureWrapper(closure).push(onto: self, numUpvalues: numUpvalues)
    }

    /// Pushes a zero-arguments closure on to the stack as a Lua function.
    ///
    /// The Lua function when called will call the `closure`, and convert any result to a Lua value using
    /// ``push(any:)``. If `closure` throws an error, it will be converted to a Lua error using
    /// ``push(error:)``.
    ///
    /// If `closure` does not return a value, the Lua function will return `nil`.
    ///
    /// ```swift
    /// L.push(closure: {
    ///     print("I am callable from Lua!")
    /// })
    /// L.push(closure: {
    ///     return "I am callable and return a result"
    /// })
    /// ```
    public func push(closure: @escaping () throws -> Any?) {
        push({ L in
            L.push(any: try closure())
            return 1
        })
    }

    /// Pushes a one-argument closure on to the stack as a Lua function.
    ///
    /// The Lua function when called will call `closure`, converting its arguments to match the signature of `closure`,
    /// and convert any result to a Lua value using ``push(any:)``. If arguments cannot be converted, a Lua error will
    /// be thrown. As with standard Lua function calls, excess arguments are discarded and any shortfall are filled in
    /// with `nil`.
    ///
    ///  If `closure` throws an error, it will be converted to a Lua error using ``push(error:)``. If
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
    /// - Note: Arguments to `closure` must all be optionals, of a type ``tovalue(_:)`` can return.
    public func push<Arg1>(closure: @escaping (Arg1?) throws -> Any?) {
        push({ L in
            let arg1: Arg1? = try L.checkClosureArgument(index: 1)
            L.push(any: try closure(arg1))
            return 1
        })
    }

    /// Pushes a two-argument closure on to the stack as a Lua function.
    ///
    /// The Lua function when called will call `closure`, converting its arguments to match the signature of `closure`,
    /// and convert any result to a Lua value using ``push(any:)``. If arguments cannot be converted, a Lua error will
    /// be thrown. As with standard Lua function calls, excess arguments are discarded and any shortfall are filled in
    /// with `nil`.
    ///
    ///  If `closure` throws an error, it will be converted to a Lua error using ``push(error:)``. If
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
    /// - Note: Arguments to `closure` must all be optionals, of a type ``tovalue(_:)`` can return.
    public func push<Arg1, Arg2>(closure: @escaping (Arg1?, Arg2?) throws -> Any?) {
        push({ L in
            let arg1: Arg1? = try L.checkClosureArgument(index: 1)
            let arg2: Arg2? = try L.checkClosureArgument(index: 2)
            L.push(any: try closure(arg1, arg2))
            return 1
        })
    }

    /// Pushes a three-argument closure on to the stack as a Lua function.
    ///
    /// The Lua function when called will call `closure`, converting its arguments to match the signature of `closure`,
    /// and convert any result to a Lua value using ``push(any:)``. If arguments cannot be converted, a Lua error will
    /// be thrown. As with standard Lua function calls, excess arguments are discarded and any shortfall are filled in
    /// with `nil`.
    ///
    ///  If `closure` throws an error, it will be converted to a Lua error using ``push(error:)``. If
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
    /// - Note: Arguments to `closure` must all be optionals, of a type ``tovalue(_:)`` can return.
    public func push<Arg1, Arg2, Arg3>(closure: @escaping (Arg1?, Arg2?, Arg3?) throws -> Any?) {
        push({ L in
            let arg1: Arg1? = try L.checkClosureArgument(index: 1)
            let arg2: Arg2? = try L.checkClosureArgument(index: 2)
            let arg3: Arg3? = try L.checkClosureArgument(index: 3)
            L.push(any: try closure(arg1, arg2, arg3))
            return 1
        })
    }

    /// Helper function used by implementations of `push(closure:)`.
    public func checkClosureArgument<T>(index: CInt) throws -> T? {
        let val: T? = tovalue(index)
        if val == nil && !isnoneornil(index) {
            let t = typename(index: index)
            let err = "Type of argument \(index) (\(t)) does not match type required by Swift closure (\(T.self))"
            throw error(err)
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
    /// To make the object usable from Lua, declare a metatable for the type of `val` using
    /// ``registerMetatable(for:functions:)``. Note that this function always uses the dynamic type of `val`, and not
    /// whatever `T` is, when calculating what metatable to assign the object. Thus `push(userdata: foo)` and
    /// `push(userdata: foo as Any)` will behave identically. Pushing a value of a type which has no metatable
    /// previously registered will generate a warning, and the object will have no metamethods declared on it,
    /// except for `__gc` which is always defined in order that Swift object lifetimes are preserved.
    ///
    /// - Parameter val: The value to push onto the Lua stack.
    /// - Note: This function always pushes a `userdata` - if `val` represents any other type (for example, an integer)
    ///   it will not be converted to that type in Lua. Use ``push(any:)`` instead to automatically convert types to
    ///   their Lua native representation where possible.
    public func push<T>(userdata: T) {
        let anyval = userdata as Any
        let tname = getMetatableName(for: Swift.type(of: anyval))
        pushuserdata(anyval, metatableName: tname)
    }

    private func pushuserdata(_ val: Any, metatableName: String) {
        let udata = luaswift_newuserdata(self, MemoryLayout<Any>.size)!
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
    /// To convert the value, the following logic is applied:
    ///
    /// * If `value` is `nil` or `Void` (ie the empty tuple), it is pushed as `nil`.
    /// * If `value` conforms to ``Pushable``, Pushable's ``Pushable/push(onto:)`` is used.
    /// * If `value` is an `NSNumber`, if it is convertible to `Int` it is pushed as such, otherwise as a `Double`.
    /// * If `value` is `[UInt8]`, ``push(_:)-3o5nr`` is used.
    /// * If `value` conforms to `ContiguousBytes`, ``push(bytes:)`` is used.
    /// * If `value` is an `Array` or `Dictionary` that is not `Pushable`, `push(any:)` is called recursively to push
    ///   its elements.
    /// * If `value` is a `lua_CFunction`, ``push(function:)`` is used.
    /// * If `value` is a `LuaClosure`, ``push(_:numUpvalues:)`` is used (with `numUpvalues=0`).
    /// * If `value` is a zero-argument closure that returns `Void` or `Any?`, it is pushed using `push(closure:)`.
    ///   Due to limitations in Swift type inference, these are the only closure types that are handled in this way.
    /// * Any other type is pushed as a `userdata` using ``push(userdata:)``.
    ///
    /// - Parameter value: The value to push
    public func push(any value: Any?) {
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
        // I don't have strong enough confidence that I understand how bridged strings (CFStringRef, _NSCFString,
        // NSTaggedString, __StringStorage, who knows how many others) behave to declare Pushable conformance that would
        // definitely work for all string types - this however should cover all possibilities.
        case let str as String:
            push(str)
#if !LUASWIFT_NO_FOUNDATION
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
            push(function: function)
        case let closure as LuaClosure:
            push(closure)
        case let closure as () throws -> ():
            push(closure: closure)
        case let closure as () throws -> (Any?):
            push(closure: closure)
        default:
            push(userdata: value)
        }
    }

    /// Push a Swift Error onto the Lua stack.
    ///
    /// This function special-cases ``LuaCallError``, ``LuaLoadError/parseError(_:)`` and errors returned by
    /// ``error(_:)``, and pushes the original underlying Lua error value unmodified. Otherwise the string
    /// `"Swift error: \(error.localizedDescription)"` is used.
    public func push(error: Error) {
        switch error {
        case let err as LuaCallError:
            push(err)
        case LuaLoadError.parseError(let str):
            push(str)
        default:
#if LUASWIFT_NO_FOUNDATION
            push("Swift error: \(String(describing: error))")
#else
            push("Swift error: \(error.localizedDescription)")
#endif
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
    /// - Parameter nret: The number of expected results. Can be ``LUA_MULTRET``
    ///   to keep all returned values.
    /// - Parameter traceback: If true, any errors thrown will include a
    ///   full stack trace.
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the execution of the function.
    /// - Precondition: The top of the stack must contain a function and `nargs` arguments.
    public func pcall(nargs: CInt, nret: CInt, traceback: Bool = true) throws {
        let index: CInt
        if traceback {
            index = gettop() - nargs
            push(function: tracebackFn)
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
            throw LuaCallError.popFromStack(self)
        }
    }

    /// Convenience zero-result wrapper around ``Lua/Swift/UnsafeMutablePointer/pcall(nargs:nret:traceback:)``.
    ///
    /// Make a protected call to a Lua function that must already be pushed
    /// onto the stack. Each of `arguments` is pushed using ``push(any:)``. The
    /// function is popped from the stack and any results are discarded.
    ///
    /// - Parameter arguments: Arguments to pass to the Lua function.
    /// - Parameter traceback: If true, any errors thrown will include a
    ///   full stack trace.
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the execution of the function.
    /// - Precondition: The value at the top of the stack must refer to a Lua function or callable.
    public func pcall(_ arguments: Any?..., traceback: Bool = true) throws {
        try pcall(arguments: arguments, traceback: traceback)
    }

    public func pcall(arguments: [Any?], traceback: Bool = true) throws {
        for arg in arguments {
            push(any: arg)
        }
        try pcall(nargs: CInt(arguments.count), nret: 0, traceback: traceback)
    }

    /// Convenience one-result wrapper around ``Lua/Swift/UnsafeMutablePointer/pcall(nargs:nret:traceback:)``.
    ///
    /// Make a protected call to a Lua function that must already be pushed
    /// onto the stack. Each of `arguments` is pushed using ``push(any:)``. The
    /// function is popped from the stack. All results are popped from the stack
    /// and the first one is converted to `T` using ``tovalue(_:)``. `nil` is
    /// returned if the result could not be converted to `T`.
    ///
    /// - Parameter arguments: Arguments to pass to the Lua function.
    /// - Parameter traceback: If true, any errors thrown will include a
    ///   full stack trace.
    /// - Returns: The first result of the function, converted if possible to a
    ///   `T`.
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the execution of the function.
    /// - Precondition: The value at the top of the stack must refer to a Lua function or callable.
    public func pcall<T>(_ arguments: Any?..., traceback: Bool = true) throws -> T? {
        return try pcall(arguments: arguments, traceback: traceback)
    }

    public func pcall<T>(arguments: [Any?], traceback: Bool = true) throws -> T? {
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
        let prefix = "LuaSwift_Type_" + String(describing: type)
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

    public enum MetafieldType {
        case function(lua_CFunction)
        case closure(LuaClosure)
    }

    private func doRegisterMetatable(typeName: String, functions: [String: MetafieldType]) {
        precondition(functions["__gc"] == nil, "__gc function for Swift userdata types is registered automatically")
        if luaL_newmetatable(self, typeName) == 0 {
            fatalError("Metatable for type \(typeName) is already registered!")
        }

        for (name, function) in functions {
            switch function {
            case let .function(cfunction):
                push(function: cfunction)
            case let .closure(closure):
                push(LuaClosureWrapper(closure))
            }
            rawset(-2, utf8Key: name)
        }

        if functions["__index"] == nil {
            push(index: -1)
            rawset(-2, utf8Key: "__index")
        }

        push(function: gcUserdata)
        rawset(-2, utf8Key: "__gc")
    }

    private static let DefaultMetatableName = "LuaSwift_Default"

    /// Register a metatable for values of type `T`.
    ///
    /// Register a metatable for values of type `T` for when they are pushed using ``push(userdata:)`` or 
    /// ``push(any:)``. Note, attempting to register a metatable for types that are bridged to Lua types (such as
    /// `Integer,` or `String`), will not work with values pushed with ``push(any:)`` - if you really need to do that,
    /// they must always be pushed with ``push(userdata:)`` (at which point they cannot be used as normal Lua
    /// numbers/strings/etc).
    ///
    /// Use `.function` to specify a `lua_CFunction` directly. You can use a Swift closure in lieu of a `lua_CFunction`
    /// pointer providing it does not capture any variables, does not throw or error, and has the right signature, for
    /// example `.function { (L: LuaState!) -> CInt in ... }`.
    ///
    /// Use `.closure { L in ... }` to specify an arbitrary Swift closure (of type ``LuaClosure``), which is both
    /// allowed to capture things, and allowed to throw.
    ///
    /// For example, to make a type `Foo` callable:
    ///
    /// ```swift
    /// L.registerMetatable(for: Foo.self, functions: [
    ///     "__call": .function { L in
    ///        print("TODO call support")
    ///        return 0
    ///    }
    /// ])
    /// ```
    ///
    /// Do not specify a `__gc` in `functions`, this is created automatically. If `__index` is not specified, one is
    /// created which refers to the metatable, thus additional items in `functions` are accessible Lua-side:
    ///
    /// ```swift
    /// L.registerMetatable(for: Foo.self, functions: [
    ///     "bar": .function { L in
    ///         print("This is a call to bar()!")
    ///         return 0
    ///     }
    /// ])
    /// // Means you can do foo.bar()
    /// ```
    ///
    /// All metatables are stored in the Lua registry using the prefix `"LuaSwift_"`, to avoid conflicting with any
    /// other uses of [`luaL_newmetatable()`](http://www.lua.org/manual/5.4/manual.html#luaL_newmetatable). The exact
    /// name used is an internal implementation detail.
    ///
    /// - Parameter type: Type to register.
    /// - Parameter functions: Map of functions.
    /// - Precondition: There must not already be a metatable defined for `type`.
    public func registerMetatable<T>(for type: T.Type, functions: [String: MetafieldType]) {
        doRegisterMetatable(typeName: getMetatableName(for: type), functions: functions)
        getState().userdataMetatables.insert(lua_topointer(self, -1))
        pop() // metatable
    }

    /// Returns true if ``registerMetatable(for:functions:)`` has already been called for `T`.
    ///
    /// Note, does not consider any metatable set with ``registerDefaultMetatable(functions:)``.
    public func isMetatableRegistered<T>(for type: T.Type) -> Bool {
        let name = getMetatableName(for: type)
        let t = luaL_getmetatable(self, name)
        pop()
        return t == LUA_TTABLE
    }

    /// Register a metatable to be used for all types which have not had an explicit call to
    /// ``registerMetatable(for:functions:)``.
    ///
    /// If this function is not called, a warning will be printed the first time an unregistered type is pushed. A
    /// minimal metatable will be generated in such cases, which supports garbage collection but otherwise exposes no
    /// other functions.
    ///
    /// - Parameter functions: map of functions.
    public func registerDefaultMetatable(functions: [String: MetafieldType]) {
        doRegisterMetatable(typeName: Self.DefaultMetatableName, functions: functions)
        getState().userdataMetatables.insert(lua_topointer(self, -1))
        pop() // metatable
    }

    // MARK: - get/set functions

    /// Wrapper around [lua_rawget](http://www.lua.org/manual/5.4/manual.html#lua_rawget).
    ///
    /// - Precondition: The value at `index` must be a table.
    /// - Parameter index: The stack index of the table.
    /// - Returns: The type of the resulting value.
    @discardableResult
    public func rawget(_ index: CInt) -> LuaType {
        precondition(type(index) == .table)
        return LuaType(rawValue: lua_rawget(self, index))!
    }

    /// Convenience function which calls ``rawget(_:)`` using `key` as the key.
    ///
    /// - Precondition: The value at `index` must be a table.
    /// - Parameter index: The stack index of the table.
    /// - Parameter key: The key to use.
    /// - Returns: The type of the resulting value.
    @discardableResult
    public func rawget<K: Pushable>(_ index: CInt, key: K) -> LuaType {
        let absidx = absindex(index)
        push(key)
        return rawget(absidx)
    }

    /// Convenience function which calls ``rawget(_:)`` using `utf8Key` as the key.
    ///
    /// - Precondition: The value at `index` must be a table.
    /// - Parameter index: The stack index of the table.
    /// - Parameter utf8Key: The key to use, which will always be pushed using UTF-8 encoding.
    /// - Returns: The type of the resulting value.
    @discardableResult
    public func rawget(_ index: CInt, utf8Key key: String) -> LuaType {
        let absidx = absindex(index)
        push(utf8String: key)
        return rawget(absidx)
    }

    /// Look up a value using ``rawget(_:key:)`` and convert it to `T` using the given accessor.
    public func rawget<K: Pushable, T>(_ index: CInt, key: K, _ accessor: (CInt) -> T?) -> T? {
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
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the call to `lua_gettable`.
    @discardableResult
    public func get(_ index: CInt) throws -> LuaType {
        let absidx = absindex(index)
        push(function: luaswift_gettable)
        lua_insert(self, -2) // Move the fn below key
        push(index: absidx)
        lua_insert(self, -2) // move tbl below key
        try pcall(nargs: 2, nret: 1, traceback: false)
        return type(-1)!
    }

    /// Pushes onto the stack the value `tbl[key]`. May invoke metamethods.
    ///
    /// Where `tbl` is the table at `index` on the stack.
    ///
    /// - Parameter index: The stack index of the table.
    /// - Parameter key: The key to look up in the table.
    /// - Returns: The type of the resulting value.
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the call to `lua_gettable`.
    @discardableResult
    public func get<K: Pushable>(_ index: CInt, key: K) throws -> LuaType {
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
    public func get<K: Pushable, T>(_ index: CInt, key: K, _ accessor: (CInt) -> T?) -> T? {
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
    public func getdecodable<K: Pushable, T: Decodable>(_ index: CInt, key: K) -> T? {
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
    public func rawset(_ index: CInt) {
        precondition(type(index) == .table, "Cannot call rawset on something that isn't a table")
        lua_rawset(self, index)
    }

    /// Performs `tbl[key] = val` using raw accesses, ie does not invoke metamethods.
    ///
    /// Where `tbl` is the table at `index` on the stack, and `val` is the value on the top of the stack.
    ///
    /// - Parameter key: The key to use.
    /// - Precondition: The value at `index` must be a table.
    public func rawset<K: Pushable>(_ index: CInt, key: K) {
        let absidx = absindex(index)
        // val on top of stack
        push(key)
        lua_insert(self, -2) // Push key below val
        rawset(absidx)
    }

    public func rawset(_ index: CInt, utf8Key key: String) {
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
    public func rawset<K: Pushable, V: Pushable>(_ index: CInt, key: K, value: V) {
        let absidx = absindex(index)
        push(key)
        push(value)
        rawset(absidx)
    }

    /// Performs `tbl[key] = val` using raw accesses, ie does not invoke metamethods.
    ///
    /// Where `tbl` is the table at `index` on the stack.
    ///
    /// - Parameter key: The key to use, which will always be pushed using UTF-8 encoding.
    /// - Parameter value: The value to set.
    /// - Precondition: The value at `index` must be a table.
    public func rawset<V: Pushable>(_ index: CInt, utf8Key key: String, value: V) {
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
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the call to `lua_settable`.
    public func set(_ index: CInt) throws {
        let absidx = absindex(index)
        push(function: luaswift_settable)
        lua_insert(self, -3) // Move the fn below key and val
        push(index: absidx)
        lua_insert(self, -3) // move tbl below key and val
        try pcall(nargs: 3, nret: 0, traceback: false)
    }

    /// Performs `tbl[key] = val`. May invoke metamethods.
    ///
    /// Where `tbl` is the table at `index` on the stack and `val` is the value on the top of the stack
    ///
    /// - Parameter key: The key to use.
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the call to `lua_settable`.
    public func set<K: Pushable>(_ index: CInt, key: K) throws {
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
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the call to `lua_settable`.
    public func set<K: Pushable, V: Pushable>(_ index: CInt, key: K, value: V) throws {
        let absidx = absindex(index)
        push(key)
        push(value)
        try set(absidx)
    }

    // MARK: - Misc functions

    /// Pushes the global called `name` onto the stack.
    ///
    /// - Parameter name: The name of the global to push onto the stack. The global name is always assumed to be in
    ///   UTF-8 encoding.
    @discardableResult
    public func getglobal(_ name: String) -> LuaType {
        return LuaType(rawValue: lua_getglobal(self, name))!
    }

    /// Pushes the globals table (`_G`) onto the stack.
    public func pushGlobals() {
        lua_pushglobaltable(self)
    }

    /// Wrapper around [`luaL_requiref()`](https://www.lua.org/manual/5.4/manual.html#luaL_requiref).
    ///
    /// Does not leave the module on the stack.
    ///
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the execution of the function.
    public func requiref(name: String, function: lua_CFunction, global: Bool = true) throws {
        push(function: luaswift_requiref)
        push(utf8String: name)
        push(function: function)
        push(global)
        try pcall(nargs: 3, nret: 0)
    }

    /// Load a function pushed by `closure` as if it were a Lua module.
    ///
    /// This is similar to ``requiref(name:function:global:)`` but instead of providing a `lua_CFunction` that when
    /// called forms the body of the module, pass in a `closure` which must push a function on to the Lua stack. It is
    /// this resulting function which is called to create the module.
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
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the execution of the module function.
    ///   Rethrows if `closure` throws.
    public func requiref(name: String, global: Bool = true, closure: () throws -> Void) throws {
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
    public func setfuncs(_ fns: [String: lua_CFunction], nup: CInt = 0) {
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

    /// Returns an `Error` wrapping the given string.
    ///
    /// Which when pushed by ``push(error:)`` will be converted back to a Lua error with exactly the given string
    /// contents.
    ///
    /// This is useful inside a ``LuaClosure`` to safely throw a Lua error.
    ///
    /// Example:
    ///
    /// ```swift
    /// func myluafn(L: LuaState) throws -> CInt {
    ///     // ...
    ///     throw L.error("Something error-worthy happened")
    /// }
    /// ```
    ///
    /// To raise a non-string error, push the required value on to the stack and call
    /// `throw LuaCallError.popFromStack(L)`.
    public func error(_ string: String) -> LuaCallError {
        return LuaCallError(string)
    }

    /// Convert a Lua value on the stack into a Swift object of type `LuaValue`. Does not pop the value from the stack.
    ///
    /// - Parameter index: The stack index of the value.
    /// - Returns: A `LuaValue` representing the value at the given stack index.
    public func ref(index: CInt) -> LuaValue {
        push(index: index)
        let type = type(-1)!
        let ref = luaL_ref(self, LUA_REGISTRYINDEX)
        if ref == LUA_REFNIL {
            return LuaValue()
        } else {
            let result = LuaValue(L: self, ref: ref, type: type)
            getState().luaValues[ref] = UnownedLuaValue(val: result)
            return result
        }
    }

    func unref(_ ref: CInt) {
        getState().luaValues[ref] = nil
        luaL_unref(self, LUA_REGISTRYINDEX, ref)
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
    public func ref(any: Any?) -> LuaValue {
        push(any: any)
        return popref()
    }

    /// Convert the value on the top of the Lua stack into a Swift object of type `LuaValue` and pops it.
    ///
    /// - Returns: A `LuaValue` representing the value on the top of the stack.
    public func popref() -> LuaValue {
        let result = ref(index: -1)
        pop()
        return result
    }

    /// Returns a `LuaValue` representing the global environment.
    ///
    /// Equivalent to (but slightly more efficient than):
    ///
    /// ```swift
    /// L.pushGlobals()
    /// let globals = L.popref()
    /// ```
    ///
    /// For example:
    ///
    /// ```swift
    /// try L.globals["print"].pcall("Hello world!")
    /// ```
    public var globals: LuaValue {
        // Note, LUA_RIDX_GLOBALS doesn't need to be freed so doesn't need to be added to luaValues
        return LuaValue(L: self, ref: LUA_RIDX_GLOBALS, type: .table)
    }

    /// Returns the raw length of a string, table or userdata.
    ///
    /// - Parameter index: The stack index of the value.
    /// - Returns: the length, or `nil` if the value is not one of the types that has a defined raw length.
    public func rawlen(_ index: CInt) -> lua_Integer? {
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
    public func len(_ index: CInt) throws -> lua_Integer? {
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

    /// Compare two values for raw equality, ie without invoking `__eq` metamethods.
    ///
    /// See [lua_rawequal](https://www.lua.org/manual/5.4/manual.html#lua_rawequal).
    ///
    /// - Parameter index1: Index of the first value to compare.
    /// - Parameter index2: Index of the second value to compare.
    /// - Returns: true if the two values are equal according to the definition of raw equality.
    public func rawequal(_ index1: CInt, _ index2: CInt) -> Bool {
        return lua_rawequal(self, index1, index2) != 0
    }

    /// Compare two values for equality. May invoke `__eq` metamethods.
    ///
    /// - Parameter index1: Index of the first value to compare.
    /// - Parameter index2: Index of the second value to compare.
    /// - Returns: true if the two values are equal.
    /// - Throws: ``LuaCallError`` if an `__eq` metamethod errored.
    public func equal(_ index1: CInt, _ index2: CInt) throws -> Bool {
        return try compare(index1, index2, .eq)
    }

    /// The type of comparison to perform in ``compare(_:_:_:)``.
    public enum ComparisonOp : Int {
        /// Compare for equality (`==`)
        case eq = 0 // LUA_OPEQ
        /// Compare less than (`<`)
        case lt = 1 // LUA_OPLT
        /// Compare less than or equal (`<=`)
        case le = 2 // LUA_OPLE
    }

    /// Compare two values using the given comparison operator. May invoke metamethods.
    ///
    /// - Parameter index1: Index of the first value to compare.
    /// - Parameter index2: Index of the second value to compare.
    /// - Parameter op: The comparison operator to perform.
    /// - Returns: true if the comparison is satisfied.
    /// - Throws: ``LuaCallError`` if a metamethod errored.
    public func compare(_ index1: CInt, _ index2: CInt, _ op: ComparisonOp) throws -> Bool {
        let i1 = absindex(index1)
        let i2 = absindex(index2)
        push(function: luaswift_compare)
        push(index: i1)
        push(index: i2)
        push(op.rawValue)
        try pcall(nargs: 3, nret: 1, traceback: false)
        return toint(-1) != 0
    }

    /// Get the main thread for this state.
    ///
    /// Unless coroutines are being used, this will be the same as `self`.
    public func getMainThread() -> LuaState {
        rawget(LUA_REGISTRYINDEX, key: LUA_RIDX_MAINTHREAD)
        defer {
            pop()
        }
        return lua_tothread(self, -1)!
    }

    // MARK: - Loading code

    public enum LoadMode: String {
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
    /// - Throws: ``LuaLoadError/fileNotFound`` if `file` cannot be opened. ``LuaLoadError/parseError(_:)`` if the file
    ///   cannot be parsed.
    public func load(file path: String, displayPath: String? = nil, mode: LoadMode = .text) throws {
        var err: CInt = 0
#if LUASWIFT_NO_FOUNDATION
        var ospath = Array<UInt8>(path.utf8)
        ospath.append(0) // Zero-terminate the path
        ospath.withUnsafeBytes { ptr in
            ptr.withMemoryRebound(to: CChar.self) { cpath in
                err = luaswift_loadfile(self, cpath.baseAddress, displayPath ?? path, mode.rawValue)
            }
        }
#else
        err = luaswift_loadfile(self, FileManager.default.fileSystemRepresentation(withPath: path), displayPath ?? path, mode.rawValue)
#endif
        if err == LUA_ERRFILE {
            throw LuaLoadError.fileNotFound
        } else if err == LUA_ERRSYNTAX {
            let errStr = tostring(-1)!
            pop()
            throw LuaLoadError.parseError(errStr)
        } else if err != LUA_OK {
            fatalError("Unexpected error from luaswift_loadfile")
        }
    }

    /// Load a Lua chunk from memory, without executing it.
    ///
    /// On return, the function representing the file is left on the top of the stack.
    ///
    /// - Parameter data: The data to load.
    /// - Parameter name: The name of the chunk, for use in stacktraces. Optional.
    /// - Parameter mode: Whether to only allow text, compiled binary chunks, or either.
    /// - Throws: ``LuaLoadError/parseError(_:)`` if the data cannot be parsed.
    public func load(data: [UInt8], name: String?, mode: LoadMode) throws {
        try data.withUnsafeBytes { buf in
            try load(buffer: buf, name: name, mode: mode)
        }
    }

    /// Load a Lua chunk from memory, without executing it.
    ///
    /// On return, the function representing the file is left on the top of the stack.
    ///
    /// - Parameter buffer: The data to load.
    /// - Parameter name: The name of the chunk, for use in stacktraces. Optional.
    /// - Parameter mode: Whether to only allow text, compiled binary chunks, or either.
    /// - Throws: ``LuaLoadError/parseError(_:)`` if the data cannot be parsed.
    public func load(buffer: UnsafeRawBufferPointer, name: String?, mode: LoadMode) throws {
        var err: CInt = 0
        buffer.withMemoryRebound(to: CChar.self) { chars in
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
    /// - Throws: ``LuaLoadError/parseError(_:)`` if the data cannot be parsed.
    public func load(string: String, name: String? = nil) throws {
        try load(data: Array<UInt8>(string.utf8), name: name, mode: .text)
    }

    /// Load a Lua chunk from file with ``load(file:displayPath:mode:)`` and execute it.
    ///
    /// Any values returned from the file are left on the top of the stack.
    ///
    /// - Parameter file: Path to a Lua text or binary file.
    /// - Parameter mode: Whether to only allow text files, compiled binary chunks, or either.
    /// - Throws: ``LuaLoadError/fileNotFound`` if `file` cannot be opened.
    ///   ``LuaLoadError/parseError(_:)`` if the file cannot be parsed.
    public func dofile(_ path: String, mode: LoadMode = .text) throws {
        try load(file: path, mode: mode)
        try pcall(nargs: 0, nret: LUA_MULTRET)
    }
}
