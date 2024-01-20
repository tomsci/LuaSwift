// Copyright (c) 2023-2024 Tom Sutcliffe
// See LICENSE file for license information.

#if !LUASWIFT_NO_FOUNDATION
import Foundation
#endif
import CLua

public typealias LuaState = UnsafeMutablePointer<lua_State>

public typealias LuaClosure = (LuaState) throws -> CInt

/// The integer number type used by Lua. By default, this is configured to be `Int64`.
public typealias lua_Integer = CLua.lua_Integer

/// The floating-point number type used by Lua. By default, this is configured to be `Double`.
public typealias lua_Number = CLua.lua_Number

/// Special value for ``Lua/Swift/UnsafeMutablePointer/pcall(nargs:nret:traceback:)`` to indicate
/// that all results should be returned unadjusted.
///
/// This is identical to `LUA_MULTRET` defined in `CLua`.
public let MultiRet: CInt = CLua.LUA_MULTRET

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
        return releaseNum >= 50400
    }

    // > 5.4.6 constructor
    init(major: CInt, minor: CInt, release: CInt) {
        self.major = major
        self.minor = minor
        self.release = release
    }

    // 5.4.6 and earlier constructor
    init(major: String, minor: String, release: String) {
        self.major = CInt(major)!
        self.minor = CInt(minor)!
        self.release = CInt(release)!
    }

}

/// The version of Lua being used.
public let LUA_VERSION = LuaVer(major: LUASWIFT_LUA_VERSION_MAJOR, minor: LUASWIFT_LUA_VERSION_MINOR,
    release: LUASWIFT_LUA_VERSION_RELEASE)

@usableFromInline
internal func defaultTracebackFn(_ L: LuaState!) -> CInt {
    if let msg = L.tostring(-1) {
        luaL_traceback(L, L, msg, 0)
    } else {
        // Just return the error object as-is
    }
    return 1
}

// Because getting a raw pointer to a var to use with lua_rawsetp(L, LUA_REGISTRYINDEX) is so awkward in Swift, we use a
// function instead as the registry key we stash the State in, because we _can_ reliably generate file-unique
// lua_CFunctions.
fileprivate func stateLookupKey(_ L: LuaState!) -> CInt {
    return 0
}

internal func gcUserdata(_ L: LuaState!) -> CInt {
    let rawptr = lua_touserdata(L, 1)!
    let anyPtr = rawptr.bindMemory(to: Any.self, capacity: 1)
    anyPtr.deinitialize(count: 1)
    return 0
}

/// A Swift enum of the Lua types.
///
/// The `rawValue` of the enum uses the same integer values as the `LUA_T...` type constants. Note that `LUA_TNONE` does
/// not have a `LuaType` representation, and is instead represented by `nil`, ie an optional `LuaType`, in places where
/// `LUA_TNONE` can occur.
@frozen
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
    /// Returns the name of the type in the same format as used by
    /// [`type()`](https://www.lua.org/manual/5.4/manual.html#pdf-type) and
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

    /// Construct a LuaType from a C type integer.
    ///
    /// - Parameter ctype: The C type to convert.
    /// - Returns: A `LuaType` representing the given type, or `nil` if `ctype` is `LUA_TNONE`.
    /// - Precondition: `ctype` must be an integer in the range `LUA_TNONE...LUA_TTHREAD`.
    public init?(ctype: CInt) {
        if ctype == LUA_TNONE {
            return nil
        } else {
            self.init(rawValue: ctype)!
        }
    }

    /// Returns the type as a String.
    ///
    /// As per ``tostring()``, but including handling `nil` (ie `LUA_TNONE`). `LuaType.tostring(nil)` returns
    /// "no value".
    public static func tostring(_ type: LuaType?) -> String {
        return type?.tostring() ?? "no value"
    }
}

/// Conforming to this protocol permits values to perform custom cleanup in response to a `close` metamethod event.
///
/// Types conforming to `Closable` do not need to supply a custom `close` metamethod in their call to
/// ``Lua/Swift/UnsafeMutablePointer/register(_:)-8rgnn``, and instead just need to pass `close: .synthesize`,
/// which will call ``close()``.
///
/// See also ``Metatable`` and [`.synthesize`](doc:Metatable/CloseType/synthesize).
public protocol Closable {
    /// This function will be called when a userdata representing this instance is closed by a Lua `close` event.
    ///
    /// If a value of type `T` conforming to `Closable` is bridged into Lua using `push(userdata:)`, and
    /// `close: .synthesize` was specified in the registration of the type's metatable, then this function will be
    /// called as a result of a `local ... <close>` variable going out of scope. See
    /// [To-be-closed Variables](https://www.lua.org/manual/5.4/manual.html#3.3.8) and
    /// ``Metatable/CloseType/synthesize`` for more information.
    func close()
}

extension UnsafeMutablePointer where Pointee == lua_State {

    /// OptionSet representing the standard Lua libraries.
    @frozen 
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
        /// The safe libraries are:
        /// * `coroutine`
        /// * `table`
        /// * `string`
        /// * `math`
        /// * `utf8`
        ///
        /// Note that `package` is not a 'safe' library by this definition because it permits arbitrary DLLs to be
        /// loaded.
        public static let safe: Libraries = [.coroutine, .table, .string, .math, .utf8]
    }

    // MARK: - State management

    /// Create a new `LuaState`.
    ///
    /// Create a new `LuaState` and optionally open some or all of the standard libraries. The global functions are
    /// always added (ie [`luaopen_base`](https://www.lua.org/manual/5.4/manual.html#pdf-luaopen_base) is always
    /// opened). Note that because `LuaState` is defined as `UnsafeMutablePointer<lua_State>`, the state is _not_
    /// automatically destroyed when it goes out of scope. You must call ``close()``.
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
        requiref_unsafe(name: LUA_GNAME, function: luaopen_base)
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
    @inlinable
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
    /// This replaces `package.searchers`, which has the effect of replacing the default system search paths and
    /// disabling native module loading (via `require`). `package.cpath` is removed, and `package.path` is set to
    /// `"<path>/?.lua"` but the value is effectively read-only; subsequently changing it will not affect the lookup
    /// behaviour.
    ///
    /// For example `require "foo"` will look for `<path>/foo.lua`, and `require "foo.bar"` will look for
    /// `<path>/foo/bar.lua`.
    ///
    /// - Parameter path: The root directory containing .lua files. Specify `nil` to disable all module loading (except
    ///   for any preloads configured with ``addModules(_:mode:)``).
    /// - Parameter displayPath: What to display in stacktraces instead of showing the full `path`. The default `""`
    ///   means stacktraces will contain just the relative file paths, relative to `path`. Pass in `path` or `nil` to
    ///   show the unmodified real path.
    /// - Precondition: The `package` standard library must have been opened.
    public func setRequireRoot(_ path: String?, displayPath: String? = "") {
        let L = self
        // Now configure the require path
        guard getglobal("package") == .table else {
            preconditionFailure("Cannot use setRequireRoot if package library not opened!")
        }

        // Set package.path even though our moduleSearcher doesn't use it
        if let path {
            L.push(utf8String: path + "/?.lua")
        } else {
            L.pushnil()
        }
        L.rawset(-2, utf8Key: "path")

        // Unset cpath, since we remove the searchers that use it
        L.rawset(-1, utf8Key: "cpath", value: .nilValue)

        // Previously we would modify the existing package.searchers, which was expected to look like:
        // [1]: searcher_preload
        // [2]: searcher_Lua
        // [3]: searcher_C
        // [4]: searcher_Croot
        // Now we just replace searchers entirely, providing our own searcher_preload and searcher_Lua equivalents.

        L.newtable(narr: 2)
        L.rawset(-1, key: 1, value: .function(luaswift_searcher_preload))

        if let pathRoot = path {
            let searcher: LuaClosure = { L in
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
                } catch LuaLoadError.fileError {
                    let searcherErrorPrefix = LUA_VERSION.is54orLater() ? "" : "\n\t"
                    L.push("\(searcherErrorPrefix)no file '\(displayPath)'")
                    return 1
                } // Otherwise throw
            }
            L.rawset(-1, key: 2, value: .closure(searcher)) // 2nd searcher is the .lua lookup one
        }
        L.rawset(-2, utf8Key: "searchers") // Pops searchers

        pop(1) // package
    }

    /// Add built-in modules to the [preload](https://www.lua.org/manual/5.4/manual.html#pdf-package.preload) table.
    ///
    /// Add built-in modules to the [preload](https://www.lua.org/manual/5.4/manual.html#pdf-package.preload) table,
    /// such that they can loaded by `require(name)`. The modules are not loaded until `require` is called.
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
            rawset(-2, utf8Key: name)
        }
        pop() // preload table
    }

    /// Add built-in modules to the [preload](https://www.lua.org/manual/5.4/manual.html#pdf-package.preload) table,
    /// removing any others.
    ///
    /// Add built-in modules to the [preload](https://www.lua.org/manual/5.4/manual.html#pdf-package.preload) table,
    /// such that they can loaded by `require(name)`. The modules are not loaded until `require` is called. Any modules
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
            rawset(-3)
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

    public enum GcMode : CInt {
        case generational = 10
        case incremental = 11
    }

    /// Call the garbage collector according to the `what` parameter.
    ///
    /// Starts, stops or runs the garbage collector. When called with no arguments, performs a full garbage-collection
    /// cycle.
    ///
    /// > Note: Do not call this API from within a finalizer, it will have no effect.
    public func collectgarbage(_ what: GcWhat = .collect) {
        luaswift_gc0(self, what.rawValue)
    }

    /// Returns true if the garbage collector is running.
    ///
    /// Equivalent to `lua_gc(L, LUA_GCISRUNNING)` in C.
    public func collectorRunning() -> Bool {
        return luaswift_gc0(self, LUA_GCISRUNNING) > 0
    }

    /// Returns the total amount of memory in bytes that the Lua state is using.
    ///
    /// Returns the total amount of memory in bytes that the Lua state is using.
    ///
    /// > Note: Do not call this API from within a finalizer, it will not return the correct value if you do.
    public func collectorCount() -> Int {
        let kb = luaswift_gc0(self, LUA_GCCOUNT)
        if kb == -1 {
            // uh-oh, in a finalizer?
            return -1
        }
        return Int(kb) * 1024 + Int(luaswift_gc0(self, LUA_GCCOUNTB))
    }

    /// Performs an incremental step of garbage collection.
    ///
    /// Performs an incremental step of garbage collection, as if `stepSize` kilobytes of memory had been allocated by
    /// Lua.
    ///
    /// > Note: Do not call this API from within a finalizer, it will have no effect.
    ///
    /// - Parameter stepSize: If zero, perform a single basic step. If greater than zero, performs garbage collection
    ///   as if `stepSize` kilobytes of memory had been allocated by Lua.
    /// - Returns: `true` if the step finished a collection cycle.
    @discardableResult
    public func collectorStep(_ stepSize: CInt) -> Bool {
        return luaswift_gc1(self, LUA_GCSTEP, stepSize) > 0
    }

    /// Set the garbage collector to incremental mode.
    ///
    /// Set the garbage collector to incremental mode, and optionally set any or all of the collection parameters.
    /// See [Incremental Garbage Collection](https://www.lua.org/manual/5.4/manual.html#2.5.1).
    ///
    /// - Parameter pause: how long the collector waits before starting a new cycle, or `nil` to leave the parameter
    ///   unchanged.
    /// - Parameter stepmul: the speed of the collector relative to memory allocation, or `nil` to leave the parameter
    ///   unchanged.
    /// - Parameter stepsize: size of each incremental step, or `nil` to leave the parameter unchanged. This parameter
    ///   is ignored prior to Lua 5.4.
    /// - Returns: The previous garbage collection mode.
    /// - Precondition: Do not call from within a finalizer.
    @discardableResult
    public func collectorSetIncremental(pause: CInt? = nil, stepmul: CInt? = nil, stepsize: CInt? = nil) -> GcMode {
        let prevMode = luaswift_setinc(self, pause ?? 0, stepmul ?? 0, stepsize ?? 0)
        precondition(prevMode >= 0, "Attempt to call collectorSetIncremental() from within a finalizer.")
        return GcMode(rawValue: prevMode)!
    }

    /// Set the garbage collector to generational mode.
    ///
    /// Set the garbage collector to generational mode, and optionally set any or all of the collection parameters.
    /// See [Generational Garbage Collection](https://www.lua.org/manual/5.4/manual.html#2.5.2). Only supported on
    /// Lua 5.4 and later.
    ///
    /// - Parameter minormul: the frequency of minor collections, or `nil` to leave the parameter unchanged.
    /// - Parameter majormul: the frequency of major collections, or `nil` to leave the parameter unchanged.
    /// - Returns: The previous garbage collection mode.
    /// - Precondition: Do not call from within a finalizer.
    @discardableResult
    public func collectorSetGenerational(minormul: CInt? = nil, majormul: CInt? = nil) -> GcMode {
        let prevMode = luaswift_setgen(self, minormul ?? 0, majormul ?? 0)
        precondition(prevMode >= 0, "Attempt to call collectorSetGenerational() from within a finalizer.")
        if let result = GcMode(rawValue: prevMode) {
            return result
        } else {
            fatalError("Attempt to call collectorSetGenerational() on a Lua version that doesn't support it")
        }
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
        // Register a metatable for this type with a fixed name to avoid infinite recursion of makeMetatableName
        // trying to call getState()
        let mtName = "LuaSwift_State"
        doRegisterMetatable(typeName: mtName)
        // Note, the _State metatable doesn't need to go in userdataMetatables since maybeGetState() uses
        // unchecked_touserdata() which doesn't consult userdataMetatables.
        pop() // metatable
        push(function: stateLookupKey)
        pushuserdata(state, metatableName: mtName)
        rawset(LUA_REGISTRYINDEX)

        // While we're here, register ClosureWrapper
        // Are we doing too much non-deferred initialization in getState() now?
        register(Metatable(for: LuaClosureWrapper.self))
        register(Metatable(for: LuaContinuationWrapper.self))

        return state
    }

    func maybeGetState() -> _State? {
        push(function: stateLookupKey)
        rawget(LUA_REGISTRYINDEX)
        defer {
            pop()
        }
        // We must call the unchecked version to avoid recursive loops as touserdata calls maybeGetState(). This is
        // safe because we know the value of StateRegistryKey does not need checking.
        return unchecked_touserdata(-1)
    }

    // MARK: - Basic stack stuff

    /// Get the type of the value at the given index.
    ///
    /// - Parameter index: The stack index of the value.
    /// - Returns: The type of the value at `index`, or `nil` for a non-valid but acceptable index.
    ///   `nil` is the equivalent of `LUA_TNONE`, whereas ``LuaType/nil`` is the equivalent of `LUA_TNIL`.
    @inlinable
    public func type(_ index: CInt) -> LuaType? {
        let t = lua_type(self, index)
        return LuaType(ctype: t)
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
    @inlinable
    public func typename(index: CInt) -> String {
        return String(cString: luaL_typename(self, index))
    }

    /// See [lua_absindex](https://www.lua.org/manual/5.4/manual.html#lua_absindex).
    @inlinable
    public func absindex(_ index: CInt) -> CInt {
        return lua_absindex(self, index)
    }

    /// See [lua_isnone](https://www.lua.org/manual/5.4/manual.html#lua_isnone).
    @inlinable
    public func isnone(_ index: CInt) -> Bool {
        return type(index) == nil
    }

    /// See [lua_isnoneornil](https://www.lua.org/manual/5.4/manual.html#lua_isnoneornil).
    @inlinable
    public func isnoneornil(_ index: CInt) -> Bool {
        if let t = type(index) {
            return t == .nil
        } else {
            return true // ie is none
        }
    }

    /// See [lua_isnil](https://www.lua.org/manual/5.4/manual.html#lua_isnil).
    @inlinable
    public func isnil(_ index: CInt) -> Bool {
        return type(index) == .nil
    }

    /// Returns true if the value is an integer.
    ///
    /// Note that this can return false even if `tointeger()` would succeed, in the case of a number which is stored
    /// as floating-point but does have a whole-number representation. Conversely, if `isinteger()` returns `true` then
    /// `tointeger()` will always succeed (`toint()` may not however, if `Int` is a smaller type than `lua_Integer`).
    ///
    /// - Parameter index: The stack index of the value.
    /// - Returns: `true` if the value is a number and that number is stored as an integer, `false` otherwise.
    @inlinable
    public func isinteger(_ index: CInt) -> Bool {
        return lua_isinteger(self, index) != 0
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

    /// Move the item on top of the stack to the given index.
    ///
    /// Move the item on top of the stack to the given index, shifting up the elements above this index to open space.
    ///
    /// - Parameter index: The stack index to move the top item to.
    @inlinable
    public func insert(_ index: CInt) {
        lua_insert(self, index)
    }

    /// See [lua_gettop](https://www.lua.org/manual/5.4/manual.html#lua_gettop).
    @inlinable
    public func gettop() -> CInt {
        return lua_gettop(self)
    }

    /// See [lua_settop](https://www.lua.org/manual/5.4/manual.html#lua_settop).
    @inlinable
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
    @inlinable
    public func newtable(narr: CInt = 0, nrec: CInt = 0) {
        lua_createtable(self, narr, nrec)
    }

    // MARK: - to...() functions

    /// Convert the value at the given stack index to a boolean.
    ///
    /// - Parameter index: The stack index.
    /// - Returns: `true` if the value at the given stack index is anything other than `nil` or `false`.
    @inlinable
    public func toboolean(_ index: CInt) -> Bool {
        let b = lua_toboolean(self, index)
        return b != 0
    }

    /// Return the value at the given index as an integer.
    ///
    /// - Note: Unlike [`lua_tointegerx()`](https://www.lua.org/manual/5.4/manual.html#lua_tointegerx), strings are
    ///   not automatically converted, unless `convert: true` is specified.
    ///
    /// - Parameter index: The stack index.
    /// - Parameter convert: Whether to attempt to convert string values as well as numbers.
    /// - Returns: The integer value, or `nil` if the value was not convertible to an integer.
    public func tointeger(_ index: CInt, convert: Bool = false) -> lua_Integer? {
        if !convert && type(index) != .number {
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

    /// Return the value at the given index as an integer.
    ///
    /// - Note: Unlike [`lua_tointegerx()`](https://www.lua.org/manual/5.4/manual.html#lua_tointegerx), strings are
    ///   not automatically converted, unless `convert: true` is specified.
    ///
    /// - Parameter index: The stack index.
    /// - Parameter convert: Whether to attempt to convert string values as well as numbers.
    /// - Returns: The integer value, or `nil` if the value was not convertible to an `Int`.
    public func toint(_ index: CInt, convert: Bool = false) -> Int? {
        if let int = tointeger(index, convert: convert) {
            return Int(exactly: int)
        } else {
            return nil
        }
    }

    /// Return the value at the given index as a `lua_Number`.
    ///
    /// - Note: Unlike [`lua_tonumberx()`](https://www.lua.org/manual/5.4/manual.html#lua_tonumberx), strings are
    ///   not automatically converted, unless `convert: true` is specified.
    ///
    /// - Parameter index: The stack index.
    /// - Parameter convert: Whether to attempt to convert string values as well as numbers.
    /// - Returns: The number value, or `nil`.
    public func tonumber(_ index: CInt, convert: Bool = false) -> lua_Number? {
        if !convert && type(index) != .number {
            return nil
        }
        var isnum: CInt = 0
        let ret = lua_tonumberx(self, index, &isnum)
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
            push(index: index)
            push(function: luaswift_tostring, toindex: -2) // Below the copy of index
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
    /// `Array`/`Dictionary`/`String`/`[UInt8]` based on their contents:
    ///
    /// * `string` is converted to `String` if the bytes are valid in the default string encoding, otherwise to `[UInt8]`.
    /// * `table` is converted to `Dictionary<AnyHashable, Any>` if there are any non-integer keys in the table,
    ///   otherwise to `Array<Any>`.
    ///
    /// If `guessType` is `false`, the placeholder types ``LuaStringRef`` and ``LuaTableRef`` are used for `string` and
    /// `table` values respectively.
    ///
    /// Regardless of `guessType`, `LuaValue` may be used to represent values that cannot be expressed as Swift types,
    /// for example Lua functions which are not `lua_CFunction`.
    ///
    /// Generally speaking, this API is not very useful, and you should normally use ``tovalue(_:)`` instead, when
    /// needing to do any generics-based programming.
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
            return lua_topointer(self, index)!
        case .number:
            if let intVal = tointeger(index) {
                // Integers are returned type-erased (thanks to AnyHashable) meaning fewer cast restrictions in
                // eg tovalue()
                return AnyHashable(intVal)
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
                // Ugh why can't I test C functions for equality
                if luaswift_iscallclosurewrapper(fn) {
                    pushUpvalue(index: index, n: 1)
                    let wrapper: LuaClosureWrapper = touserdata(-1)!
                    pop()
                    return wrapper.closure
                }
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
    /// The Lua types are each handled as follows:
    /// * `number` can be converted to `lua_Number` or to any integer type providing the value can be represented
    ///    as such, based on what `T` is. A Lua integer can always be converted to a `lua_Number` (ie `Double`)
    ///    providing the value has an exact double-precision representation (ie is less than 2^53). Values are never
    ///    rounded or truncated to satisfy `T`.
    /// * `boolean` converts to `Bool`.
    /// * `string` converts to `String`, `[UInt8]` or `Data` depending on what `T` is. To convert to `String`, the
    ///    string must be valid in the default string encoding. If `T` is `Any` or `AnyHashable`, string values will
    ///    be converted to `String` if possible (given the default string encoding) and to `[UInt8]` otherwise.
    /// * `table` converts to either an array or a dictionary depending on whether `T` is `Array<Element>` or
    ///   `Dictionary<Key, Value>`. The table contents are recursively converted as if `tovalue<Element>()`,
    ///   `tovalue<Key>()` and/or `tovalue<Value>()` were being called, as appropriate. If any element fails to
    ///   cast to the appropriate subtype, then the entire conversion fails and returns `nil`. If `T` is `Any`, a
    ///   `Dictionary<AnyHashable, Any>` is always returned, regardless of whether the Lua table looks more like an
    ///   array or a dictionary. Call ``Lua/Swift/Dictionary/luaTableToArray()-7jqqs`` subsequently if desired.
    ///   Similarly, if `T` is `AnyHashable`, a `Dictionary<AnyHashable, AnyHashable>` will always be returned
    ///   (providing both key and value can be converted to `AnyHashable`).
    /// * `userdata` - providing the value was pushed via `push<U>(userdata:)`, converts to `U` or anything `U` can be
    ///    cast to.
    /// * `function` - if the function is a C function, it is represented by `lua_CFunction`. If the function was pushed
    ///   with ``push(_:numUpvalues:toindex:)``, is represented by ``LuaClosure``. Otherwise it is represented by
    ///   ``LuaValue``. The conversion succeeds if the represented type can be cast to `T`.
    /// * `thread` converts to `LuaState`.
    /// * `lightuserdata` converts to `UnsafeRawPointer`.
    /// 
    /// If `T` is `LuaValue`, the conversion will always succeed for all Lua value types as if ``ref(index:)`` were
    /// called.
    ///
    /// Converting the `nil` Lua value when `T` is `Optional<U>` always succeeds and returns `.some(.none)`. This is the
    /// only case where the Lua `nil` value does not return `nil`. Any behavior described above like "converts to
    /// `SomeType`" or "when `T` is `SomeType`" also applies for any level of nested `Optional` of that type, such as
    /// `SomeType??`.
    ///
    /// If the value cannot be represented by type `T` for any other reason, then `nil` is returned. This includes
    /// numbers being out of range, and tables with keys whose Swift value (according to the rules of `tovalue()`) is
    /// not `Hashable`.
    ///
    /// Converting large tables is relatively expensive, due to the large number of dynamic casts required to correctly
    /// check all the types, although generally this shouldn't be an issue until hundreds of thousands of elements are
    /// involved.
    ///
    /// ```swift
    /// L.push(123)
    /// let intVal: Int = L.tovalue(-1)! // OK
    /// let doubleVal: Double = L.tovalue(-1)! // OK
    /// let smallInt: Int8 = L.tovalue(-1)! // Also OK (since 123 fits in a Int8)
    ///
    /// L.push(["abc": 123, "def": 456])
    /// let dict: [String: Int] = L.tovalue(-1)! // OK
    /// let numDict: [String: Double] = L.tovalue(-1)! // Also OK
    /// ```
    ///
    /// > Important: The exact behavior of `tovalue()` has varied over the course of the 0.x versions of LuaSwift, in
    ///   corner cases such as how strings and tables should be returned from calls to `tovalue<Any>()`. Be sure to
    ///   check that the current behavior described above is as expected.
    public func tovalue<T>(_ index: CInt) -> T? {
        let typeAcceptsAny = (opaqueValue is T)
        let typeAcceptsAnyHashable = (opaqueHashable is T)
        let typeAcceptsAnyOrAnyHashable = typeAcceptsAny || typeAcceptsAnyHashable
        let typeAcceptsLuaValue = (LuaValue.nilValue is T)
        if typeAcceptsLuaValue && !typeAcceptsAnyOrAnyHashable {
            // There's no need to even call toany
            return ref(index: index) as? T
        }

        let value = toany(index, guessType: false)
        if T.self == Any.self && value == nil {
            // Special case this because otherwise in the directCast clause when T = Any, `nil as? Any` will succeed and
            // produce .some(nil)
            return nil
        } else if let ref = value as? LuaStringRef {
            let typeAcceptsString = (emptyString is T)
            if typeAcceptsString, let asString = ref.toString() {
                // Note this means that a T=Any[Hashable] constraint will return a String for preference
                return asString as? T
            }

            let typeAcceptsBytes = (dummyBytes is T)
            if typeAcceptsBytes {
                // [UInt8] is returned in preference to Data, in the case of T=Any[Hashable]
                return ref.toData() as? T
            }
#if !LUASWIFT_NO_FOUNDATION
            let typeAcceptsData = (emptyData is T)
            if typeAcceptsData {
                return Data(ref.toData()) as? T
            }
#endif
        } else if let ref = value as? LuaTableRef {
            if typeAcceptsAny {
                if let dict: Dictionary<AnyHashable, Any> = ref.asAnyDictionary() {
                    return dict as? T
                } else {
                    return nil
                }
            } else if typeAcceptsAnyHashable {
                if let dict: Dictionary<AnyHashable, AnyHashable> = ref.asAnyDictionary() {
                    return dict as? T
                } else {
                    return nil
                }
            } else {
                return ref.resolve()
            }
        } else if let directCast = value as? T {
            return directCast
        }
        return nil
    }

    /// Attempt to convert the value at the given stack index to type `T`.
    ///
    /// This function behaves identically to ``tovalue(_:)`` except for having an explicit `type:` parameter to force
    /// the correct type where inference on the return type is not sufficient.
    @inlinable
    public func tovalue<T>(_ index: CInt, type: T.Type) -> T? {
        return tovalue(index)
    }

    /// Convert a Lua userdata which was created with ``push(userdata:toindex:)`` back to a value of type `T`.
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
    /// function - use ``touserdata(_:)`` or ``tovalue(_:)`` instead.
    ///
    /// - Parameter index: The stack index.
    /// - Parameter type: The `Decodable` type to convert to.
    /// - Returns: A value of type `T`, or `nil` if the value at the given stack position cannot be decoded to `T`.
    @inlinable
    public func todecodable<T: Decodable>(_ index: CInt, type: T.Type) -> T? {
        return todecodable(index)
    }

    /// Convert a value on the stack to a `Decodable` type inferred from the return type.
    ///
    /// If `T` is a composite struct or class type, the Lua representation must be a table with members corresponding
    /// to the Swift member names. Userdata values, or tables containing userdatas, are not convertible using this
    /// function - use ``touserdata(_:)`` or ``tovalue(_:)`` instead.
    ///
    /// - Parameter index: The stack index.
    /// - Returns: A value of type `T`, or `nil` if the value at the given stack position cannot be decoded to `T`.
    public func todecodable<T: Decodable>(_ index: CInt) -> T? {
        let top = gettop()
        defer {
            settop(top)
        }
        let decoder = LuaDecoder(state: self, index: index, codingPath: [])
        return try? decoder.decode(T.self)
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
    @inlinable
    public func toint(_ index: CInt, key: String) -> Int? {
        return get(index, key: key, { toint($0) })
    }

    /// Convenience function that gets a key from the table at `index` and returns it as a `lua_Number`.
    ///
    /// This function may invoke metamethods, and will return `nil` if one errors.
    ///
    /// - Parameter index: The stack index of the table (or table-like object with a `__index` metafield).
    /// - Parameter key: The key to look up.
    /// - Returns: The value as a `lua_Number`, or `nil` if the key was not found, the value was not a number
    ///   or if a metamethod errored.
    @inlinable
    public func tonumber(_ index: CInt, key: String) -> lua_Number? {
        return get(index, key: key, { tonumber($0) })
    }

    /// Convenience function that gets a key from the table at `index` and returns it as a `Bool`.
    ///
    /// This function may invoke metamethods, and will return `false` if one errors.
    ///
    /// - Parameter index: The stack index of the table (or table-like object with a `__index` metafield).
    /// - Parameter key: The key to look up.
    /// - Returns: The value as a `Bool`, or `false` if the key was not found, the value was a false value,
    ///   or if a metamethod errored.
    @inlinable
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
    @inlinable
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
    @inlinable
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
    /// - Parameter resetTop: By default, the stack top is reset on exit and each time through the iterator to what it
    ///   was at the point of calling `ipairs`. Occasionally this is not desirable and can be disabled by setting
    ///   `resetTop` to false.
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
    ///     // top of stack contains `L.rawget(value, key: i)`
    /// }
    ///
    /// // Compared to:
    /// try L.for_ipairs(-1) { i in
    ///     // top of stack contains `L.get(value, key: i)`
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

            push(index: index) // Push first as could be relative index
            push(wrapper, toindex: -2)
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
            top = L.gettop()
            L.pushnil() // initial k
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
    /// value which are pushed on to the stack. The `__pairs` metafield is ignored if the
    /// table has one, that is to say raw accesses are used.
    ///
    /// To iterate with non-raw accesses, use ``for_pairs(_:_:)`` instead.
    ///
    /// The indexes to the key and value will always be `top+1` and `top+2`, where `top` is the value of `gettop()`
    /// prior to the call to `pairs()`, thus are provided for convenience only. `-2` and `-1` can be used instead, if
    /// desired. The stack is reset to `top` at the end of each iteration through the loop.
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
    /// This function only exposed for implementations of pairs iterators to use, thus usually should not be called
    /// directly. The value is popped from the stack.
    ///
    /// Returns: `false` (and pushes `next, value, nil`) if the value isn't iterable, otherwise `true`.
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
            }, toindex: -2) // push next below value
            L.pushnil()
            return isTable
        } else {
            insert(-2) // Push __pairs below value
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
            push(wrapper, toindex: -4) // Push wrapper below iterfn, state, initval
            try pcall(nargs: 3, nret: 0)
        }
    }

    // MARK: - push() functions

    /// Push a nil value on to the stack.
    ///
    /// - Parameter toindex: See <doc:LuaState#Push-functions-toindex-parameter>.
    @inlinable
    public func pushnil(toindex: CInt = -1) {
        lua_pushnil(self)
        if toindex != -1 {
            insert(toindex)
        }
    }

    /// Push the **fail** value on to the stack.
    ///
    /// Currently (in Lua 5.4) this function behaves identically to `pushnil()`.
    ///
    /// - Parameter toindex: See <doc:LuaState#Push-functions-toindex-parameter>.
    @inlinable
    public func pushfail(toindex: CInt = -1) {
        pushnil(toindex: toindex)
    }

    /// Pushes a copy of the element at the given index on to the stack.
    ///
    /// - Parameter index: Stack index of the value to copy.
    /// - Parameter toindex: See <doc:LuaState#Push-functions-toindex-parameter>.
    @inlinable
    public func push(index: CInt, toindex: CInt = -1) {
        lua_pushvalue(self, index)
        if toindex != -1 {
            insert(toindex)
        }
    }

    /// Push anything which conforms to `Pushable` on to the stack.
    ///
    /// - Parameter value: Any Swift value which conforms to ``Pushable``.
    /// - Parameter toindex: See <doc:LuaState#Push-functions-toindex-parameter>.
    @inlinable
    public func push<T>(_ value: T?, toindex: CInt = -1) where T: Pushable {
        if let value = value {
            value.push(onto: self)
        } else {
            pushnil()
        }
        if toindex != -1 {
            insert(toindex)
        }
    }

    /// Push a String on to the stack, using the default string encoding.
    ///
    /// See ``getDefaultStringEncoding()``.
    ///
    /// - Parameter string: The `String` to push.
    /// - Parameter toindex: See <doc:LuaState#Push-functions-toindex-parameter>.
    /// - Precondition: The string must be representable in the default encoding (in cases where the encoding cannot
    ///   represent all of Unicode).
    public func push(string: String, toindex: CInt = -1) {
#if LUASWIFT_NO_FOUNDATION
        let data = Array<UInt8>(string.utf8)
        push(data, toindex: toindex)
#else
        push(string: string, encoding: getDefaultStringEncoding(), toindex: toindex)
#endif
    }

    /// Push a String on to the stack, using UTF-8 string encoding.
    ///
    /// - Note: If `LUASWIFT_NO_FOUNDATION` is defined, this function behaves identically to ``push(string:toindex:)``.
    ///
    /// - Parameter utf8String: The `String` to push.
    /// - Parameter toindex: See <doc:LuaState#Push-functions-toindex-parameter>.
    public func push(utf8String string: String, toindex: CInt = -1) {
#if LUASWIFT_NO_FOUNDATION
        push(string: string, toindex: toindex)
#else
        push(string: string, encoding: .utf8, toindex: toindex)
#endif
    }

    /// Push a byte array on to the stack, as a Lua `string`.
    ///
    /// - Parameter data: the data to push.
    /// - Parameter toindex: See <doc:LuaState#Push-functions-toindex-parameter>.
    public func push(_ data: [UInt8], toindex: CInt = -1) {
        data.withUnsafeBytes { rawBuf in
            push(rawBuf, toindex: toindex)
        }
    }

    /// Push a `lua_CFunction` on to the stack.
    ///
    /// Functions or closures implemented in Swift that conform to `(LuaState?) -> CInt` may be pushed using this API
    /// only if they:
    ///
    /// * Do not throw Swift or Lua errors
    /// * Do not capture any variables
    ///
    /// If the above conditions do not hold, push a ``LuaClosure`` using ``push(_:numUpvalues:toindex:)`` instead.
    ///
    /// - Parameter function: the function or closure to push.
    /// - Parameter toindex: See <doc:LuaState#Push-functions-toindex-parameter>.
    @inlinable
    public func push(function: lua_CFunction, toindex: CInt = -1) {
        lua_pushcfunction(self, function)
        if toindex != -1 {
            insert(toindex)
        }
    }

    /// Push a function or closure of type `LuaClosure` on to the stack as a Lua function.
    ///
    /// See ``LuaClosure`` for a discussion of how LuaClosures behave.
    ///
    /// `closure` may use upvalues in the same was as
    /// [`lua_pushcclosure`](https://www.lua.org/manual/5.4/manual.html#lua_pushcclosure) with one exception: They start
    /// at index 1 plus ``LuaClosureWrapper/NumInternalUpvalues``, rather than `1`, due to the housekeeping required to
    /// perform the Lua-Swift bridging. Normally however, you would use Swift captures rather than Lua upvalues to
    /// access variables from within `closure` and thus `numUpvalues` would normally be omitted or `0`.
    ///
    /// Example:
    ///
    /// ```swift
    /// L.push({ L in
    ///     let arg: Int = try L.checkArgument(1)
    ///     // ...
    ///     return 0
    /// })
    /// ```
    ///
    /// - Parameter closure: the function or closure to push.
    /// - Parameter numUpvalues: The number of upvalues to add to the closure.
    /// - Parameter toindex: See <doc:LuaState#Push-functions-toindex-parameter>.
    public func push(_ closure: @escaping LuaClosure, numUpvalues: CInt = 0, toindex: CInt = -1) {
        LuaClosureWrapper(closure).push(onto: self, numUpvalues: numUpvalues)
        if toindex != -1 {
            insert(toindex)
        }
    }

    /// Push a zero-arguments closure on to the stack as a Lua function.
    ///
    /// The Lua function when called will call `closure`. If the closure throws an error, it will be converted to a
    /// Lua error using ``push(error:toindex:)``.
    ///
    /// The Swift closure may return any value which can be translated using ``push(tuple:)``. This includes returning
    /// Void (meaning the Lua function returns no results) or returning a tuple of N values (meaning the Lua function
    /// returns N values).
    ///
    /// ```swift
    /// L.push(closure: {
    ///     print("I am callable from Lua!")
    /// })
    /// L.push(closure: {
    ///     return "I am callable and return a result"
    /// })
    /// L.push(closure: {
    ///     return ("I return multiple results", "result #2")
    /// })
    /// ```
    ///
    /// - Parameter closure: The closure to push.
    /// - Parameter toindex: See <doc:LuaState#Push-functions-toindex-parameter>.
    public func push<Ret>(closure: @escaping () throws -> Ret, toindex: CInt = -1) {
        push(Self.makeClosure(closure), toindex: toindex)
    }

    /// Push a one-argument closure on to the stack as a Lua function.
    ///
    /// The Lua function when called will call `closure`, converting its arguments to match the signature of `closure`.
    /// If arguments cannot be converted, a Lua error will be thrown. As with standard Lua function calls, excess
    /// arguments are discarded and any shortfall are filled in with `nil`.
    ///
    /// If `closure` throws an error, it will be converted to a Lua error using ``push(error:toindex:)``.
    ///
    /// The Swift closure may return any value which can be translated using ``push(tuple:)``. This includes returning
    /// Void (meaning the Lua function returns no results) or returning a tuple of N values (meaning the Lua function
    /// returns N values).
    ///
    /// ```swift
    /// L.push(closure: { (arg: String?) in
    ///     // ...
    /// })
    /// L.push(closure: { (arg: String?) -> Int in
    ///     // ...
    /// })
    /// ```
    ///
    /// - Note: There is an ambiguity if pushing a closure which takes a `LuaState?` and returns a `CInt` if _also_
    ///   using the [trailing closure](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/closures#Trailing-Closures)
    ///   syntax - the wrong overload of `push()` will be called. To avoid this ambiguity, do not use the trailing
    ///   closure syntax in such cases and call as `push(closure: {...})`.
    ///
    /// - Parameter closure: The closure to push.
    /// - Parameter toindex: See <doc:LuaState#Push-functions-toindex-parameter>.
    public func push<Arg1, Ret>(closure: @escaping (Arg1) throws -> Ret, toindex: CInt = -1) {
        push(Self.makeClosure(closure), toindex: toindex)
    }

    /// Push a two-argument closure on to the stack as a Lua function.
    ///
    /// The Lua function when called will call `closure`, converting its arguments to match the signature of `closure`.
    /// If arguments cannot be converted, a Lua error will be thrown. As with standard Lua function calls, excess
    /// arguments are discarded and any shortfall are filled in with `nil`.
    ///
    /// If `closure` throws an error, it will be converted to a Lua error using ``push(error:toindex:)``.
    ///
    /// The Swift closure may return any value which can be translated using ``push(tuple:)``. This includes returning
    /// Void (meaning the Lua function returns no results) or returning a tuple of N values (meaning the Lua function
    /// returns N values).
    ///
    /// ```swift
    /// L.push(closure: { (arg1: String?, arg2: Int?) in
    ///     // ...
    /// })
    /// L.push(closure: { (arg1: String?, arg2: Int?) -> Int in
    ///     // ...
    /// })
    /// ```
    ///
    /// - Parameter closure: The closure to push.
    /// - Parameter toindex: See <doc:LuaState#Push-functions-toindex-parameter>.
    public func push<Arg1, Arg2, Ret>(closure: @escaping (Arg1, Arg2) throws -> Ret, toindex: CInt = -1) {
        push(Self.makeClosure(closure), toindex: toindex)
    }

    /// Push a three-argument closure on to the stack as a Lua function.
    ///
    /// The Lua function when called will call `closure`, converting its arguments to match the signature of `closure`.
    /// If arguments cannot be converted, a Lua error will be thrown. As with standard Lua function calls, excess
    /// arguments are discarded and any shortfall are filled in with `nil`.
    ///
    /// If `closure` throws an error, it will be converted to a Lua error using ``push(error:toindex:)``.
    ///
    /// The Swift closure may return any value which can be translated using ``push(tuple:)``. This includes returning
    /// Void (meaning the Lua function returns no results) or returning a tuple of N values (meaning the Lua function
    /// returns N values).
    ///
    /// ```swift
    /// L.push(closure: { (arg1: String?, arg2: Int?, arg3: Any?) in
    ///     // ...
    /// })
    /// L.push(closure: { (arg1: String?, arg2: Int?, arg3: Any?) -> Int in
    ///     // ...
    /// })
    /// ```
    ///
    /// - Parameter closure: The closure to push.
    /// - Parameter toindex: See <doc:LuaState#Push-functions-toindex-parameter>.
    public func push<Arg1, Arg2, Arg3, Ret>(closure: @escaping (Arg1, Arg2, Arg3) throws -> Ret, toindex: CInt = -1) {
        push(Self.makeClosure(closure), toindex: toindex)
    }

    internal static func makeClosure<Ret>(_ closure: @escaping () throws -> Ret) -> LuaClosure {
        return { L in
            return L.push(tuple: try closure())
        }
    }

    internal static func makeClosure<Arg1, Ret>(_ closure: @escaping (Arg1) throws -> Ret) -> LuaClosure {
        return { L in
            let arg1: Arg1 = try L.checkArgument(1)
            return L.push(tuple: try closure(arg1))
        }
    }

    internal static func makeClosure<Arg1, Arg2, Ret>(_ closure: @escaping (Arg1, Arg2) throws -> Ret) -> LuaClosure {
        return { L in
            let arg1: Arg1 = try L.checkArgument(1)
            let arg2: Arg2 = try L.checkArgument(2)
            return L.push(tuple: try closure(arg1, arg2))
        }
    }

    internal static func makeClosure<Arg1, Arg2, Arg3, Ret>(_ closure: @escaping (Arg1, Arg2, Arg3) throws -> Ret) -> LuaClosure {
        return { L in
            let arg1: Arg1 = try L.checkArgument(1)
            let arg2: Arg2 = try L.checkArgument(2)
            let arg3: Arg3 = try L.checkArgument(3)
            return L.push(tuple: try closure(arg1, arg2, arg3))
        }
    }

    internal static func makeClosure<Arg1, Arg2, Arg3, Arg4, Ret>(_ closure: @escaping (Arg1, Arg2, Arg3, Arg4) throws -> Ret) -> LuaClosure {
        return { L in
            let arg1: Arg1 = try L.checkArgument(1)
            let arg2: Arg2 = try L.checkArgument(2)
            let arg3: Arg3 = try L.checkArgument(3)
            let arg4: Arg4 = try L.checkArgument(4)
            return L.push(tuple: try closure(arg1, arg2, arg3, arg4))
        }
    }

    /// Push any value representable using `Any` on to the stack as a `userdata`.
    ///
    /// From a lifetime perspective, this function behaves as if the value were
    /// assigned to another variable of type `Any`, and when the Lua userdata is
    /// garbage collected, this variable goes out of scope.
    ///
    /// To make the object usable from Lua, declare a metatable for the value's type using
    /// ``register(_:)-8rgnn``. Note that this function always uses the dynamic type of the value, and
    /// not whatever `T` is, when calculating what metatable to assign the object. Thus `push(userdata: foo)` and
    /// `push(userdata: foo as Any)` will behave identically. Pushing a value of a type which has no metatable
    /// previously registered will generate a warning, and the object will have no metamethods declared on it,
    /// except for `__gc` which is always defined in order that Swift object lifetimes are preserved.
    ///
    /// - Note: This function always pushes a `userdata` - if `val` represents any other type (for example, an integer)
    ///   it will not be converted to that type in Lua. Use ``push(any:toindex:)`` instead to automatically convert
    ///   types to their Lua native representation where possible.
    /// - Parameter userdata: The value to push on to the Lua stack.
    /// - Parameter toindex: See <doc:LuaState#Push-functions-toindex-parameter>.
    public func push<T>(userdata: T, toindex: CInt = -1) {
        let anyval: Any = userdata
        let tname = makeMetatableName(for: Swift.type(of: anyval))
        pushuserdata(anyval, metatableName: tname)
        if toindex != -1 {
            insert(toindex)
        }
    }

    private func pushuserdata(_ val: Any, metatableName: String) {
        let udata = luaswift_newuserdata(self, MemoryLayout<Any>.size)!
        let udataPtr = udata.bindMemory(to: Any.self, capacity: 1)
        udataPtr.initialize(to: val)
        pushmetatable(name: metatableName)
        lua_setmetatable(self, -2) // pops metatable
    }

    /// Push the metatable for type `T` on to the stack.
    ///
    /// Pushes on to the stack the metatable that is used by ``push(userdata:toindex:)`` for dynamic type `T`. This
    /// might be the default metatable, or an empty generated metatable if `T` has not been registered and no default
    /// has been set.
    ///
    /// Normally there is no need to call this function because `push(userdata:)` takes care of it, but it can
    /// occasionally be useful to modify the metatable after it has been created by `register(_:)`. For example, to
    /// add a `__metatable` field.
    public func pushMetatable<T>(for type: T.Type) {
        let tname = makeMetatableName(for: type)
        pushmetatable(name: tname)
    }

    private func pushmetatable(name: String) {
        if luaL_getmetatable(self, name) == LUA_TNIL {
            pop()
            if luaL_getmetatable(self, Self.DefaultMetatableName) == LUA_TTABLE {
                // All good
            } else {
                pop()
                print("Implicitly registering empty metatable for type \(name)")
                doRegisterMetatable(typeName: name)
                getState().userdataMetatables.insert(lua_topointer(self, -1))
            }
        }
    }

    /// Convert any Swift value to a Lua value and push on to the stack.
    ///
    /// To convert the value, the following logic is applied in order, stopping at the first matching clause:
    ///
    /// * If `value` is `nil`, `Void` (ie the empty tuple), or `.some(.none)` it is pushed as `nil`.
    /// * If `value` conforms to ``Pushable``, Pushable's ``Pushable/push(onto:)`` is used.
    /// * If `value` is `[UInt8]`, ``push(_:toindex:)-171ku`` is used.
    /// * If `value` is `UInt8`, it is pushed as an integer. This special case is required because `UInt8` is not
    ///   `Pushable`.
    /// * If `value` conforms to `ContiguousBytes` (which includes `Data`), then ``push(bytes:toindex:)`` is used.
    /// * If `value` is one of the Foundation types `NSNumber`, `NSString` or `NSData`, or is a Core Foundation type
    ///   that is toll-free bridged to one of those types, then it is pushed as a `NSNumber`, `String`, or `Data`
    ///   respectively.
    /// * If `value` is an `Array` or `Dictionary` that is not `Pushable`, `push(any:)` is called recursively to push
    ///   its elements.
    /// * If `value` is a `lua_CFunction`, ``push(function:toindex:)`` is used.
    /// * If `value` is a `LuaClosure`, ``push(_:numUpvalues:toindex:)`` is used (with `numUpvalues=0`).
    /// * If `value` is a zero-argument closure that returns `Void` or `Any?`, it is pushed using `push(closure:)`.
    ///   Due to limitations in Swift type inference, these are the only closure types that are handled in this way.
    /// * Any other type is pushed as a `userdata` using ``push(userdata:toindex:)``.
    ///
    /// - Parameter value: The value to push on to the Lua stack.
    /// - Parameter toindex: See <doc:LuaState#Push-functions-toindex-parameter>.
    public func push(any value: Any?, toindex: CInt = -1) {
        guard let value else {
            pushnil(toindex: toindex)
            return
        }
        if value is Void {
            pushnil(toindex: toindex)
            return
        }

        // It is really hard to unwrap an Optional<T> that's been stuffed into an Any... this is the only way I've found
        // that works and lets you check if the inner value is nil. Note this can't be part of the main switch below,
        // because _everything_ matches this case.
        switch value {
        case let opt as Optional<Any>:
            if opt == nil {
                pushnil(toindex: toindex)
                return
            }
        }

        switch value {
        case let pushable as Pushable:
            push(pushable)
        // I don't have strong enough confidence that I understand how bridged strings (CFStringRef, _NSCFString,
        // NSTaggedString, __StringStorage, who knows how many others) behave to declare Pushable conformance that would
        // definitely work for all string types - this however should cover all possibilities.
        case let str as String:
            push(string: str)
        case let uint as UInt8:
            push(Int(uint))
        case let data as [UInt8]:
            push(data)
#if !LUASWIFT_NO_FOUNDATION
        case let data as ContiguousBytes:
            push(bytes: data)
        case let data as NSData:
            // Apparently NSData subtypes don't cast with `foo as Data` but *do* with `(foo as NSData) as Data`. WTF?
            // But using UnsafeRawBufferPointer is probably slightly more efficient than `data as Data` here.
            push(UnsafeRawBufferPointer(start: data.bytes, count: data.length))
#endif
        case let array as Array<Any>:
            newtable(narr: CInt(array.count))
            for (i, val) in array.enumerated() {
                push(any: val)
                lua_rawseti(self, -2, lua_Integer(i + 1))
            }
        case let dict as Dictionary<AnyHashable, Any>:
            newtable(nrec: CInt(dict.count))
            for (k, v) in dict {
                push(any: k)
                push(any: v)
                lua_rawset(self, -3)
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

        if toindex != -1 {
            insert(toindex)
        }
    }

    /// Push an N-tuple on to the Lua stack as N values.
    ///
    /// If the argument is a tuple, it is unpacked and each element is pushed on to the stack in order using
    /// [`push(any:)`](doc:Lua/Swift/UnsafeMutablePointer/push(any:toindex:)), and the number of values pushed is
    /// returned. If the argument is not a tuple, it is pushed using
    /// [`push(any:)`](doc:Lua/Swift/UnsafeMutablePointer/push(any:toindex:))  and `1` is returned.
    ///
    /// The empty tuple `()` (also written `Void`) results in zero values being pushed. An optional of any type which is
    /// `.none` will result in 1 value (`nil`) being pushed. Due to limitations in the Swift type system, tuples with
    /// more than 10 elements are not supported and will be pushed as a single userdata value as per the fallback
    /// behavior of `push(any:)`. Nested tuples are also not supported. If the argument is a named tuple, the names
    /// are ignored and it is treated the same as an unnamed tuple.
    ///
    /// ```swift
    /// let numItems = L.push(tuple: (1, "hello", true)) // Pushes 3 values
    /// ```
    ///
    /// > Note: This is the only `push()` function which does not always push exactly 1 value on to the stack.
    ///
    /// - Parameter tuple: Any value.
    /// - Returns: The number of values pushed on to the stack.
    public func push(tuple: Any) -> CInt {
        if tuple is () {
            // Empty tuple, push zero values
            return 0
        }
        switch tuple {
        case let (a, b) as (Any, Any):
            push(any: a)
            push(any: b)
            return 2
        case let (a, b, c) as (Any, Any, Any):
            push(any: a)
            push(any: b)
            push(any: c)
            return 3
        case let (a, b, c, d) as (Any, Any, Any, Any):
            push(any: a)
            push(any: b)
            push(any: c)
            push(any: d)
            return 4
        case let (a, b, c, d, e) as (Any, Any, Any, Any, Any):
            push(any: a)
            push(any: b)
            push(any: c)
            push(any: d)
            push(any: e)
            return 5
        case let (a, b, c, d, e, f) as (Any, Any, Any, Any, Any, Any):
            push(any: a)
            push(any: b)
            push(any: c)
            push(any: d)
            push(any: e)
            push(any: f)
            return 6
        case let (a, b, c, d, e, f, g) as (Any, Any, Any, Any, Any, Any, Any):
            push(any: a)
            push(any: b)
            push(any: c)
            push(any: d)
            push(any: e)
            push(any: f)
            push(any: g)
            return 7
        case let (a, b, c, d, e, f, g, h) as (Any, Any, Any, Any, Any, Any, Any, Any):
            push(any: a)
            push(any: b)
            push(any: c)
            push(any: d)
            push(any: e)
            push(any: f)
            push(any: g)
            push(any: h)
            return 8
        case let (a, b, c, d, e, f, g, h, i) as (Any, Any, Any, Any, Any, Any, Any, Any, Any):
            push(any: a)
            push(any: b)
            push(any: c)
            push(any: d)
            push(any: e)
            push(any: f)
            push(any: g)
            push(any: h)
            push(any: i)
            return 9
        case let (a, b, c, d, e, f, g, h, i, j) as (Any, Any, Any, Any, Any, Any, Any, Any, Any, Any):
            push(any: a)
            push(any: b)
            push(any: c)
            push(any: d)
            push(any: e)
            push(any: f)
            push(any: g)
            push(any: h)
            push(any: i)
            push(any: j)
            return 10
        default: // Also covers the single-argument case
            push(any: tuple)
            return 1
        }
    }

    /// Push a Swift Error on to the Lua stack.
    ///
    /// If `error` also conforms to `Pushable`, then ``Pushable/push(onto:)`` is used. This includes ``LuaCallError``,
    /// ``LuaLoadError``, and errors returned by ``error(_:)-swift.method``, all of which push the underlying Lua
    /// error value unmodified.
    ///
    /// For any other Error type, the string `"Swift error: \(error.localizedDescription)"` is pushed.
    ///
    /// - Parameter error: The error to push on to the Lua stack.
    /// - Parameter toindex: See <doc:LuaState#Push-functions-toindex-parameter>.
    public func push(error: Error, toindex: CInt = -1) {
        if let pushable = error as? Pushable {
            push(pushable, toindex: toindex)
        } else {
#if LUASWIFT_NO_FOUNDATION
            push("Swift error: \(String(describing: error))", toindex: toindex)
#else
            push("Swift error: \(error.localizedDescription)", toindex: toindex)
#endif
        }
    }

    /// Pushes the thread represented by `self` onto the stack.
    ///
    /// Pushes the thread represented by `self` onto its stack. Note that `LuaState` also conforms to `Pushable` so
    /// can be pushed that way as well:
    ///
    /// ```swift
    /// L.pushthread()
    /// // Equivalent to
    /// L.push(L)
    /// ```
    ///
    /// - Returns: `true` if this thread is the main thread of its state.
    @discardableResult
    public func pushthread() -> Bool {
        return lua_pushthread(self) == 1
    }

    // MARK: - Calling into Lua

    /// Make a protected call to a Lua function, optionally including a stack trace in any errors.
    ///
    /// The function and any arguments must already be pushed to the stack in the same way as for
    /// [`lua_pcall()`](https://www.lua.org/manual/5.4/manual.html#lua_pcall)
    /// and are popped from the stack by this call. Unless the function errors,
    /// `nret` result values are then pushed to the stack.
    ///
    /// - Parameter nargs: The number of arguments to pass to the function.
    /// - Parameter nret: The number of expected results. Can be ``MultiRet``
    ///   to keep all returned values.
    /// - Parameter traceback: If true, any errors thrown will include a
    ///   full stack trace.
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the execution of the function.
    /// - Precondition: The top of the stack must contain a function/callable and `nargs` arguments.
    @inlinable
    public func pcall(nargs: CInt, nret: CInt, traceback: Bool = true) throws {
        try pcall(nargs: nargs, nret: nret, msgh: traceback ? defaultTracebackFn : nil)
    }

    /// Make a protected call to a Lua function, optionally specifying a custom message handler.
    ///
    /// The function and any arguments must already be pushed to the stack in the same way as for
    /// [`lua_pcall()`](https://www.lua.org/manual/5.4/manual.html#lua_pcall)
    /// and are popped from the stack by this call. Unless the function errors,
    /// `nret` result values are then pushed to the stack.
    ///
    /// - Parameter nargs: The number of arguments to pass to the function.
    /// - Parameter nret: The number of expected results. Can be ``MultiRet``
    ///   to keep all returned values.
    /// - Parameter msgh: An optional message handler function to be called if the function errors.
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the execution of the function.
    /// - Precondition: The top of the stack must contain a function/callable and `nargs` arguments.
    public func pcall(nargs: CInt, nret: CInt, msgh: lua_CFunction?) throws {
        if let error = trypcall(nargs: nargs, nret: nret, msgh: msgh) {
            throw error
        }
    }

    /// Make a protected call to a Lua function, returning a `LuaCallError` if an error occurred.
    ///
    /// The function and any arguments must already be pushed to the stack in the same way as for
    /// [`lua_pcall()`](https://www.lua.org/manual/5.4/manual.html#lua_pcall)
    /// and are popped from the stack by this call. If the function errors, no results are pushed
    /// to the stack and a `LuaCallError` is returned. Otherwise `nret` results are pushed and `nil`
    /// is returned.
    ///
    /// - Parameter nargs: The number of arguments to pass to the function.
    /// - Parameter nret: The number of expected results. Can be ``MultiRet``
    ///   to keep all returned values.
    /// - Parameter msgh: An optional message handler function to be called if the function errors.
    /// - Returns: A `LuaCallError` if the function errored, `nil` otherwise.
    public func trypcall(nargs: CInt, nret: CInt, msgh: lua_CFunction?) -> LuaCallError? {
        let index: CInt
        if let msghFn = msgh {
            index = gettop() - nargs
            push(function: msghFn, toindex: index)
        } else {
            index = 0
        }
        let error = trypcall(nargs: nargs, nret: nret, msgh: index)
        if index != 0 {
            // Keep the stack balanced
            lua_remove(self, index)
        }
        return error
    }

    /// Make a protected call to a Lua function, returning a `LuaCallError` if an error occurred.
    ///
    /// The function and any arguments must already be pushed to the stack in the same way as for
    /// [`lua_pcall()`](https://www.lua.org/manual/5.4/manual.html#lua_pcall)
    /// and are popped from the stack by this call. If the function errors, no results are pushed
    /// to the stack and a `LuaCallError` is returned. Otherwise `nret` results are pushed and `nil`
    /// is returned.
    ///
    /// - Parameter nargs: The number of arguments to pass to the function.
    /// - Parameter nret: The number of expected results. Can be ``MultiRet``
    ///   to keep all returned values.
    /// - Parameter msgh: The stack index of a message handler function, or `0` to specify no
    ///   message handler. The handler is not popped from the stack.
    /// - Returns: A `LuaCallError` if the function errored, `nil` otherwise.
    public func trypcall(nargs: CInt, nret: CInt, msgh: CInt) -> LuaCallError? {
        let err = lua_pcall(self, nargs, nret, msgh)
        if err == LUA_OK {
            return nil
        } else {
            return LuaCallError.popFromStack(self)
        }
    }

    /// Convenience zero-result wrapper around ``Lua/Swift/UnsafeMutablePointer/pcall(nargs:nret:traceback:)``.
    ///
    /// Make a protected call to a Lua function that must already be pushed
    /// on to the stack. Each of `arguments` is pushed using ``push(any:toindex:)``. The
    /// function is popped from the stack and any results are discarded.
    ///
    /// - Parameter arguments: Arguments to pass to the Lua function.
    /// - Parameter traceback: If true, any errors thrown will include a
    ///   full stack trace.
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the execution of the function.
    /// - Precondition: The value at the top of the stack must refer to a Lua function or callable.
    @inlinable
    public func pcall(_ arguments: Any?..., traceback: Bool = true) throws {
        try pcall(arguments: arguments, traceback: traceback)
    }

    /// Like `pcall(arguments...)` but using an explicit array for the arguments.
    ///
    /// See ``pcall(_:traceback:)-2ujhj``.
    @inlinable
    public func pcall(arguments: [Any?], traceback: Bool = true) throws {
        for arg in arguments {
            push(any: arg)
        }
        try pcall(nargs: CInt(arguments.count), nret: 0, traceback: traceback)
    }

    /// Convenience one-result wrapper around ``Lua/Swift/UnsafeMutablePointer/pcall(nargs:nret:traceback:)``.
    ///
    /// Make a protected call to a Lua function that must already be pushed
    /// on to the stack. Each of `arguments` is pushed using ``push(any:toindex:)``. The
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
    @inlinable
    public func pcall<T>(_ arguments: Any?..., traceback: Bool = true) throws -> T? {
        return try pcall(arguments: arguments, traceback: traceback)
    }

    /// Like `pcall(arguments...)` but using an explicit array for the arguments.
    ///
    /// See ``pcall(_:traceback:)-3qlin``.
    @inlinable
    public func pcall<T>(arguments: [Any?], traceback: Bool = true) throws -> T? {
        for arg in arguments {
            push(any: arg)
        }
        try pcall(nargs: CInt(arguments.count), nret: 1, traceback: traceback)
        let result: T? = tovalue(-1)
        pop(1)
        return result
    }

    /// Make a protected call to a Lua function which is allowed to yield.
    ///
    /// Like ``pcallk(nargs:nret:traceback:continuation:)`` but allowing a custom message handler function to be
    /// specified.
    public func pcallk(nargs: CInt, nret: CInt, msgh: lua_CFunction?, continuation: @escaping LuaPcallContinuation) -> CInt {
        setupContinuationParams(nargs: nargs, nret: nret, msgh: msgh, continuation: continuation)

        // The actual lua_pcallk() call is done from handleClosureResult() (called from luaswift_callclosurewrapper)
        // so as to have fully unwound the Swift stack frame back to a C context. That way we don't have to worry about
        // longjmps exiting Swift stack frames. And we use another magic return value to indicate this.
        return LUASWIFT_CALLCLOSURE_PCALLK
    }

    private func setupContinuationParams(nargs: CInt, nret: CInt, msgh: lua_CFunction?, continuation: @escaping LuaPcallContinuation) {
        checkstack(4)
        let fnPos = gettop() - nargs
        let wrapper = LuaContinuationWrapper(continuation)
        push(userdata: wrapper, toindex: fnPos)
        if let msgh {
            push(function: msgh, toindex: fnPos)
        } else {
            pushnil(toindex: fnPos)
        }
        push(nargs)
        push(nret)
        // stack is now: msgh, continuation, fn, [args...], nargs, nret

        // Check that the continuation registry val is set up
        rawset(LUA_REGISTRYINDEX, key: .function(luaswift_continuation_regkey), value: .function(LuaClosureWrapper.callContinuation))
    }

    /// Make a protected call to a Lua function which is allowed to yield.
    ///
    /// Make a yieldable call to a Lua function.
    ///
    /// This is the LuaSwift equivalent to [`lua_pcallk()`](https://www.lua.org/manual/5.4/manual.html#lua_pcallk).
    /// See [Handling Yields in C](https://www.lua.org/manual/5.4/manual.html#4.5) for more details. This function
    /// behaves similarly to `lua_pcallk`, with the exception that the continuation function is passed in as a
    /// `LuaPcallContinuation` rather than a `lua_KFunction`, and does not need the additional explicit call to the
    /// continuation function in the case where no yield occurs.
    ///
    /// For example, where a yieldable `lua_CFunction` implemented in C might look like this:
    ///
    /// ```c
    /// int my_cfunction(lua_State *L) {
    ///     /* stuff */
    ///     return continuation(L, lua_pcallk(L, nargs, nret, msgh, ctx, continuation), ctx);
    /// }
    ///
    /// int continuation(lua_State *L, int status, lua_KContext ctx) {
    ///     /* continuation */
    /// }
    /// ```
    ///
    /// The equivalent written in Swift would be:
    ///
    /// ```swift
    /// let my_closure: LuaClosure = { L in
    ///     /* stuff */
    ///     return L.pcallk(nargs: nargs, nret: nret, continuation: { L, status in
    ///         /* continuation */
    ///     })
    /// }
    /// ```
    ///
    /// > Important: `pcallk()` must only be called from within a `LuaClosure` which is being executed by Lua having
    ///   been pushed via ``Lua/Swift/UnsafeMutablePointer/push(_:numUpvalues:toindex:)``, must be the last call in the
    ///   closure, and must be called with exactly the syntax `return L.pcallk(...)` where `L` is the same `LuaState`
    ///   as passed into the `LuaClosure`. Any other usage will result in undefined behavior. Calling `lua_pcallk()`
    ///   directly from Swift is not safe, for reasons similar to why `lua_call()` isn't.
    ///
    /// * If the call does not yield or error, `continuation` will be called with `status.yielded = false`,
    ///   `status.error = nil`, and the results of the call adjusted to `nret` extra values on the stack.
    /// * If the call errors, `continuation` be called with `status.error` set to a ``LuaCallError``, and the stack as
    ///   it was before the call (minus the `nargs` and function, and without any values added).
    /// * If the call yields, `continuation` will be called if/when the current thread is resumed with
    ///   `status.yielded = true` and the values passed to the resume call adjusted to `nret` extra values on the stack.
    ///
    /// In all cases the result of the `LuaClosure` will be whatever `continuation` throws or returns. The continuation
    /// closure may itself call `pcallk()`, providing that the `pcallk()` is the last call in the continuation closure,
    /// and specifies its own continuation. If the call yields and the thread is never resumed, the continuation
    /// closure will not be deinited until after the thread has been closed or garbage collected.
    ///
    /// - Parameter nargs: The number of arguments to pass to the function.
    /// - Parameter nret: The number of expected results to be passed to the continuation. Can be ``MultiRet`` to keep
    ///   all returned values.
    /// - Parameter traceback: If true, any error from the call will include a full stack trace.
    /// - Parameter continuation: Continuation to execute once the call has completed or errored (or, if the call
    ///   yielded, once the thread is resumed).
    /// - Precondition: The top of the stack must contain a function/callable and `nargs` arguments.
    @inlinable
    public func pcallk(nargs: CInt, nret: CInt, traceback: Bool = true, continuation: @escaping LuaPcallContinuation) -> CInt {
        return pcallk(nargs: nargs, nret: nret, msgh: traceback ? defaultTracebackFn : nil, continuation: continuation)
    }

    /// Call a Lua function which is allowed to yield.
    ///
    /// Behaves identically to ``pcallk(nargs:nret:traceback:continuation:)`` except for the call not being called
    /// protected, and therefore that the continuation will not be called if an error occurs. The same caveats apply, in
    /// that `callk` can only be called as return from a `LuaClosure`.
    ///
    /// - Parameter nargs: The number of arguments to pass to the function.
    /// - Parameter nret: The number of expected results to be passed to the continuation. Can be ``MultiRet`` to keep
    ///   all returned values.
    /// - Parameter continuation: Continuation to execute once the call has completed (or, if the call yielded, once the
    ///   thread is resumed).
    /// - Precondition: The top of the stack must contain a function/callable and `nargs` arguments.
    public func callk(nargs: CInt, nret: CInt, continuation: @escaping LuaCallContinuation) -> CInt {
        let pcont: LuaPcallContinuation = { L, status in
            if status.error != nil {
                // Not possible in a callk()
                fatalError()
            }
            return try continuation(L, LuaCallContinuationStatus(yielded: status.yielded))
        }
        setupContinuationParams(nargs: nargs, nret: nret, msgh: nil, continuation: pcont)
        return LUASWIFT_CALLCLOSURE_CALLK
    }

    /// Yield the current coroutine.
    ///
    /// Yield the current coroutine, popping `nresults` values from the stack. See
    /// [`lua_yieldk()`](https://www.lua.org/manual/5.4/manual.html#lua_yieldk). Must only be used as the return value
    /// of the last call in a `LuaClosure`. If there is no current coroutine, an error will be thrown from the
    /// `LuaClosure`. If `continuation` is nil, when the coroutine resumes it continues the function that called the
    /// `LuaClosure`, otherwise it calls `continuation`.
    ///
    /// For example:
    ///
    /// ```swift
    /// let my_closure: LuaClosure = { L in
    ///     L.push("something")
    ///     return L.yield(nresults: 1)
    /// }
    ///
    /// let my_closure_with_continuation: LuaClosure = { L in
    ///     L.push("something")
    ///     return L.yield(nresults: 1, continuation: { L in
    ///         print("coroutine resumed with \(L.gettop()) arguments")
    ///         return 0
    ///     })
    /// }
    /// ```
    ///
    /// > Important: `yield()` must only be called from within a `LuaClosure` which is being executed by Lua having
    ///   been pushed via ``Lua/Swift/UnsafeMutablePointer/push(_:numUpvalues:toindex:)``, must be the last call in the
    ///   closure, and must be called with exactly the syntax `return L.yield(...)` where `L` is the same `LuaState`
    ///   as passed into the `LuaClosure`. Any other usage will result in undefined behavior. Calling `lua_yield()`
    ///   or `lua_yieldk()` directly from Swift is not safe, for reasons similar to why `lua_call()` isn't.
    ///
    /// - Parameter nresults: The number of results to be returned from the resume call.
    /// - Parameter continuation: closure to execute if/when the current coroutine is resumed, or nil to continue by
    ///   returning to the parent function.
    public func yield(nresults: CInt, continuation: LuaClosure? = nil) -> CInt {
        if let continuation {
            // Using LuaPcallContinuation lets us reuse LuaClosureWrapper.callContinuation
            let pcont: LuaPcallContinuation = { L, _ in
                return try continuation(L)
            }
            push(userdata: LuaContinuationWrapper(pcont))

            // Check that the continuation registry val is set up
            rawset(LUA_REGISTRYINDEX, key: .function(luaswift_continuation_regkey), value: .function(LuaClosureWrapper.callContinuation))
        } else {
            pushnil()
        }
        push(nresults)
        return LUASWIFT_CALLCLOSURE_YIELD
    }

    // MARK: - Registering metatables

    private func makeMetatableName(for type: Any.Type) -> String {
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

    /// Returns true if a metatable has already been registered for `T`.
    ///
    /// Also returns true if a minimal metatable was created by ``push(userdata:toindex:)`` because there was no default
    /// metatable set. Does not return true if `T` is using the default metatable created by
    /// `register(DefaultMetatable)`.
    public func isMetatableRegistered<T>(for type: T.Type) -> Bool {
        let prefix = "LuaSwift_Type_" + String(describing: type)
        if let state = maybeGetState(),
           let typesArray = state.metatableDict[prefix],
           let index = typesArray.firstIndex(where: { $0 == type }) {
            let name = index == 0 ? prefix : "\(prefix)[\(index)]"
            let t = luaL_getmetatable(self, name)
            pop()
            return t == LUA_TTABLE
        } else {
            return false
        }
    }

    // Only for use by deprecated registerMetatable and registerDefaultMetatable APIs
    public enum MetafieldType {
        case function(lua_CFunction)
        case closure(LuaClosure)
    }

    private func doRegisterMetatable(typeName: String, metafields: [MetafieldName: InternalMetafieldValue]? = nil) {
        if luaL_newmetatable(self, typeName) == 0 {
            preconditionFailure("Metatable for type \(typeName) is already registered!")
        }

        if let metafields {
            for (name, function) in metafields {
                switch function {
                case .function(let cfunction):
                    push(function: cfunction)
                case .closure(let closure):
                    push(LuaClosureWrapper(closure))
                case .value(let value):
                    push(value)
                }
                rawset(-2, utf8Key: name.rawValue)
            }
        }

        push(function: gcUserdata)
        rawset(-2, utf8Key: "__gc")

        // Leaves metatable on top of the stack
    }

    private static let DefaultMetatableName = "LuaSwift_Default"

    /// Deprecated, use ``register(_:)-8rgnn`` instead.
    @available(*, deprecated, message: "Use register(Metatable) instead.")
    public func registerMetatable<T>(for type: T.Type, functions: [String: MetafieldType]) {
        deprecated_registerMetatable(for: type, functions: functions)
    }

    internal func deprecated_registerMetatable<T>(for type: T.Type, functions: [String: MetafieldType]) {
        let mt = handleLegacyMetatableFunctions(functions, type: T.self)
        register(mt)
    }

    // Documented in registerMetatable.md
    public func register<T>(_ metatable: Metatable<T>) {
        doRegisterMetatable(typeName: makeMetatableName(for: T.self), metafields: metatable.mt)

        if let fields = metatable.unsynthesizedFields {
            addNonPropertyFieldsToMetatable(fields)
        }

        getState().userdataMetatables.insert(lua_topointer(self, -1))
        pop() // metatable
    }

    @available(*, deprecated, message: "Use register(DefaultMetatable) instead.")
    public func registerDefaultMetatable(functions: [String: MetafieldType]) {
        deprecated_registerDefaultMetatable(functions: functions)
    }

    internal func deprecated_registerDefaultMetatable(functions: [String: MetafieldType]) {
        let mt = handleLegacyMetatableFunctions(functions, type: Any.self)
        doRegisterMetatable(typeName: Self.DefaultMetatableName, metafields: mt.mt)
        if let fields = mt.unsynthesizedFields {
            addNonPropertyFieldsToMetatable(fields)
        }
        getState().userdataMetatables.insert(lua_topointer(self, -1))
        pop() // metatable
    }

    private func handleLegacyMetatableFunctions<T>(_ functions: [String: MetafieldType], type: T.Type) -> Metatable<T> {
        var fields: [String: Metatable<T>.FieldType] = [:]
        var metafields: [MetafieldName: InternalMetafieldValue] = [:]
        for (name, val) in functions {
            if let metaname = MetafieldName(rawValue: name) {
                let metaval: InternalMetafieldValue
                switch val {
                case .function(let function):
                    metaval = .function(function)
                case .closure(let closure):
                    metaval = .closure(closure)
                }
                metafields[metaname] = metaval
            } else {
                let fieldval: Metatable<T>.FieldType
                switch val {
                case .function(let function):
                    fieldval = .function(function)
                case .closure(let closure):
                    fieldval = .closure(closure)
                }
                fields[name] = fieldval
            }
        }
        if !fields.isEmpty && metafields[.index] == nil {
            metafields[.index] = Metatable<T>.IndexType.synthesize(fields: fields)
        }
        if metafields[.close] == nil {
            // The legacy APIs always set __close
            metafields[.close] = Metatable<Any>.CloseType.synthesize.value
        }
        return Metatable(for: T.self, legacyApiMetafields: metafields)
    }

    private func addNonPropertyFieldsToMetatable<T>(_ fields: [String: Metatable<T>.FieldType]) {
        push(index: -1)
        rawset(-2, utf8Key: "__index")

        for (k, v) in fields {
            switch v.value {
            case .function(let function):
                push(function: function)
            case .closure(let closure):
                push(closure)
            case .value(let value):
                push(value)
            case .property(_), .rwproperty(_, _):
                fatalError() // By definition cannot hit this
            }
            rawset(-2, utf8Key: k)
        }
    }

    /// Register a default (fallback) metatable.
    ///
    /// Register a metatable to be used for all types which have not had an explicit call to
    /// `register(Metatable(...))`.
    ///
    /// If this function is not called, a warning will be printed the first time an unregistered type is pushed using
    /// ``push(userdata:toindex:)``, and a minimal metatable will then be generated which supports garbage collection but
    /// exposes no other functions.
    ///
    /// See also <doc:BridgingSwiftToLua#Default-metatables>.
    ///
    /// - Precondition: do not call more than once - the default metatable for a given LuaState cannot be modified once
    ///   it has been set.
    public func register(_ metatable: DefaultMetatable) {
        doRegisterMetatable(typeName: Self.DefaultMetatableName, metafields: metatable.mt)
        getState().userdataMetatables.insert(lua_topointer(self, -1))
        pop() // metatable
    }


    // MARK: - get/set functions

    /// Wrapper around [lua_rawget](https://www.lua.org/manual/5.4/manual.html#lua_rawget).
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
    @discardableResult @inlinable
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
    @discardableResult @inlinable
    public func rawget(_ index: CInt, utf8Key key: String) -> LuaType {
        let absidx = absindex(index)
        push(utf8String: key)
        return rawget(absidx)
    }

    /// Look up a value using ``rawget(_:key:)`` and convert it to `T` using the given accessor.
    @inlinable
    public func rawget<K: Pushable, T>(_ index: CInt, key: K, _ accessor: (CInt) -> T?) -> T? {
        rawget(index, key: key)
        let result = accessor(-1)
        pop()
        return result
    }

    /// Pushes on to the stack the value `tbl[key]`. May invoke metamethods.
    ///
    /// Where `tbl` is the table (or other indexable value) at `index` on the stack and `key` is the value on the top of
    /// the stack. `key` is popped from the stack.
    ///
    /// - Parameter index: The stack index of the table.
    /// - Returns: The type of the resulting value.
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the call to `lua_gettable`.
    @discardableResult
    public func get(_ index: CInt) throws -> LuaType {
        let absidx = absindex(index)
        push(function: luaswift_gettable, toindex: -2) // Put the fn below key
        push(index: absidx, toindex: -2) // Put tbl below key
        try pcall(nargs: 2, nret: 1, traceback: false)
        return type(-1)!
    }

    /// Pushes on to the stack the value `tbl[key]`. May invoke metamethods.
    ///
    /// Where `tbl` is the table (or other indexable value) at `index` on the stack.
    ///
    /// - Parameter index: The stack index of the table.
    /// - Parameter key: The key to look up in the table.
    /// - Returns: The type of the resulting value.
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the call to `lua_gettable`.
    @discardableResult @inlinable
    public func get<K: Pushable>(_ index: CInt, key: K) throws -> LuaType {
        let absidx = absindex(index)
        push(key)
        return try get(absidx)
    }

    /// Look up a value `tbl[key]` and convert it to `T` using the given accessor.
    ///
    /// Where `tbl` is the table (or other indexable value) at `index` on the stack. If an error is thrown during the
    /// table lookup, `nil` is returned.
    ///
    /// - Parameter index: The stack index of the table.
    /// - Parameter key: The key to look up in the table.
    /// - Parameter accessor: A function which takes a stack index and returns a `T?`.
    /// - Returns: The resulting value, or `nil`.
    @inlinable
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
    /// Where `tbl` is the table (or other indexable value) at `index` on the stack. If an error is thrown during the
    /// table lookup or decode, `nil` is returned.
    ///
    /// - Parameter index: The stack index of the table.
    /// - Parameter key: The key to look up in the table.
    /// - Returns: The resulting value, or `nil`.
    @inlinable
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
    /// value just below the top. `key` and `val` are popped from the stack.
    ///
    /// - Parameter index: The stack index of the table.
    /// - Precondition: The value at `index` must be a table.
    public func rawset(_ index: CInt) {
        precondition(type(index) == .table, "Cannot call rawset on something that isn't a table")
        lua_rawset(self, index)
    }

    /// Performs `tbl[key] = val` using raw accesses, ie does not invoke metamethods.
    ///
    /// Where `tbl` is the table at `index` on the stack, and `val` is the value on the top of the stack. `val` is
    /// popped from the stack.
    ///
    /// - Parameter index: The stack index of the table.
    /// - Parameter key: The key to use.
    /// - Precondition: The value at `index` must be a table.
    @inlinable
    public func rawset<K: Pushable>(_ index: CInt, key: K) {
        let absidx = absindex(index)
        // val on top of stack
        push(key, toindex: -2) // Push key below val
        rawset(absidx)
    }

    /// Performs `tbl[key] = val` using raw accesses, ie does not invoke metamethods.
    ///
    /// Where `tbl` is the table at `index` on the stack, and `val` is the value on the top of the stack. `val` is
    /// popped from the stack.
    ///
    /// - Parameter index: The stack index of the table.
    /// - Parameter key: The string key to use, which is always converted to a Lua string using UTF-8 encoding,
    ///   regardless of what the default string encoding is.
    /// - Precondition: The value at `index` must be a table.
    @inlinable
    public func rawset(_ index: CInt, utf8Key key: String) {
        let absidx = absindex(index)
        // val on top of stack
        push(utf8String: key, toindex: -2) // Push key below val
        rawset(absidx)
    }

    /// Performs `tbl[key] = val` using raw accesses, ie does not invoke metamethods.
    ///
    /// Where `tbl` is the table at `index` on the stack.
    ///
    /// - Parameter index: The stack index of the table.
    /// - Parameter key: The key to use.
    /// - Parameter value: The value to set.
    /// - Precondition: The value at `index` must be a table.
    @inlinable
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
    /// - Parameter index: The stack index of the table.
    /// - Parameter key: The string key to use, which is always converted to a Lua string using UTF-8 encoding,
    ///   regardless of what the default string encoding is.
    /// - Parameter value: The value to set.
    /// - Precondition: The value at `index` must be a table.
    @inlinable
    public func rawset<V: Pushable>(_ index: CInt, utf8Key key: String, value: V) {
        let absidx = absindex(index)
        push(utf8String: key)
        push(value)
        rawset(absidx)
    }

    /// Performs `tbl[key] = val`. May invoke metamethods.
    ///
    /// Where `tbl` is the table (or other indexable value) at `index` on the stack, `val` is the value on the top of
    /// the stack, and `key` is the value just below the top. `key` and `val` are popped from the stack.
    ///
    /// - Parameter index: The stack index of the table.
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the call to `lua_settable`.
    public func set(_ index: CInt) throws {
        let absidx = absindex(index)
        push(function: luaswift_settable, toindex: -3) // Put below key and val
        push(index: absidx, toindex: -3) // Put below key and val (and above function)
        try pcall(nargs: 3, nret: 0, traceback: false)
    }

    /// Performs `tbl[key] = val`. May invoke metamethods.
    ///
    /// Where `tbl` is the table (or other indexable value) at `index` on the stack and `val` is the value on the top of
    /// the stack. `val` is popped from the stack.
    ///
    /// - Parameter index: The stack index of the table.
    /// - Parameter key: The key to use.
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the call to `lua_settable`.
    @inlinable
    public func set<K: Pushable>(_ index: CInt, key: K) throws {
        let absidx = absindex(index)
        // val on top of stack
        push(key, toindex: -2) // Push key below val
        try set(absidx)
    }

    /// Performs `tbl[key] = value`. May invoke metamethods.
    ///
    /// Where `tbl` is the table (or other indexable value) at `index` on the stack.
    ///
    /// - Parameter index: The stack index of the table.
    /// - Parameter key: The key to use.
    /// - Parameter value: The value to set.
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the call to `lua_settable`.
    @inlinable
    public func set<K: Pushable, V: Pushable>(_ index: CInt, key: K, value: V) throws {
        let absidx = absindex(index)
        push(key)
        push(value)
        try set(absidx)
    }

    // MARK: - Misc functions

    /// Pushes the global called `name` on to the stack.
    ///
    /// The global name is always assumed to be in UTF-8 encoding.
    ///
    /// > Important: Unlike `lua_getglobal()`, this function uses raw accesses, ie does not invoke metamethods.
    ///
    /// - Parameter name: The name of the global to push on to the stack.
    /// - Returns: The type of the value pushed on to the stack.
    @discardableResult @inlinable
    public func getglobal(_ name: String) -> LuaType {
        pushglobals()
        let t = rawget(-1, utf8Key: name)
        lua_remove(self, -2)
        return t
    }

    /// Sets the global variable called `name` to the value on the top of the stack.
    ///
    /// The global name is always assumed to be in UTF-8 encoding. The stack value is popped.
    ///
    /// > Important: Unlike `lua_setglobal()`, this function uses raw accesses, ie does not invoke metamethods.
    ///
    /// - Parameter name: The name of the global to set.
    public func setglobal(name: String) {
        precondition(gettop() > 0)
        pushglobals(toindex: -2)
        rawset(-2, utf8Key: name)
        pop() // globals
    }

    /// Sets the global variable called `name` to `value`.
    ///
    /// The global name is always assumed to be in UTF-8 encoding.
    ///
    /// > Important: Unlike `lua_setglobal()`, this function uses raw accesses, ie does not invoke metamethods.
    ///
    /// - Parameter name: The name of the global to set.
    /// - Parameter value: The value to assign.
    @inlinable
    public func setglobal<V: Pushable>(name: String, value: V) {
        push(value)
        setglobal(name: name)
    }

    /// Pushes the globals table (`_G`) on to the stack.
    ///
    /// - Parameter toindex: See <doc:LuaState#Push-functions-toindex-parameter>.
    @inlinable
    public func pushglobals(toindex: CInt = -1) {
        lua_pushglobaltable(self)
        if toindex != -1 {
            insert(toindex)
        }
    }

    /// Deprecated, use ``pushglobals(toindex:)-3ot28``.
    @available(*, deprecated, renamed: "pushglobals")
    public func pushGlobals(toindex: CInt = -1) {
        pushglobals(toindex: toindex)
    }

    /// Wrapper around [`luaL_requiref()`](https://www.lua.org/manual/5.4/manual.html#luaL_requiref).
    ///
    /// Does not leave the module on the stack.
    ///
    /// - Parameter name: The name of the module.
    /// - Parameter function: The function which sets up the module.
    /// - Parameter global: Whether or not to set `_G[name]`.
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
    /// Does not leave the module on the stack.
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
    /// - Parameter global: Whether or not to set `_G[name]`.
    /// - Parameter closure: This closure is called to push the module function on to the stack. Note, it will not be
    ///   called if a module called `name` is already loaded. Must push exactly one item on to the stack.
    /// - Throws: ``LuaCallError`` if a Lua error is raised during the execution of the module function.
    ///   Rethrows if `closure` throws.
    public func requiref(name: String, global: Bool = true, closure: () throws -> Void) throws {
        // There's just no reasonable way to shoehorn this into calling luaL_requiref, we have to unroll it...
        let top = gettop()
        defer {
            settop(top)
        }
        luaL_getsubtable(self, LUA_REGISTRYINDEX, LUA_LOADED_TABLE)
        rawget(-1, utf8Key: name) // LOADED[modname]
        if (!toboolean(-1)) {  // package not already loaded?
            pop()  // remove nil LOADED[modname]
            try closure()
            precondition(gettop() == top + 2 && type(-1) == .function,
                         "requiref closure did not push a function on to the stack!")

            push(utf8String: name)  // argument to open function
            try pcall(nargs: 1, nret: 1)  // call 'openf' to open module
            push(index: -1)  // make copy of module (call result)
            rawset(-3, utf8Key: name)  // LOADED[modname] = module
        }
        if (global) {
            setglobal(name: name)  // _G[modname] = module
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
    /// Which when pushed by ``push(error:toindex:)`` will be converted back to a Lua error with exactly the given string
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

    /// Convenience static wrapper around ``error(_:)-swift.method``.
    public static func error(_ string: String) -> LuaCallError {
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

    // Used by LuaValue.deinit
    internal func unref(_ ref: CInt) {
        getState().luaValues[ref] = nil
        luaL_unref(self, LUA_REGISTRYINDEX, ref)
    }

    /// Convert any Swift value to a `LuaValue`.
    ///
    /// Equivalent to:
    ///
    /// ```swift
    /// L.push(any: val)
    /// let ref = L.popref()
    /// ```
    ///
    /// - Parameter any: The value to convert
    /// - Returns: A `LuaValue` representing the specified value.
    @inlinable
    public func ref(any: Any?) -> LuaValue {
        push(any: any)
        return popref()
    }

    /// Convert the value on the top of the Lua stack into a Swift object of type `LuaValue` and pops it.
    ///
    /// - Returns: A `LuaValue` representing the value on the top of the stack.
    @inlinable
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
    /// L.pushglobals()
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
    /// Invokes the `__len` metamethod if the value has one.
    ///
    /// - Parameter index: The stack index of the value.
    /// - Returns: the length, or `nil` if the value does not have a defined length or `__len` did not return an
    ///   integer.
    /// - Throws: ``LuaCallError`` if the value had a `__len` metamethod which errored.
    public func len(_ index: CInt) throws -> lua_Integer? {
        let t = type(index)
        if t == .string {
            // Len on strings cannot fail or error
            return rawlen(index)!
        }
        let absidx = absindex(index)
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
            push(index: absidx)
            try pcall(nargs: 1, nret: 1)
            defer {
                pop()
            }
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
    @inlinable
    public func rawequal(_ index1: CInt, _ index2: CInt) -> Bool {
        return lua_rawequal(self, index1, index2) != 0
    }

    /// Compare two values for equality. May invoke `__eq` metamethods.
    ///
    /// - Parameter index1: Index of the first value to compare.
    /// - Parameter index2: Index of the second value to compare.
    /// - Returns: true if the two values are equal.
    /// - Throws: ``LuaCallError`` if an `__eq` metamethod errored.
    @inlinable
    public func equal(_ index1: CInt, _ index2: CInt) throws -> Bool {
        return try compare(index1, index2, .eq)
    }

    /// The type of comparison to perform in ``compare(_:_:_:)``.
    public enum ComparisonOp : CInt {
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
        defer {
            pop()
        }
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
    /// - Throws: ``LuaLoadError/fileError(_:)`` if `file` cannot be opened. ``LuaLoadError/parseError(_:)`` if the file
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
            let errStr = tostring(-1)!
            pop()
            throw LuaLoadError.fileError(errStr)
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
    /// - Parameter string: The Lua script to load. This is always parsed using UTF-8 string encoding.
    /// - Parameter name: The name to give to the resulting chunk. If not specified, the string parameter itself will
    ///   be used as the name.
    /// - Throws: ``LuaLoadError/parseError(_:)`` if the string cannot be parsed.
    public func load(string: String, name: String? = nil) throws {
        try load(data: Array<UInt8>(string.utf8), name: name ?? string, mode: .text)
    }

    /// Load a Lua chunk from file with ``load(file:displayPath:mode:)`` and execute it.
    ///
    /// Any values returned from the file are left on the top of the stack.
    ///
    /// - Parameter file: Path to a Lua text or binary file.
    /// - Parameter mode: Whether to only allow text files, compiled binary chunks, or either.
    /// - Throws: ``LuaLoadError/fileError(_:)`` if `file` cannot be opened.
    ///   ``LuaLoadError/parseError(_:)`` if the file cannot be parsed.
    public func dofile(_ path: String, mode: LoadMode = .text) throws {
        try load(file: path, mode: mode)
        try pcall(nargs: 0, nret: LUA_MULTRET)
    }

    /// Load a Lua chunk from a string with ``load(string:name:)`` and execute it.
    ///
    /// Any values returned from the chunk are left on the top of the stack.
    ///
    /// - Parameter string: The Lua script to load.
    /// - Throws: ``LuaLoadError/parseError(_:)`` if the string cannot be parsed.
    public func dostring(_ string: String, name: String? = nil) throws {
        try load(string: string, name: name)
        try pcall(nargs: 0, nret: LUA_MULTRET)
    }

    /// Dump a function as a binary chunk.
    ///
    /// Dumps the function on the top of the stack as a binary chunk. The function is not popped from the stack.
    ///
    /// - Parameter strip: Whether to strip debug information.
    /// - Returns: The binary chunk, or nil if the value on the top of the stack is not a Lua function.
    public func dump(strip: Bool = false) -> [UInt8]? {
        let writefn: lua_Writer = { (L, p, sz, ud) in
            let buf = UnsafeRawBufferPointer(start: p, count: sz)
            ud!.withMemoryRebound(to: [UInt8].self, capacity: 1) { resultPtr in
                resultPtr.pointee.append(contentsOf: buf)
            }
            return 0
        }
        var result: [UInt8] = []
        let err = withUnsafeMutablePointer(to: &result) { resultPtr in
            return lua_dump(self, writefn, UnsafeMutableRawPointer(resultPtr), strip ? 1 : 0)
        }
        if err == 0 {
            return result
        } else {
            return nil
        }
    }

    // MARK: - Upvalues

    /// Search a closure's upvalues for one matching the given name.
    ///
    /// Search a closure's upvalues for one matching the given name, and returns the number of the first upvalue
    /// match, suitable for passing to the `n` parameter of ``getUpvalue(index:n:)`` or ``setUpvalue(index:n:value:)``.
    ///
    /// - Parameter index: The stack index of the closure.
    /// - Parameter name: The upvalue name to search for.
    /// - Returns: The number of the upvalue, or `nil` if `index` does not refer to a closure or the closure does not
    ///   have an upvalue with the specified name.
    public func findUpvalue(index: CInt, name: String) -> CInt? {
        var i: CInt = 1
        while true {
            if let valname = lua_getupvalue(self, index, i) {
                pop()
                if String(cString: valname) == name {
                    return i
                } else {
                    i = i + 1
                    // Keep looping
                }
            } else {
                return nil
            }
        }
    }

    /// Pushes the nth upvalue of the closure at the given index on to the stack.
    ///
    /// If `n` is larger than the number of upvalues of the closure, then `nil` is returned and nothing is pushed onto
    /// the stack.
    ///
    /// The exact order of upvalues to a function is not defined and may be dependent on the order they are accessed
    /// within the function, thus could change merely as a result of refactoring the internals of the function.
    /// Therefore `_ENV` is not guaranteed to be at `n=1` unless the closure is a main chunk.
    ///
    /// - Parameter index: The stack index of the closure.
    /// - Parameter n: Which upvalue to return.
    /// - Returns: The name of the value pushed to the stack, or `nil` if `n` is greater than the number of upvalues the
    ///   closure defines. Note that the name may not be meaningful or unique, but it will be non-nil if the upvalue
    ///   exists.
    @discardableResult
    public func pushUpvalue(index: CInt, n: CInt) -> String? {
        if let name = lua_getupvalue(self, index, n) {
            return String(cString: name)
        } else {
            return nil
        }
    }

    /// Returns the name and value of the nth upvalue of the closure at the given index.
    ///
    /// The exact order of upvalues to a function is not defined and may be dependent on the order they are accessed
    /// within the function, thus could change merely as a result of refactoring the internals of the function.
    /// Therefore `_ENV` is not guaranteed to be at `n=1` unless the closure is a main chunk.
    ///
    /// - Parameter index: The stack index of the closure.
    /// - Parameter n: Which upvalue to return.
    /// - Returns: The name and value of the given upvalue, or `nil` if `n` is greater than the number of upvalues the
    ///   closure defines. Note that upvalue names may not be meaningful or unique.
    public func getUpvalue(index: CInt, n: CInt) -> (name: String, value: LuaValue)? {
        if let name = pushUpvalue(index: index, n: n) {
            let val = popref()
            return (name: name, value: val)
        } else {
            return nil
        }
    }

    /// Returns all the uniquely-named upvalues for the closure at the given index.
    ///
    /// If there are multiple upvalues with the same name, for example because the function was stripped of debug
    /// information and all the upvalues are consequently called `?`, then none of those upvalues are included in the
    /// result.
    ///
    /// - Parameter index: The stack index of the closure.
    /// - Returns: A Dictionary of all the closure's uniquely-named upvalues.
    public func getUpvalues(index: CInt) -> [String : LuaValue] {
        var i: CInt = 1
        var result: [String : LuaValue] = [:]
        var seenNames: Set<String> = []
        while true {
            if let (name, val) = getUpvalue(index: index, n: i) {
                if seenNames.contains(name) {
                    result[name] = nil
                } else {
                    result[name] = val
                    seenNames.insert(name)
                }
                i = i + 1
            } else {
                break
            }
        }
        return result
    }

    /// Set a closure's upvalue to the value on the top of the stack.
    ///
    /// The value is always popped from the stack.
    ///
    /// - Parameter index: The stack index of the closure.
    /// - Parameter n: Which upvalue to set.
    /// - Returns: `true` if `n` was a valid upvalue which was updated, `false` otherwise.
    @discardableResult
    public func setUpvalue(index: CInt, n: CInt) -> Bool {
        if lua_setupvalue(self, index, n) != nil {
            return true
        } else {
            pop()
            return false
        }
    }

    /// Set a closure's upvalue to the specified value.
    ///
    /// - Parameter index: The stack index of the closure.
    /// - Parameter n: Which upvalue to set.
    /// - Parameter value: The value to assign to the upvalue.
    /// - Returns: `true` if `n` was a valid upvalue which was updated, `false` otherwise.
    @discardableResult
    public func setUpvalue<V: Pushable>(index: CInt, n: CInt, value: V) -> Bool {
        let absidx = absindex(index)
        push(value)
        return setUpvalue(index: absidx, n: n)
    }

    // MARK: - Argument checks

    /// Returns an `Error` suitable for throwing from a `LuaClosure` when there is a problem with an argument.
    ///
    /// This is the LuaSwift equivalent of
    /// [`luaL_argerror()`](https://www.lua.org/manual/5.4/manual.html#luaL_argerror). For example:
    ///
    /// ```swift
    /// func myLuaClosure(L: LuaState) throws -> CInt {
    ///     if L.isnil(1) {
    ///         throw L.argumentError(1, "expected non-nil")
    ///     }
    ///     /* rest of fn */
    /// }
    /// ```
    ///
    /// This will result in an error something like: `"bad argument #1 to 'myLuaClosure' (expected non-nil)"`
    ///
    /// - Parameter arg: Index of the argument which has the problem.
    /// - Parameter extramsg: More information about the problem, which is appended to the error string.
    /// - Returns: An error which, when thrown from a `LuaClosure`, will result in a string error in Lua.
    public func argumentError(_ arg: CInt, _ extramsg: String) -> LuaCallError {
        var adjustedArg = arg
        guard let fninfo = getStackInfo(level: 0, what: [.name]) else {
            return error("bad argument #\(arg) (\(extramsg))")
        }

        let name = fninfo.name ?? "?"
        if fninfo.namewhat == .method {
            adjustedArg = arg - 1
            if adjustedArg == 0 {
                return error("calling '\(name)' on bad self (\(extramsg)")
            }
        }

        return error("bad argument #\(arg) to '\(name)' (\(extramsg))")
    }

    /// Checks if an function argument is of the correct type.
    ///
    /// If the Lua value at the given stack index is not convertible to `T` using ``tovalue(_:)``, then an error is
    /// thrown. For example:
    ///
    /// ```swift
    /// func myclosure(_ L: LuaState) throws -> CInt {
    ///     let arg: String = try L.checkArgument(1)
    ///     // ...
    /// }
    /// ```
    ///
    /// This function correctly handles the case where `T` is an `Optional<BaseType>`, providing `BaseType` is not
    /// itself an Optional, returning `.none` when the Lua value was `nil`, and erroring if the Lua value was any
    /// other type not convertible to `BaseType`.
    ///
    /// - Parameter arg: Stack index of the argument.
    /// - Returns: An instance of type `T`.
    /// - Throws: an ``argumentError(_:_:)`` if the specified argument cannot be converted to type `T`. Argument
    ///   conversion is performed according to ``tovalue(_:)``.
    public func checkArgument<T>(_ arg: CInt) throws -> T {
        if let val: T = tovalue(arg) {
            return val
        } else {
            throw argumentError(arg, "Expected type convertible to \(String(describing: T.self)), got \(typename(index: arg))")
        }
    }

    /// Checks if an function argument is of the correct type.
    ///
    /// This function behaves identically to ``checkArgument(_:)`` except for having an explicit `type:` parameter to force
    /// the correct type where inference on the return type is not sufficient.
    ///
    /// - Parameter arg: Stack index of the argument.
    /// - Parameter type: The type to convert the argument to.
    /// - Returns: An instance of type `T`.
    /// - Throws: an ``argumentError(_:_:)`` if the specified argument cannot be converted to type `T`. Argument
    ///   conversion is performed according to ``tovalue(_:)``.
    @inlinable
    public func checkArgument<T>(_ arg: CInt, type: T.Type) throws -> T {
        return try checkArgument(arg)
    }

    /// Checks if an argument can be converted to a RawRepresentable type.
    /// 
    /// The argument is assumed to be in the RawRepresentable's raw value type. For example, given a definition like:
    /// ```swift
    /// enum Foo: String {
    ///     case foo
    ///     case bar
    /// }
    /// ```
    /// then `let arg: Foo = try L.checkOption(1)` when argument 1 is the string "bar" will set `arg` to `Foo.bar`.
    ///
    /// - Parameter arg: Stack index of the argument.
    /// - Parameter default: If specified, this value is returned if the argument is none or nil. If not specified then
    ///   a nil or omitted argument will throw an error.
    /// - Returns: An instance of `T`, assuming `T(rawValue: <argval>)` succeeded.
    /// - Throws: An ``argumentError(_:_:)`` if the specified argument was not of the correct raw type or could not be
    ///   converted to `T`.
    public func checkOption<T, U>(_ arg: CInt, default def: T? = nil) throws -> T where T: RawRepresentable<U> {
        if isnoneornil(arg), let defaultVal = def {
            return defaultVal
        }

        let raw: U = try checkArgument(arg)
        if let result = T(rawValue: raw) {
            return result
        } else {
            throw argumentError(arg, "invalid option '\(raw)' for \(String(describing: T.self))")
        }
    }

    /// Debugging function to dump the contents of the Lua stack.
    ///
    /// If no parameters are specified, prints all elements in the current stack frame using
    /// ``tostring(_:encoding:convert:)-9syls`` with `encoding=nil` and `convert=true`.
    ///
    /// - Parameter from: The index to start from (default is 1, ie start from the bottom of the stack).
    /// - Parameter to: The last index to print. The default value `nil` is the same as specifying `gettop()`, meaning
    ///   to include elements up to and including the topmost.
    public func printStack(from: CInt = 1, to: CInt? = nil) {
        let top = to ?? gettop()
        if top - from < 0 {
            print("(No stack values)")
            return
        }
        for i in from ... top {
            let desc = tostring(i, convert: true) ?? "??"
            print("\(i): \(desc)")
        }
    }
}

protocol LuaTemporaryRef {

    func ref() -> LuaValue
    
}
