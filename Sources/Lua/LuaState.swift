// Copyright (c) 2023-2025 Tom Sutcliffe
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
///
/// Note that while it permissable to construct other `LuaVer` instances, this is not intended to be a generalised
/// version number type. Comparisons and ``releaseNum`` will not behave correctly for numerical values outside of
/// what comprises a valid Lua version number.
public struct LuaVer: Sendable, CustomStringConvertible, Comparable {
    /// The Lua major version number (eg 5).
    public let major: CInt
    /// The Lua minor version number (eg 4).
    public let minor: CInt
    /// The Lua release number (eg 6, for 5.4.6).
    public let release: CInt
    /// The complete Lua version number as an decimal integer (eg 50406 for 5.4.6).
    public var releaseNum: CInt {
        return (major * 100 + minor) * 100 + release
    }

    /// Returns true if the Lua version is 5.4 or later.
    ///
    /// The following are equivalent:
    /// ```swift
    /// LUA_VERSION.is54orLater() // is the same as...
    /// LUA_VERSION >= LUA_5_4_0
    /// ```
    public func is54orLater() -> Bool {
        return self >= LUA_5_4_0
    }

    // > 5.4.7 constructor
    /// Construct a LuaVer representing a particular Lua version.
    ///
    /// This can be useful when wanting to do tests for specific Lua versions where there isn't a constant for that
    /// version defined by LuaSwift:
    ///
    /// ```swift
    /// let lua_5_3_3 = LuaVer(major: 5, minor: 3, release: 3)
    /// if LUA_VERSION >= lua_5_3_3 {
    ///     // something nuanced...
    /// }
    /// ```
    public init(major: CInt, minor: CInt, release: CInt) {
        self.major = major
        self.minor = minor
        self.release = release
    }

    // 5.4.7 and earlier constructor
    init(major: String, minor: String, release: String) {
        self.major = CInt(major)!
        self.minor = CInt(minor)!
        self.release = CInt(release)!
    }

    /// Returns the Lua version (including release number) as a string.
    ///
    /// Returns the Lua version (including release number) as a string, for example `"5.4.6"`.
    public func tostring() -> String {
        return "\(major).\(minor).\(release)"
    }

    public var description: String {
        return tostring()
    }

    public static func < (lhs: LuaVer, rhs: LuaVer) -> Bool {
        // This definition is sufficient for all real Lua versions (where no part of the version will exceed 100)
        return lhs.releaseNum < rhs.releaseNum
    }

    public static func == (lhs: LuaVer, rhs: LuaVer) -> Bool {
        return lhs.releaseNum == rhs.releaseNum
    }
}

/// The version of Lua being used.
///
/// This can be used to modify runtime behaviour depending on what Lua version is being used, for example:
///
/// ```swift
/// if LUA_VERSION >= LUA_5_4_0 {
///     // Do something only applicable in Lua 5.4
/// }
/// ```
///
/// or simply for logging purposes:
///
/// ```swift
/// print("Using Lua \(LUA_VERSION)")
/// ```
public let LUA_VERSION = LuaVer(major: LUASWIFT_LUA_VERSION_MAJOR, minor: LUASWIFT_LUA_VERSION_MINOR,
    release: LUASWIFT_LUA_VERSION_RELEASE)

/// Constant representing the 5.4.0 version of Lua.
///
/// Normally used in a comparison with ``LUA_VERSION``.
public let LUA_5_4_0 = LuaVer(major: 5, minor: 4, release: 0)

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
    // Clear the stack, make it harder for a deinit fn to mess things up. We're in a finalizer already, so this can't
    // cause the userdata to be GC'd due to no more references.
    L.settop(0)

    let anyPtr = rawptr.assumingMemoryBound(to: Any.self)
    anyPtr.deinitialize(count: 1)
    return 0
}

fileprivate func callUnmanagedClosure(_ L: LuaState!) -> CInt {
    // Lightuserdata representing the LuaClosureWrapper expected to be on top of the stack; rest of stack is up to the
    // caller to set up.
    let wrapper = Unmanaged<LuaClosureWrapper>.fromOpaque(lua_touserdata(L, -1))
    L.pop() // wrapper

    do {
        return try wrapper.takeUnretainedValue().closure(L)
    } catch {
        L.push(error: error)
        return LUASWIFT_CALLCLOSURE_ERROR
    }
}

/// A Swift enum of the Lua types.
///
/// The `rawValue` of the enum uses the same integer values as the `LUA_T...` type constants. Note that `LUA_TNONE` does
/// not have a `LuaType` representation, and is instead represented by `nil`, ie an optional `LuaType`, in places where
/// `LUA_TNONE` can occur.
///
/// > Note: `nil` and `LuaType.nil` are distinct values -- in places where `LuaType?` is used, `nil` represents the
///   absence of a type (corresponding to `LUA_TNONE`), whereas `LuaType.nil` represents the type of the Lua nil value,
///   ie `LUA_TNIL`.
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
    /// Returns a `LuaType` representing the given type, or `nil` if `ctype` is `LUA_TNONE`.
    ///
    /// - Parameter ctype: The C type to convert.
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
///
/// > Note: Conformance to `Closable` has no effect if running with a Lua version prior to 5.4.
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
    /// Calls [`lua_close()`](https://www.lua.org/manual/5.4/manual.html#lua_close) on this state. Must be the last
    /// function called on this `LuaState` pointer. For example:
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
    ///
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

    public enum GcMode {
        case generational
        case incremental
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
    /// > Warning: Collection parameter values are not portable between versions of Lua. Consult the appropriate
    ///   [version of the manual](https://www.lua.org/manual/).
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
        switch prevMode {
        case LUASWIFT_GCGEN:
            return .generational
        case LUASWIFT_GCINC:
            return .incremental
        case -1:
            preconditionFailure("Attempt to call collectorSetIncremental() from within a finalizer.")
        default:
            fatalError("Unexpected return \(prevMode) from luaswift_setinc")
        }
    }

    /// Set the garbage collector to generational mode.
    ///
    /// Set the garbage collector to generational mode, and optionally set any or all of the collection parameters.
    /// See [Generational Garbage Collection](https://www.lua.org/manual/5.4/manual.html#2.5.2). Only supported on
    /// Lua 5.4 and later.
    ///
    /// > Warning: Collection parameter values are not portable between versions of Lua. Consult the appropriate
    ///   [version of the manual](https://www.lua.org/manual/). The `minorMajorMul` and `majorMinorMul` parameters are
    ///   experimental and should not be considered part of the public API, until they are present in an official Lua
    ///   release.
    ///
    /// - Parameter minormul: the frequency of minor collections, or `nil` to leave the parameter unchanged.
    /// - Parameter majormul: the frequency of major collections, or `nil` to leave the parameter unchanged.
    ///   Only applicable on Lua v5.4, must be nil on later versions.
    /// - Parameter minorMajorMul: the minor-major multiplier, or `nil` to leave the parameter unchanged.
    ///   Only applicable post Lua v5.4, must be nil on earlier versions.
    /// - Parameter majorMinorMul: the major-minor multiplier, or `nil` to leave the parameter unchanged.
    ///   Only applicable post Lua v5.4, must be nil on earlier versions.
    /// - Returns: The previous garbage collection mode.
    /// - Precondition: Do not call from within a finalizer, or when using Lua v5.3 or earlier. Do not specify a
    ///   parameter that is not supported on the version of Lua being used.
    @discardableResult
    public func collectorSetGenerational(minormul: CInt? = nil, majormul: CInt? = nil, minorMajorMul: CInt? = nil, majorMinorMul: CInt? = nil) -> GcMode {
        let prevMode = luaswift_setgen(self, minormul ?? 0, majormul ?? 0, minorMajorMul ?? 0, majorMinorMul ?? 0)
        switch prevMode {
        case LUASWIFT_GCGEN:
            return .generational
        case LUASWIFT_GCINC:
            return .incremental
        case LUASWIFT_GCUNSUPPORTED:
            preconditionFailure("Attempt to call collectorSetGenerational() on a Lua version that doesn't support it")
        case -1:
            preconditionFailure("Attempt to call collectorSetGenerational() from within a finalizer.")
        default:
            fatalError("Unexpected return \(prevMode) from luaswift_setgen")
        }
    }

    class _State {
#if !LUASWIFT_NO_FOUNDATION
        var defaultStringEncoding: LuaStringEncoding = .stringEncoding(.utf8)
#endif
        var metatableDict = Dictionary<String, Array<Any.Type>>()
        var userdataMetatables = Set<UnsafeRawPointer>()
        var luaValues = Dictionary<CInt, UnownedLuaValue>()
        var errorConverter: LuaErrorConverter? = nil
        var hookFnsRef: CInt = LUA_NOREF

        deinit {
            for (_, val) in luaValues {
                val.val.L = nil
            }
        }
    }

    internal func getState() -> _State {
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
        register(Metatable<LuaClosureWrapper>())
        register(Metatable<LuaContinuationWrapper>())
        register(Metatable<LuaHookWrapper>())
        luaswift_set_functions(LuaClosureWrapper.callClosure, LuaClosureWrapper.callContinuation, LuaHookWrapper.callHook);

        return state
    }

    internal func maybeGetState() -> _State? {
        push(function: stateLookupKey)
        rawget(LUA_REGISTRYINDEX)
        defer {
            pop()
        }
        // We must call the unchecked version to avoid recursive loops as touserdata calls maybeGetState(). This is
        // safe because we know the value of stateLookupKey does not need checking.
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

    /// Returns true if the value is a C (or Swift) function.
    ///
    /// This will also return true for a `LuaClosure` pushed using `push(_ closure: LuaClosure)`; no distinction is
    /// made by this API between functions implemented in C and functions/closures implemented in Swift. Any
    /// function not written in Lua is considered a 'C function' for the purposes of this API.
    ///
    /// - Parameter index: The stack index of the value.
    /// - Returns: `true` if the value is a function written in C (or Swift).
    public func iscfunction(_ index: CInt) -> Bool {
        return lua_iscfunction(self, index) != 0
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

    /// Removes the element at the given valid index.
    ///
    /// Removes the element at the given valid index, shifting down the elements above this index to fill the gap.
    ///
    /// - Parameter index: The stack index remove.
    @inlinable
    public func remove(_ index: CInt) {
        lua_remove(self, index)
    }

    /// See [`lua_copy`](https://www.lua.org/manual/5.4/manual.html#lua_copy).
    @inlinable
    public func copy(from: CInt, to: CInt) {
        lua_copy(self, from, to)
    }

    /// See [`lua_gettop`](https://www.lua.org/manual/5.4/manual.html#lua_gettop).
    @inlinable
    public func gettop() -> CInt {
        return lua_gettop(self)
    }

    /// See [`lua_settop`](https://www.lua.org/manual/5.4/manual.html#lua_settop).
    @inlinable
    public func settop(_ top: CInt) {
        lua_settop(self, top)
    }

    /// See [`lua_checkstack`](https://www.lua.org/manual/5.4/manual.html#lua_checkstack).
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
        precondition(narr >= 0 && nrec >= 0, "Table size cannot be negative")
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
    /// Generally speaking, this API is not very useful on its own, and you should normally use ``tovalue(_:)`` instead,
    /// when needing to do any generics-based programming.
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
            let ptr: Any = lua_touserdata(self, index) as Any
            return ptr
        case .number:
            if let intVal = tointeger(index) {
#if LUASWIFT_ANYHASHABLE_BROKEN
                return intVal
#else
                // Integers are returned type-erased (thanks to AnyHashable) meaning fewer cast restrictions in
                // eg tovalue()
                return AnyHashable(intVal)
#endif
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
                if luaswift_fnsequal(fn, luaswift_callclosurewrapper) {
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
            if let oneOfOurs: Any = touserdata(index) {
                return oneOfOurs
            } else {
                // If it's not a userdata we configured, just return the raw pointer
                return lua_touserdata(self, index)!
            }
        case .thread:
            return lua_tothread(self, index)
        }
    }

    /// Attempt to convert the value at the given stack index to type `T`.
    ///
    /// This function attempts to convert a Lua value to the specified Swift type `T`, according to the rules outlined
    /// below, returning `nil` if conversion to `T` was not possible. Generally speaking, it supports the inverse of
    /// the conversions that [`push(any:)`](doc:Lua/Swift/UnsafeMutablePointer/push(any:toindex:)) supports. Recursively
    /// converting nested data structures is supported if `T` is an `Array` or `Dictionary` type.
    ///
    /// How the conversion is performed depends on what type the Lua value is:
    ///
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
    ///   (providing both key and value can be converted to `AnyHashable`). When converting to an `Array`, only the
    ///   integer keys from 1 upwards are considered (and are adjusted to be zero-based), any other keys will be
    ///   ignored. When converting to a `Dictionary`, all keys are considered and integer indexes are not adjusted.
    /// * `userdata` - providing the value was pushed via
    ///   [`push<U>(userdata:)`](doc:Lua/Swift/UnsafeMutablePointer/push(userdata:toindex:)), converts to `U` or
    ///   anything `U` can be cast to. If the value was not pushed via `push(userdata:)` (a "foreign" userdata) then it
    ///   converts to `UnsafeRawPointer` or `UnsafeMutableRawPointer`. If `T` is `Any` or `AnyHashable` and the value is
    ///   a foreign userdata, a `UnsafeMutableRawPointer` is returned.
    /// * `function` - if the function is a C function, it is represented by `lua_CFunction`. If the function was pushed
    ///   with [`push(_ closure:)`](doc:Lua/Swift/UnsafeMutablePointer/push(_:numUpvalues:toindex:)), is represented by ``LuaClosure``. Otherwise it is represented by
    ///   ``LuaValue``. The conversion succeeds if the represented type can be cast to `T`.
    /// * `thread` converts to `LuaState`.
    /// * `lightuserdata` converts to `UnsafeRawPointer?` or `UnsafeMutableRawPointer?`. If `T` is `Any` or
    ///   `AnyHashable`, a `UnsafeMutableRawPointer?` is returned. If the value is definitely not the null pointer,
    ///   then the non-optional types `UnsafeRawPointer` or `UnsafeMutableRawPointer` can be used -- the null pointer
    ///   lightuserdata will not convert to the non-optional types (because in Swift a non-optional raw pointer is not
    ///   allowed to be null).
    ///
    /// If `T` is `LuaValue`, the conversion will always succeed for all Lua value types as if ``ref(index:)`` were
    /// called. Tuples are not supported and conversion to a tuple type will always fail and return `nil`.
    ///
    /// Converting the `nil` Lua value when `T` is `Optional<U>` (thus the return type of `tovalue()` is
    /// `Optional<Optional<U>>`) always succeeds and returns `.some(.none)`. This is the only case where the Lua `nil`
    /// value does not return `nil`. Any behavior described above like "converts to `SomeType`" or "when `T` is
    /// `SomeType`" also applies for any level of nested `Optional` of that type, such as `SomeType??`.
    ///
    /// If the value cannot be represented by type `T` for any other reason, then `nil` is returned. This includes
    /// numbers being out of range or requiring rounding, tables with keys whose Swift value (according to the rules of
    /// `tovalue()`) is not `Hashable`, strings not being decodable using the default string encoding, etc.
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
    /// `tovalue()` underpins all of the LuaSwift APIs which automatically convert Lua values to Swift types, such as
    /// ``pcall(_:traceback:)-3qlin`` and ``checkArgument(_:)``.
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

        // You cannot direct cast from UnsafeMutableRawPointer to UnsafeRawPointer and unfortunately lightuserdata used
        // to always be returned from toany() as UnsafeRawPointer, so we need to avoid breaking any existing code and
        // allow both T=UnsafeRawPointer and T=UnsafeMutableRawPointer.
        let t = type(index)
        if t == .userdata || t == .lightuserdata {
             if let mutptr = value as? UnsafeMutableRawPointer {
                return UnsafeRawPointer(mutptr) as? T
            }
        }

#if LUASWIFT_ANYHASHABLE_BROKEN
        // Then the directCast clause above won't have worked, and we need to try every integer type
        if t == .number, let intVal = value as? lua_Integer {
            if let intSubType = Int(exactly: intVal), let ret = intSubType as? T {
                return ret
            }
            if let intSubType = Int8(exactly: intVal), let ret = intSubType as? T {
                return ret
            }
            if let intSubType = Int16(exactly: intVal), let ret = intSubType as? T {
                return ret
            }
            if let intSubType = Int32(exactly: intVal), let ret = intSubType as? T {
                return ret
            }
            if let intSubType = Int64(exactly: intVal), let ret = intSubType as? T {
                return ret
            }
            if let intSubType = UInt(exactly: intVal), let ret = intSubType as? T {
                return ret
            }
            if let intSubType = UInt8(exactly: intVal), let ret = intSubType as? T {
                return ret
            }
            if let intSubType = UInt16(exactly: intVal), let ret = intSubType as? T {
                return ret
            }
            if let intSubType = UInt32(exactly: intVal), let ret = intSubType as? T {
                return ret
            }
            if let intSubType = UInt64(exactly: intVal), let ret = intSubType as? T {
                return ret
            }
            if let dbl = Double(exactly: intVal), let ret = dbl as? T {
                return ret
            }
            if let flt = Float(exactly: intVal), let ret = flt as? T {
                return ret
            }
        }
#endif

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

    /// Convert a Lua light userdata back to the pointer it represents.
    ///
    /// Because pointers in Swift that can be null are represented by an optional `UnsafeMutableRawPointer`, and it is
    /// valid to have a lightuserdata referring to the null pointer, this function returns a double-nested optional --
    /// that is to say, it returns `nil` if the value at `index` is not a light userdata, `.some(.none)` for a light
    /// userdata representing the null pointer, and `.some(.some(ptr))` for any other light userdata.
    ///
    /// ```swift
    /// if let ptr = L.tolightuserdata(-1) {
    ///     if ptr == nil {
    ///         print("null lightuserdata")
    ///     } else {
    ///         print("lightuserdata \(ptr!)")
    ///     }
    /// } else {
    ///     print("not a lightuserdata")
    /// }
    /// ```
    ///
    /// - Parameter index: The stack index.
    /// - Returns: `nil` if the value at `index` is not a light userdata, `.some(.none)` for a light userdata
    ///   representing the null pointer, or `.some(.some(ptr))` for any other light userdata.
    public func tolightuserdata(_ index: CInt) -> UnsafeMutableRawPointer?? {
        guard type(index) == .lightuserdata else {
            return nil
        }
        return .some(lua_touserdata(self, index))
    }

    /// See [`lua_tothread`](https://www.lua.org/manual/5.4/manual.html#lua_tothread).
    ///
    /// - Parameter index: The stack index.
    /// - Returns: the thread at the given index or `nil` if the value is not a thread.
    public func tothread(_ index: CInt) -> LuaState? {
        return lua_tothread(self, index)
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
        guard getmetatable(index) else {
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

    internal func unchecked_touserdata<T>(_ index: CInt) -> T? {
        guard let rawptr = lua_touserdata(self, index) else {
            return nil
        }
        let typedPtr = rawptr.assumingMemoryBound(to: Any.self)
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

    /// Get the underlying `FILE` pointer from a Lua file handle on the stack.
    ///
    /// This function is for Lua file handles using the Lua-supplied metatable named
    /// `LUA_FILEHANDLE` and a userdata starting with a
    /// [`luaL_Stream`](https://www.lua.org/manual/5.4/manual.html#luaL_Stream). It returns `nil`
    /// if the file handle has already been closed.
    ///
    /// - Parameter index: The stack index.
    /// - Returns: A `FILE` pointer or `nil` if the value at the given stack index is not a file
    ///   handle, or has already been closed.
    public func tofilehandle(_ index: CInt) -> UnsafeMutablePointer<FILE>? {
        guard let rawptr = luaL_testudata(self, index, LUA_FILEHANDLE) else {
            return nil
        }
        return rawptr.withMemoryRebound(to: luaL_Stream.self, capacity: 1) { pointer in
            if pointer.pointee.closef != nil {
                return pointer.pointee.f
            } else {
                return nil
            }
        }
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
    /// - Parameter convert: If true and the value for the given key is not a Lua string, it will be converted to a
    ///   string (invoking `__tostring` metamethods if necessary) before being decoded.
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

    private class IPairsTypedRawIterator<T>: Sequence, IteratorProtocol {
        let L: LuaState
        let index: CInt
        var i: lua_Integer
        init(_ L: LuaState, _ index: CInt, start: lua_Integer) {
            self.L = L
            self.index = L.absindex(index)
            self.i = start - 1
        }
        public func next() -> (lua_Integer, T)? {
            i = i + 1
            lua_rawgeti(L, index, i)
            let val: T? = L.tovalue(-1)
            L.pop()
            if let val {
                return (i, val)
            } else {
                return nil
            }
        }
    }

    /// Iterate the array part of a table using raw accesses.
    ///
    /// Returns a for-iterator that iterates the array part of a table, using raw accesses, with each element being
    /// placed on the top of the stack within the for loop. The "iterated element" is the array index of each element.
    ///
    /// Accesses are performed raw, in other words the `__index` metafield is ignored if the table has one.
    ///
    /// To automatically convert each element to a Swift type, use ``ipairs(_:type:start:)`` instead.
    ///
    /// ```swift
    /// // Assuming { 11, 22, 33 } is the only thing on the stack
    /// for i in L.ipairs(1) {
    ///     print("table[\(i)] is \(L.toint(-1)!)")
    /// }
    /// // Prints:
    /// // table[1] is 11
    /// // table[2] is 22
    /// // table[3] is 33
    /// ```
    ///
    /// - Parameter index: Stack index of the table to iterate.
    /// - Parameter start: What table index to start iterating from. Default is `1`, ie the start of the array.
    /// - Parameter resetTop: By default, the stack top is reset on exit of the loop and each time through the iterator
    ///   to what it was at the point of calling `ipairs`. Occasionally this is not desirable and can be disabled by
    ///   setting `resetTop` to false.
    /// - Precondition: `index` must refer to a table value.
    public func ipairs(_ index: CInt, start: lua_Integer = 1, resetTop: Bool = true) -> some Sequence<lua_Integer> {
        precondition(type(index) == .table, "Value must be a table to iterate with ipairs()")
        return IPairsRawIterator(self, index, start: start, resetTop: resetTop)
    }

    /// Iterate a table using raw accesses as if it were an array with elements of type `T`.
    ///
    /// Return a for-iterator that iterates the array part of a table, using raw accesses, with each element being
    /// converted to type `T` using `tovalue()`. The "iterated element" is the tuple `(index, value)`. The iteration is
    /// stopped if any value cannot be converted to `T` using `tovalue()` (which includes stopping because a `nil` value
    /// is encountered).
    ///
    /// Accesses are performed raw, in other words the `__index` metafield is ignored if the table has one.
    ///
    /// To iterate the table without converting the values to Swift values, use ``ipairs(_:start:resetTop:)`` instead.
    ///
    /// ```swift
    /// // Assuming { "abc", "def", "ghi" } is the only thing on the stack
    /// for (i, val) in L.ipairs(1, type: String.self) {
    ///     print("table[\(i)] is \(val)")
    /// }
    /// // Prints:
    /// // table[1] is abc
    /// // table[2] is def
    /// // table[3] is ghi
    /// ```
    ///
    /// > Note: The stack top is never reset when using this API. Any items pushed on to the stack inside the `for`
    ///   loop will be left there where the loop exits.
    ///
    /// - Parameter index: Stack index of the table to iterate.
    /// - Parameter type: The expected type of the array values.
    /// - Parameter start: What table index to start iterating from. Default is `1`, ie the start of the array.
    /// - Precondition: `index` must refer to a table value.
    public func ipairs<T>(_ index: CInt, type: T.Type, start: lua_Integer = 1) -> some Sequence<(lua_Integer, T)> {
        precondition(self.type(index) == .table, "Value must be a table to iterate with ipairs()")
        let iter: IPairsTypedRawIterator<T> = IPairsTypedRawIterator(self, index, start: start)
        return iter
    }

    /// Used as the return value from `for_ipairs()` and `for_pairs()` blocks.
    public enum IteratorResult: Equatable {
        /// Indicates that the iteration should stop and the `for_[i]pairs()` should return.
        case breakIteration
        /// Indicates that the iteration should proceed to the next element (if there is one).
        case continueIteration
    }

    /// Iterates a Lua array, observing `__index` metafields.
    ///
    /// Iterates a Lua array, observing `__index` metafields. Because `__index` metafields can error, and
    /// `IteratorProtocol` is not allowed to, the iteration code must be passed in as a block. The block should return
    /// `.continueIteration` to continue iterating to the next element, or `.breakIteration` to break. As an
    /// alternative to always returning `.continueIteration` to iterate all elements, use
    /// ``for_ipairs(_:start:_:)-5kkcd`` instead which takes a Void-returning block.
    ///
    /// Any error thrown by the block is rethrown by the `for_ipairs()` call, halting the iteration.
    ///
    /// ```swift
    /// for i in L.ipairs(-1) {
    ///     // top of stack contains `L.rawget(value, key: i)`
    ///     if /* something */ {
    ///         break
    ///     }
    /// }
    ///
    /// // Compared to:
    /// try L.for_ipairs(-1) { i in
    ///     // top of stack contains `try L.get(value, key: i)`
    ///     if /* something */ {
    ///         return .breakIteration
    ///     }
    ///     return .continueIteration
    /// }
    /// ```
    ///
    /// - Parameter index: Stack index of the table to iterate.
    /// - Parameter start: What table index to start iterating from. Default is `1`, ie the start of the array.
    /// - Parameter block: The code to execute.
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a Lua error is raised
    ///   during the execution of a `__index` metafield or if the value does not support indexing. Rethrows anything
    ///   thrown by `block`.
    public func for_ipairs(_ index: CInt, start: lua_Integer = 1, _ block: (lua_Integer) throws -> IteratorResult) throws {
        // Ensure this is set up
        push(function: luaswift_do_for_pairs) // yes, it's keyed under the pairs fn not ipairs...
        push(function: callUnmanagedClosure)
        rawset(LUA_REGISTRYINDEX)

        push(index: index)
        push(function: luaswift_do_for_ipairs, toindex: -2) // below the value being iterated
        push(start)

        // See for_pairs() for explanation of how this pattern works.
        try withoutActuallyEscaping(block) { escapingBlock in
            let wrapper = LuaClosureWrapper({ L in
                // The stack is exactly in the state luaswift_do_for_ipairs left it, so i and val are at 4 and 5
                let iteratorResult = try escapingBlock(lua_tointeger(L, 4))
                return iteratorResult == .continueIteration ? 1 : 0
            })

            push(lightuserdata: Unmanaged.passUnretained(wrapper).toOpaque())
            try pcall(nargs: 3, nret: 0) // luaswift_do_for_ipairs(value, start, wrapper)
        }
    }

    /// Like ``for_ipairs(_:start:_:)-16dkm`` but without the option to break from the iteration.
    ///
    /// This function behaves like ``for_ipairs(_:start:_:)-16dkm`` except that `block` should not return anything. This
    /// is a convenience overload allowing you to omit writing `return .continueIteration` when the block never needs
    /// to exit the iteration early by using `return .breakIteration`.
    ///
    /// ```swift
    /// try L.for_ipairs(-1) { i in
    ///     // iterates every item of value observing the __index metafield if present.
    /// }
    /// ```
    public func for_ipairs(_ index: CInt, start: lua_Integer = 1, _ block: (lua_Integer) throws -> Void) throws {
        try for_ipairs(index, start: start, { i in
            try block(i)
            return .continueIteration
        })
    }

    /// Iterates a Lua value as if it were an array of elements with type `T`, observing `__index` metafields.
    ///
    /// Iterates a Lua value as if it were an array of elements with type `T`, observing `__index` metafields. The
    /// iteration finishes when any element fails to convert to `T` - note that any failure to convert is treated just
    /// like if a `nil` element was encountered to indicate the end of the array. It does not cause an error.
    ///
    /// Because `__index` metafields can error, and `IteratorProtocol` is not allowed to, the iteration code must be
    /// passed in as a block. The block should return `.continueIteration` to continue iteration, or `.breakIteration`
    /// to break.
    ///
    /// ```swift
    /// // Assuming something behaving like { "abc", "def", "ghi" } is the only thing on the stack
    /// try L.for_ipairs(1, type: String.self) { i, val in
    ///     print("table[\(i)] is \(val)")
    ///     return .continueIteration
    /// }
    /// // Prints:
    /// // table[1] is abc
    /// // table[2] is def
    /// // table[3] is ghi
    /// ```
    ///
    /// Use ``for_ipairs(_:start:type:_:)-3v788`` instead to allow you to omit the `return .continueIteration` in
    /// cases where the block never needs to break.
    ///
    /// - Parameter index: Stack index of the value to iterate.
    /// - Parameter start: What table index to start iterating from. Default is `1`, ie the start of the array.
    /// - Parameter type: The expected type of the elements being iterated. If any element fails to convert, the
    ///   iteration will be halted early (as if `.breakIteration` was returned).
    /// - Parameter block: The code to execute.
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a Lua error is raised
    ///   during the execution of a `__index` metafield or if the value does not support indexing. Rethrows anything
    ///   thrown by `block`.
    public func for_ipairs<T>(_ index: CInt, start: lua_Integer = 1, type: T.Type, _ block: (lua_Integer, T) throws -> IteratorResult) throws {
        try for_ipairs(index, start: start, { i in
            if let val: T = self.tovalue(-1) {
                return try block(i, val)
            } else {
                return .breakIteration
            }
        })
    }

    /// Like ``for_ipairs(_:start:type:_:)-9mbw7`` but without the option to break from the iteration.
    ///
    /// This function behaves like ``for_ipairs(_:start:type:_:)-9mbw7`` except that `block` should not return anything.
    /// This is a convenience overload allowing you to omit writing `return .continueIteration` when the block never
    /// needs to exit the iteration early by using `return .breakIteration`.
    ///
    /// ```swift
    /// // Assuming something behaving like { "abc", "def", "ghi" } is the only thing on the stack
    /// try L.for_ipairs(1, type: String.self) { i, val in
    ///     print("table[\(i)] is \(val)")
    /// }
    /// // Prints:
    /// // table[1] is abc
    /// // table[2] is def
    /// // table[3] is ghi
    /// ```
    ///
    /// - Parameter index: Stack index of the value to iterate.
    /// - Parameter start: What table index to start iterating from. Default is `1`, ie the start of the array.
    /// - Parameter type: The expected type of the elements being iterated. If any element fails to convert, the
    ///   iteration will be halted early.
    /// - Parameter block: The code to execute.
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a Lua error is raised
    ///   during the execution of a `__index` metafield or if the value does not support indexing. Rethrows anything
    ///   thrown by `block`.
    public func for_ipairs<T>(_ index: CInt, start: lua_Integer = 1, type: T.Type, _ block: (lua_Integer, T) throws -> Void) throws {
        try for_ipairs(index, start: start, { i in
            if let val: T = self.tovalue(-1) {
                try block(i, val)
                return .continueIteration
            } else {
                return .breakIteration
            }
        })
    }

    @available(*, deprecated, message: "Will be removed in v1.0.0. Use overload with block returning IteratorResult or Void instead.")
    public func for_ipairs(_ index: CInt, start: lua_Integer = 1, _ block: (lua_Integer) throws -> Bool) throws {
        try for_ipairs(index, start: start, { i in
            return try block(i) ? .continueIteration : .breakIteration
        })
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

    private class PairsTypedRawIterator<K, V> : Sequence, IteratorProtocol {
        let L: LuaState
        let index: CInt
        let top: CInt
        init(_ L: LuaState, _ index: CInt) {
            self.L = L
            self.index = L.absindex(index)
            top = L.gettop()
            L.pushnil() // initial k
        }
        public func next() -> (K, V)? {
            if L.gettop() < top + 1 {
                // The loop better not have messed up the stack, we rely on k staying valid
                fatalError("Iteration popped more items from the stack than it pushed")
            }
            while true {
                L.settop(top + 1) // Pop everything except k
                let t = lua_next(L, index)
                if t == 0 {
                    // No more items
                    return nil
                }
                let k: K? = L.tovalue(top + 1)
                let v: V? = L.tovalue(top + 2)
                if let k, let v {
                    return (k, v)
                } else {
                    // Skip this element, keep iterating
                    continue
                }
            }
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
    /// To iterate with non-raw accesses, use ``for_pairs(_:_:)-2v2e3`` instead.
    ///
    /// The indexes to the key and value will always refer to the top 2 values on the stack, thus are provided for
    /// convenience only. `-2` and `-1` can be used instead, if desired. The stack is reset to `top` at the end of each
    /// iteration through the loop.
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

    /// Iterate all the members of a table whose types are `K` and `V`, using raw accesses.
    ///
    /// Returns a for-iterator that will iterate the values of the table at `index` on the stack, in an unspecified
    /// order. If the key or value cannot be converted to type `K` or `V` respectively (using `tovalue()`), then that
    /// pair is skipped and the iteration will continue to the next pair. Therefore, this function can be used to
    /// filter the table based on the key and value types. To iterate a table of mixed key and/or value types without
    /// potentially skipping elements, use ``pairs(_:)`` instead.
    ///
    /// The `__pairs` metafield is ignored if the table has one, that is to say raw accesses are used.
    ///
    /// ```swift
    /// // Assuming top of stack is a table
    /// // { a = 1, b = 2, c = 3, awkward = "notanint!" }
    /// for (k, v) in L.pairs(-1, type: (String.self, Int.self)) {
    ///     // k is a String, v is an Int
    ///     print("\(k) \(v)")
    /// }
    /// // ...might output the following:
    /// // b 2
    /// // c 3
    /// // a 1
    /// ```
    ///
    /// - Parameter index: Stack index of the table to iterate.
    /// - Parameter type: The key and value types to convert to, as a tuple.
    /// - Precondition: `index` must refer to a table value.
    public func pairs<K, V>(_ index: CInt, type: (K.Type, V.Type)) -> some Sequence<(K, V)> {
        precondition(self.type(index) == .table, "Value must be a table to iterate with pairs()")
        return PairsTypedRawIterator(self, index)
    }

    /// Push the 3 values needed to iterate the value at the top of the stack.
    ///
    /// This function is only exposed for implementations of pairs iterators to use, thus usually should not be called
    /// directly. The value is popped from the stack.
    ///
    /// - Returns: `false` (and pushes `next, value, nil`) if the value isn't iterable, otherwise `true`.
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if the value had a `__pairs`
    ///   metafield which errored.
    @discardableResult
    public func pushPairsParameters() throws -> Bool {
        let L = self
        if getmetafield(-1, "__pairs") == nil {
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
    ///     if /* something */ {
    ///         break
    ///     }
    /// }
    ///
    /// // Compared to:
    /// try L.for_pairs(-1) { k, v in
    ///     // iterates value observing the __pairs metafield if present.
    ///     if /* something */ {
    ///         return .breakIteration
    ///     }
    ///     return .continueIteration
    /// }
    /// ```
    ///
    /// - Parameter index: Stack index of the table to iterate.
    /// - Parameter block: The code to execute.
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a Lua error is raised
    ///   during the execution of an iterator function or a `__pairs` metafield, or if the value at `index` does not
    ///   support indexing.
    public func for_pairs(_ index: CInt, _ block: (CInt, CInt) throws -> IteratorResult) throws {
        push(index: index) // The value being iterated
        try pushPairsParameters() // pops value, pushes iterfn, state, initval
        try do_for_pairs(block)
    }

    /// Like ``for_pairs(_:_:)-2v2e3`` but without the option to break from the iteration.
    ///
    /// This function behaves like ``for_pairs(_:_:)-2v2e3`` except that `block` should not return anything. This is a
    /// convenience overload allowing you to omit writing `return .continueIteration` when the block never needs to
    /// exit the iteration early by using `return .breakIteration`.
    ///
    /// ```swift
    /// try L.for_pairs(-1) { k, v in
    ///     // iterates every item of value observing the __pairs metafield
    ///     // if present.
    /// }
    /// ```
    @inlinable
    public func for_pairs(_ index: CInt, _ block: (CInt, CInt) throws -> Void) throws {
        try for_pairs(index) { k, v in
            try block(k, v)
            return .continueIteration
        }
    }

    /// Iterate all the members of a value whose types are K and V, observing `__pairs` metafields.
    ///
    /// Iterate all the members of a `table` or `userdata` whose types are K and V, observing `__pairs` metafields if
    /// present, in an unspecified order. If the key or value cannot be converted to type `K` or `V` respectively
    /// (using `tovalue()`), then that pair is skipped and the iteration will continue to the next pair. Therefore,
    /// this function can be used to filter the table based on the key and value types. To iterate a table of mixed key
    /// and/or value types without potentially skipping elements, use ``for_pairs(_:_:)-2v2e3`` instead.
    ///
    /// ```swift
    /// // Assuming top of stack is a table
    /// // { a = 1, b = 2, c = 3, awkward = "notanint!" }
    /// try L.for_pairs(-1, type: (String.self, Int.self)) { k, v in
    ///     // k is a String, v is an Int
    ///     print("\(k) \(v)")
    ///     return .continueIteration
    /// }
    /// // ...might output the following:
    /// // b 2
    /// // c 3
    /// // a 1
    /// ```
    ///
    /// Use ``for_pairs(_:type:_:)-8xaw8`` instead to allow you to omit the `return .continueIteration` in cases where
    /// the block never needs to break.
    ///
    /// - Parameter index: Stack index of the table to iterate.
    /// - Parameter type: The key and value types to convert to, as a tuple.
    /// - Parameter block: The code to execute.
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a Lua error is raised
    ///   during the execution of an iterator function or a `__pairs` metafield, or if the value at `index` does not
    ///   support indexing.
    public func for_pairs<K, V>(_ index: CInt, type: (K.Type, V.Type), _ block: (K, V) throws -> IteratorResult) throws {
        push(index: index) // The value being iterated
        try pushPairsParameters() // pops value, pushes iterfn, state, initval
        try do_for_pairs({ k, v in
            if let key: K = self.tovalue(k),
               let val: V = self.tovalue(v) {
                return try block(key, val)
            } else {
                return .continueIteration
            }
        })
    }

    /// Like ``for_pairs(_:type:_:)-9g8dt`` but without the option to break from the iteration.
    ///
    /// This function behaves like ``for_pairs(_:type:_:)-9g8dt`` except that `block` should not return anything. This
    /// is a convenience overload allowing you to omit writing `return .continueIteration` when the block never needs
    /// to exit the iteration early by using `return .breakIteration`.
    ///
    /// - Parameter index: Stack index of the table to iterate.
    /// - Parameter type: The key and value types to convert to, as a tuple.
    /// - Parameter block: The code to execute.
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a Lua error is raised
    ///   during the execution of an iterator function or a `__pairs` metafield, or if the value at `index` does not
    ///   support indexing.
    public func for_pairs<K, V>(_ index: CInt, type: (K.Type, V.Type), _ block: (K, V) throws -> Void) throws {
        push(index: index) // The value being iterated
        try pushPairsParameters() // pops value, pushes iterfn, state, initval
        try do_for_pairs({ k, v in
            if let key: K = self.tovalue(k),
               let val: V = self.tovalue(v) {
                try block(key, val)
            }
            return .continueIteration
        })
    }

    @available(*, deprecated, message: "Will be removed in v1.0.0. Use overload with block returning IteratorResult or Void instead.")
    public func for_pairs(_ index: CInt, _ block: (CInt, CInt) throws -> Bool) throws {
        try for_pairs(index, { k, v in
            return try block(k, v) ? .continueIteration : .breakIteration
        })
    }

    // Top of stack must have iterfn, state, initval
    internal func do_for_pairs(_ block: (CInt, CInt) throws -> IteratorResult) throws {
        // Ensure this is set up
        push(function: luaswift_do_for_pairs)
        push(function: callUnmanagedClosure)
        rawset(LUA_REGISTRYINDEX)

        try withoutActuallyEscaping(block) { escapingBlock in
            let wrapper = LuaClosureWrapper({ L in
                // The stack is exactly in the state luaswift_do_for_pairs left it, so k and v are at 4 and 5
                let iteratorResult = try escapingBlock(4, 5)
                return iteratorResult == .continueIteration ? 1 : 0
            })

            // Note, we push wrapper as an unmanaged lightuserdata here rather than as a function, to shortcut the need
            // for an additional Lua call frame every time wrapper is called within the iteration loop, and also avoid
            // needing a dynamic cast as part of touserdata/unchecked_touserdata. By avoiding pushing wrapper as a full
            // userdata we also don't need to worry about escapingBlock actually escaping (due to wrapper's userdata
            // having a reference to it, and being subject to deferred deinit by the Lua garbage collector) which in
            // turn simplifies the implementation of LuaClosureWrapper.
            push(lightuserdata: Unmanaged.passUnretained(wrapper).toOpaque(), toindex: -2)
            // iterfn, state, wrapper, initval
            push(function: luaswift_do_for_pairs, toindex: -5)
            try pcall(nargs: 4, nret: 0)
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
    /// This function expects the string to be representable in the default String encoding, and will halt the program
    /// if not. To have an error thrown instead, use ``push(encodable:toindex:)``.
    ///
    /// See also ``getDefaultStringEncoding()``.
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
    /// - Parameter string: The `String` to push.
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
    /// * Do not throw Swift or Lua errors.
    /// * Do not capture any variables.
    /// * Do not call any of the yield or yieldable APIs (`pcallk`, `lua_pcallk`, etc).
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

    /// Push a Swift value on to the stack as a `userdata`.
    ///
    /// From a lifetime perspective, this function behaves as if the value were
    /// assigned to another variable of type `Any`, and when the Lua userdata is
    /// garbage collected, this variable goes out of scope.
    ///
    /// To make the object usable from Lua, declare a metatable for the value's type using
    /// ``register(_:)-8rgnn``. Note that this function always uses the dynamic type of the value, and
    /// not whatever `T` is, when calculating what metatable to assign the object. Thus `push(userdata: foo)` and
    /// `push(userdata: foo as Any)` will behave identically.
    ///
    /// Pushing a value of a type which has no metatable previously registered will generate a warning, and the object
    /// will have no metamethods declared on it, except for `__gc` which is always defined in order that Swift object
    /// lifetimes are preserved. This does not apply to types which conform to ``PushableWithMetatable``, which will
    /// automatically be registered if they are not already.
    ///
    /// > Note: This function always pushes a `userdata` - if `val` represents any other type (for example, an integer)
    ///   it will not be converted to that type in Lua. Use ``push(any:toindex:)`` instead to automatically convert
    ///   types to their Lua native representation where possible.
    ///
    /// > Important: Do not change the metatable of a LuaSwift userdata by calling `lua_setmetatable()` or similar.
    ///   Doing so may leak memory or crash the program.
    ///
    /// - Parameter userdata: The value to push on to the Lua stack.
    /// - Parameter toindex: See <doc:LuaState#Push-functions-toindex-parameter>.
    public func push<T>(userdata: T, toindex: CInt = -1) {
        // Special case to permit PushableWithMetatable to auto register regardless of how it was pushed.
        if let pushableWithMetatable = userdata as? any PushableWithMetatable {
            pushableWithMetatable.checkRegistered(self)
        }
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
    /// * If `value` conforms to ``Pushable``, the value's ``Pushable/push(onto:)`` is used.
    /// * If `value` is `UInt8`, it is pushed as an integer. This special case is required because `UInt8` is not
    ///   `Pushable`.
    /// * If `value` is `[UInt8]` or otherwise conforms to `ContiguousBytes` (which includes `Data`,
    ///   `UnsafeRawBufferPointer` and others), it is pushed as a `string` of those bytes.
    /// * If `value` is one of the Foundation types `NSNumber`, `NSString` or `NSData`, or is a Core Foundation type
    ///   that is toll-free bridged to one of those types, then it is treated like an integer, `String`, or `Data`
    ///   respectively.
    /// * If `value` is an `Array` or `Dictionary` that is not `Pushable`, a `table` is created and `push(any:)`
    ///   is called recursively to push its elements. In the case of an `Array`, the Lua table uses Lua 1-based array
    ///   indexing conventions, so the first element of `value` will be at index 1.
    /// * If `value` is a `lua_CFunction`, ``push(function:toindex:)`` is used.
    /// * If `value` is a `LuaClosure`, ``push(_:numUpvalues:toindex:)`` is used (with `numUpvalues=0`).
    /// * If `value` is a zero-argument closure that returns `Void` or `Any?`, it is pushed using `push(closure:)`.
    ///   Due to limitations in Swift type inference, these are the only closure types that are handled in this way.
    /// * If `value` is a `UnsafeMutableRawPointer`, ``push(lightuserdata:toindex:)`` is used.
    /// * Any other type is pushed as a `userdata` using ``push(userdata:toindex:)``.
    ///
    /// Note that whether the type is `Encodable` or not, does not affect how the value is pushed - in other words
    /// `push(any:)` will not use `push(encodable:)` for `Encodable` types. To make a type be pushed using its
    /// `Encodable` representation, make the type implement `Pushable` and have the implementation call
    /// `push(encodable:)`.
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
            newtable(narr: CInt(clamping: array.count))
            for (i, val) in array.enumerated() {
                push(any: val)
                lua_rawseti(self, -2, lua_Integer(i + 1))
            }
        case let dict as Dictionary<AnyHashable, Any>:
            newtable(nrec: CInt(clamping: dict.count))
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
        case let ptr as UnsafeMutableRawPointer:
            push(lightuserdata: ptr)
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
    /// `.none` will result in 1 value (`nil`) being pushed. Nested tuples are not supported. If the argument is a
    /// named tuple, the names are ignored and it is treated the same as an unnamed tuple.
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

        let mirror = Mirror(reflecting: tuple)
        if mirror.displayStyle == .tuple {
            let n = CInt(mirror.children.count)
            checkstack(n)
            for (_, child) in mirror.children {
                push(any: child)
            }
            return n
        } else {
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

    /// Push a raw pointer on to the stack as a light userdata.
    public func push(lightuserdata: UnsafeMutableRawPointer?, toindex: CInt = -1) {
        lua_pushlightuserdata(self, lightuserdata)
        if toindex != -1 {
            insert(toindex)
        }
    }

    /// Encodes the value as a Lua value and pushes on to the stack.
    ///
    /// Structs and classes are converted to a Lua `table` (without a metatable), in a similar way to how
    /// `JSONEncoder.encode()` behaves (but the result is a Lua table left on the stack, rather than a serialised JSON
    /// object returned as a `Data`).
    ///
    /// Note that this function takes a copy of `value`, and changes made to the resulting Lua value will not affect the
    /// original `value`. Also note that encoding the value only copies its data; any functions it defines will not
    /// be available on the resulting Lua value. Consider [bridging](doc:BridgingSwiftToLua) the type instead, in that
    /// case.
    ///
    /// As with ``push(any:toindex:)``, `[UInt8]` and any values conforming to `ContiguousBytes` are encoded as strings.
    ///
    /// Some Swift values cannot be represented in Lua, and this function will throw `EncodingError.invalidValue` if
    /// one is encountered while encoding `value`. Unsupported values include:
    ///
    /// * Unsigned integers whose values will not fit in a `lua_Integer`.
    /// * Arrays (or ordered collections) which contain `nil` elements.
    /// * Strings which are not representable in the default string encoding.
    ///
    /// If an error is thrown, the Lua stack will be unchanged.
    ///
    /// Use ``todecodable(_:)`` to convert Lua values back to Swift types (assuming the type also implements
    ///  `Decodable`).
    ///
    /// - Parameter value: The value to push on to the Lua stack, which must implement `Encodable`.
    /// - Parameter toindex: See <doc:LuaState#Push-functions-toindex-parameter>.
    /// - Throws: `EncodingError` if the value cannot be represented in Lua.
    public func push(encodable value: Encodable, toindex: CInt = -1) throws {
        do {
            let encoder = LuaEncoder(state: self)
            try encoder.encode(value)
        } catch {
            pop() // encoder going out of scope will have reset the stack to one more than when we started
            throw error
        }

        if toindex != -1 {
            insert(toindex)
        }
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
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a Lua error is raised
    ///   during the execution of the function.
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
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a Lua error is raised
    ///   during the execution of the function.
    /// - Precondition: The top of the stack must contain a function/callable and `nargs` arguments.
    public func pcall(nargs: CInt, nret: CInt, msgh: lua_CFunction?) throws {
        if let error = trypcall(nargs: nargs, nret: nret, msgh: msgh) {
            throw error
        }
    }

    /// Make a protected call to a Lua function, returning an `Error` if an error occurred.
    ///
    /// The function and any arguments must already be pushed to the stack in the same way as for
    /// [`lua_pcall()`](https://www.lua.org/manual/5.4/manual.html#lua_pcall)
    /// and are popped from the stack by this call. If the function errors, no results are pushed
    /// to the stack and an `Error` is returned. Otherwise `nret` results are pushed and `nil`
    /// is returned.
    ///
    /// - Parameter nargs: The number of arguments to pass to the function.
    /// - Parameter nret: The number of expected results. Can be ``MultiRet``
    ///   to keep all returned values.
    /// - Parameter msgh: An optional message handler function to be called if the function errors.
    /// - Returns: an error (of type determined by whether a ``LuaErrorConverter`` is set) if the function errored,
    ///   `nil` otherwise.
    public func trypcall(nargs: CInt, nret: CInt, msgh: lua_CFunction?) -> Error? {
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
            remove(index)
        }
        return error
    }

    /// Make a protected call to a Lua function, returning an `Error` if an error occurred.
    ///
    /// The function and any arguments must already be pushed to the stack in the same way as for
    /// [`lua_pcall()`](https://www.lua.org/manual/5.4/manual.html#lua_pcall)
    /// and are popped from the stack by this call. If the function errors, no results are pushed
    /// to the stack and an `Error` is returned. Otherwise `nret` results are pushed and `nil`
    /// is returned.
    ///
    /// - Parameter nargs: The number of arguments to pass to the function.
    /// - Parameter nret: The number of expected results. Can be ``MultiRet``
    ///   to keep all returned values.
    /// - Parameter msgh: The stack index of a message handler function, or `0` to specify no
    ///   message handler. The handler is not popped from the stack.
    /// - Returns: an error (of type determined by whether a ``LuaErrorConverter`` is set) if the function errored,
    ///   `nil` otherwise.
    public func trypcall(nargs: CInt, nret: CInt, msgh: CInt) -> Error? {
        let err = lua_pcall(self, nargs, nret, msgh)
        if err == LUA_OK {
            return nil
        } else {
            return popErrorFromStack()
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
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a Lua error is raised
    ///   during the execution of the function.
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
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a Lua error is raised
    ///   during the execution of the function.
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
    }

    /// Make a protected call to a Lua function which is allowed to yield.
    ///
    /// Make a yieldable call to a Lua function. Must be the last call in a `LuaClosure`, and is not valid to be called
    /// from any other context.
    ///
    /// This is the LuaSwift equivalent to [`lua_pcallk()`](https://www.lua.org/manual/5.4/manual.html#lua_pcallk).
    /// See [Handling Yields in C](https://www.lua.org/manual/5.4/manual.html#4.5) for more details. This function
    /// behaves similarly to `lua_pcallk`, with the exception that the continuation function is passed in as a
    /// ``LuaPcallContinuation`` rather than a `lua_KFunction`, and does not need the additional explicit call to the
    /// continuation function in the case where no yield occurs.
    ///
    /// For example, where a yieldable `lua_CFunction` implemented in C might look like this:
    ///
    /// ```c
    /// int my_cfunction(lua_State *L) {
    ///     /* stuff */
    ///     return continuation(L,
    ///         lua_pcallk(L, nargs, nret, msgh, ctx, continuation), ctx);
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
    /// * If the call errors, `continuation` be called with `status.error` set to an `Error` (of type determined by
    ///   whether a ``LuaErrorConverter`` is set), and the stack as it was before the call (minus the `nargs` and
    ///   function, and without any values added).
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
    /// protected, and therefore that the continuation will not be called if an error occurs (instead, the calling
    /// LuaClosure will error). The same caveats apply, in that `callk` can only be called as return from a
    /// `LuaClosure`.
    ///
    /// > Note: This is the only unprotected call function which is safe to call from Swift, due to the way
    ///   continuations are implemented and the constraints they impose. Neither `lua_call()` nor `lua_callk()` are
    ///   safe to call from Swift.
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
    /// > Important: When the continuation closure is called, the stack will be exactly as per the definition of
    ///   `lua_yieldk()` (ie as it was at the point of the yield call, minus `nresults` values, plus whatever values
    ///   added by the resume). While the thread is yielded however, the exact stack state is not defined (other than
    ///   the top `nresults` values) - LuaSwift uses some stack slots for housekeeping the continuation. Do not modify
    ///   the thread's stack while it is yielded (other than to pop the `nresults` values and push any values for the
    ///   resume).
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
        } else {
            pushnil()
        }
        push(nresults)
        return LUASWIFT_CALLCLOSURE_YIELD
    }

    /// Create a new thread, see [`lua_newthread()`](https://www.lua.org/manual/5.4/manual.html#lua_newthread).
    ///
    /// The resulting thread is also pushed on to the stack.
    public func newthread() -> LuaState {
        return lua_newthread(self)
    }

    /// Close the thread, see [`lua_closethread()`](https://www.lua.org/manual/5.4/manual.html#lua_closethread).
    ///
    /// - Parameter from: The coroutine that is resetting `self`, or `nil` if there is no such coroutine.
    /// - Returns: If the thread errored, or if a `__close` metamethod errored while cleaning up the to-be-closed
    ///   variables, returns that error, otherwise returns `nil`. If the thread errored, this will be the same error as
    ///   returned from ``resume(from:nargs:)``, assuming the stack has not been modified in the interim.
    /// > Note: When using Lua versions 5.4.0 to 5.4.5, this calls `lua_resetthread()` instead. On versions before 5.4,
    ///   it has no effect and always returns `nil`.
    ///
    /// > Note: When using Lua versions 5.4.0 to 5.4.2, this function will return `nil` if the thread errored, rather
    ///   than returning the error from the thread.
    @discardableResult
    public func closethread(from: LuaState?) -> Error? {
        let status = luaswift_closethread(self, from)
        if status == LUA_OK || gettop() == 0 { // Be paranoid in case the caller has already reset the stack
            return nil
        } else {
            return popErrorFromStack()
        }
    }

    /// Start or resume a coroutine in this thread.
    ///
    /// - Parameter from: The coroutine that is resuming `self`, or `nil` if there is no such coroutine.
    /// - Parameter nargs: The number of arguments to pass to the coroutine.
    /// - Returns: A tuple of values: `nresults` being the number of results returned from the coroutine or yield;
    ///   `yielded` which is `true` if the coroutine yielded and `false` otherwise; and `error` which is non-nil if
    ///   the coroutine threw an error.
    ///
    /// Start or resume a coroutine in this thread, see
    /// [`lua_resume()`](https://www.lua.org/manual/5.4/manual.html#lua_resume). `self` should be a `LuaState` returned
    /// by ``newthread()`` or `lua_newthread()`. To start a coroutine, first push the main function on to the stack,
    /// followed by `nargs` arguments, then call resume. To resume a coroutine, remove the `nresults` results from the
    /// previous `resume()` call, then push `nargs` values to be passed as the results from `yield`, then call
    /// `resume()`.
    ///
    /// On return, if `error` is `nil`, `nresults` values are present on the top of the stack.
    ///
    /// - Precondition: If the coroutine is being started, the stack must consist of a function/callable and `nargs`
    ///   arguments. If the coroutine is being resumed, the top of the stack must contain `nargs` arguments.
    ///
    /// - Important: Prior to Lua 5.4, all values are removed from the stack by this call, so the stack will only
    ///   contain `nresults` values when `resume()` returns. In 5.4 and later, only `nargs` results (and the function,
    ///   if the coroutine is being started) are removed, and the `nresults` values are added to the top of the stack.
    ///   See [`lua_resume` (5.3)](https://www.lua.org/manual/5.3/manual.html#lua_resume) vs
    ///   [`lua_resume` (5.4)](https://www.lua.org/manual/5.4/manual.html#lua_resume).
    public func resume(from: LuaState?, nargs: CInt) -> (nresults: CInt, yielded: Bool, error: Error?) {
        var nresults: CInt = 0
        let status = luaswift_resume(self, from, nargs, &nresults)
        if status == LUA_OK || status == LUA_YIELD {
            return (nresults: nresults, yielded: status == LUA_YIELD, error: nil)
        } else {
            return (nresults: 0, yielded: false, error: popErrorFromStack())
        }
    }

    /// Set a custom handler for converting Lua errors to Swift ones.
    ///
    /// By default, errors thrown or returned from any of the `pcall()` APIs are expected to be strings, and are
    /// converted to a Swift ``LuaCallError`` using [`popFromStack()`](doc:LuaCallError/popFromStack(_:)). If the
    /// functions being called are expected to error with other kinds of value, a custom converter can be supplied here
    /// to convert them to whatever custom `Error` type is suitable.
    ///
    /// Generally speaking, any custom converter should fall back to calling `LuaCallError.popFromStack()` if the value
    /// on the stack cannot be converted to the expected custom format, so that string errors are always handled.
    ///
    /// It is recommended that any `Error` returned also conforms to `Pushable`, so that errors can losslessly
    /// round-trip when for example thrown from within a `LuaClosure`.
    ///
    /// `setErrorConverter` only needs to be called once per main-thread LuaState (its setting is shared with any
    /// coroutines created by that state). It should be called before any uses of `pcall` that might need custom
    /// handling.
    ///
    /// - Parameter converter: The converter to be used for any errors raised from any of the LuaSwift `pcall()` APIs.
    ///   Can be `nil` to revert to the default `LuaCallError.popFromStack()` implementation.
    public func setErrorConverter(_ converter: LuaErrorConverter?) {
        if let converter {
            getState().errorConverter = converter
        } else if let state = maybeGetState() {
            state.errorConverter = nil
        }
    }

    /// Pops a value from the stack and constructs an `Error` from it.
    ///
    /// The type of the result is determined by whether a ``LuaErrorConverter`` is set.
    public func popErrorFromStack() -> Error {
        if let converter = maybeGetState()?.errorConverter {
            return converter.popErrorFromStack(self)
        } else {
            return LuaCallError.popFromStack(self)
        }
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
    @available(*, deprecated, message: "Will be removed in v1.0.0. Use register(Metatable) instead.")
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

    /// Register that values of type `NewType` should use the same metatable as `RegisteredType`.
    ///
    /// - Parameter type: The type to register a metatable for.
    /// - Parameter usingExistingMetatableFor: The type whose metatable should also be used for `type`. Must refer to a
    ///   type that is already registered.
    ///
    /// This is useful when there are multiple derived types whose Lua functionality depends only on a common base class
    /// or protocol.
    ///
    /// For example, if you have a class hierarchy like this:
    ///
    /// ```swift
    /// class Base {
    ///     func foo() -> String { return "Base.foo" }
    /// }
    /// class SubClassOne: Base {
    ///     override func foo() -> String { return "SubClassOne.foo" }
    /// }
    /// class SubClassTwo: Base {
    ///     override func foo() -> String { return "SubClassTwo.foo" }
    /// }
    /// ```
    ///
    /// Then to declare a metatable for `Base` and its subclasses:
    ///
    /// ```swift
    /// L.register(Metatable<Base>(fields: [
    ///     "foo": .memberfn { $0.foo() }
    /// ])
    /// L.register(type: SubClassOne.self, usingExistingMetatableFor: Base.self)
    /// L.register(type: SubClassTwo.self, usingExistingMetatableFor: Base.self)
    /// ```
    ///
    /// > Note: It is not (currently) possible for the compiler to enforce that `NewType` implements or inherits
    ///   `RegisteredType`. It is up to the caller to ensure that `NewType` is compatible with the metatable definitions
    ///   in `RegisteredType`.
    ///
    /// - Precondition: `NewType` must not already have a metatable registered for it. `RegisteredType` must
    ///   already have a metatable registered for it.
    public func register<NewType, RegisteredType>(type: NewType.Type, usingExistingMetatableFor: RegisteredType.Type) {
        let existingTypeName = makeMetatableName(for: RegisteredType.self)
        if luaL_getmetatable(self, existingTypeName) == LUA_TNIL {
            preconditionFailure("\(RegisteredType.self) must already have a metatable registered for it")
        }
        let newTypeName = makeMetatableName(for: NewType.self)
        if luaL_getmetatable(self, newTypeName) != LUA_TNIL {
            preconditionFailure("Metatable for type \(NewType.self) is already registered")
        }
        pop()
        rawset(LUA_REGISTRYINDEX, utf8Key: newTypeName) // pops existingTypeName metatable
    }

    @available(*, deprecated, message: "Will be removed in v1.0.0. Use register(DefaultMetatable) instead.")
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
        return Metatable<T>(mt: metafields, unsynthesizedFields: nil)
    }

    private func addNonPropertyFieldsToMetatable(_ fields: [String: InternalUserdataField]) {
        push(index: -1)
        rawset(-2, utf8Key: "__index")

        for (k, v) in fields {
            switch v {
            case .function(let function):
                push(function: function)
            case .closure(let closure):
                push(closure)
            case .constant(let closure):
                // Guaranteed not to throw, because closure will always be the one defined by
                // Metatable.FieldType.constant() which does not throw and is only a LuaClosure so it can capture the
                // value and type-erase it.
                let _ = try! closure(self)
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
    /// The result is pushed on to the stack.
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
    /// The result is pushed on to the stack.
    ///
    /// - Precondition: The value at `index` must be a table.
    /// - Parameter index: The stack index of the table.
    /// - Parameter key: The key to use, which will always be pushed using UTF-8 encoding.
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
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a Lua error is raised
    ///   during the call to `lua_gettable`.
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
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a Lua error is raised
    ///   during the call to `lua_gettable`.
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
    /// Example:
    /// ```swift
    /// L.newtable()
    /// L.push("key")
    /// L.push("value")
    /// L.rawset(-3) // -3 is table, -2 is key, -1 is value
    /// ```
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
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a Lua error is raised
    ///   during the call to `lua_settable`.
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
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a Lua error is raised
    ///   during the call to `lua_settable`.
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
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a Lua error is raised
    ///   during the call to `lua_settable`.
    @inlinable
    public func set<K: Pushable, V: Pushable>(_ index: CInt, key: K, value: V) throws {
        let absidx = absindex(index)
        push(key)
        push(value)
        try set(absidx)
    }

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
        remove(-2)
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

    /// For the object at the given index, pushes the specified field from its metatable onto the stack.
    ///
    /// If the object does not have a metatable or the metatable does not have this field, pushes nothing onto the stack
    /// and returns `nil`.
    ///
    /// - Parameter index: The stack index of the object.
    /// - Parameter field: The name of the metafield.
    /// - Returns: The type of the resulting value, or `nil` if the object does not have a metatable or the metatable
    ///   does not have this field.
    @discardableResult
    public func getmetafield(_ index: CInt, _ field: String) -> LuaType? {
        let t = luaL_getmetafield(self, index, field)
        if t == LUA_TNIL {
            return nil
        } else {
            return LuaType(ctype: t)!
        }
    }

    /// Get the metatable for the value at the given stack index.
    ///
    /// If the value at the given index has a metatable, the function pushes that metatable onto the stack and returns
    /// `true`. Otherwise, the function returns `false` and pushes nothing on the stack.
    ///
    /// - Parameter index: The stack index of the value.
    /// - Returns: true if the value has a metatable.
    @inlinable @discardableResult
    public func getmetatable(_ index: CInt) -> Bool {
        return lua_getmetatable(self, index) == 1
    }

    // MARK: - Misc functions

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
    @available(*, deprecated, renamed: "pushglobals", message: "Will be removed in v1.0.0. Use pushglobals() instead.")
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
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a Lua error is raised
    ///   during the execution of the function.
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
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a Lua error is raised
    ///   during the execution of the module function. Rethrows if `closure` throws.
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
    /// To raise a non-string error (assuming a suitable ``LuaErrorConverter`` has been configured), push the required
    /// value on to the stack and call `throw L.popErrorFromStack()`.
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
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if the value had a `__len`
    ///   metamethod which errored.
    public func len(_ index: CInt) throws -> lua_Integer? {
        let t = type(index)
        if t == .string {
            // Len on strings cannot fail or error
            return rawlen(index)!
        }
        let absidx = absindex(index)
        if getmetafield(index, "__len") == nil {
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
    /// See [`lua_rawequal`](https://www.lua.org/manual/5.4/manual.html#lua_rawequal).
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
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if an `__eq` metamethod
    ///   errored.
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
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a metamethod errored.
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

    /// The type of operation to perform in ``arith(_:)``.
    public enum ArithOp : CInt {
        /// Performs addition (`+`).
        case add = 0 // LUA_OPADD
        /// Performs subtraction (`-`).
        case sub = 1 // LUA_OPSUB
        /// Performs multiplication (`*`).
        case mul = 2 // LUA_OPMUL
        /// Performs modulo (`%`).
        case mod = 3 // LUA_OPMOD
        /// Performs exponentiation (`^`).
        case pow = 4 // LUA_OPPOW
        /// Performs floating-point division (`/`).
        case div = 5 // LUA_OPDIV
        /// Performs floor division (`//`).
        case idiv = 6 // LUA_OPIDIV
        /// Performs bitwise AND (`&`).
        case band = 7 // LUA_OPBAND
        /// Performs bitwise OR (`&`).
        case bor = 8 // LUA_OPBOR
        /// Performs bitwise XOR (`~`).
        case bxor = 9 // LUA_OPBXOR
        /// Performs left shift (`<<`).
        case shl = 10 // LUA_OPSHL
        /// Performs right shift (`>>`).
        case shr = 11 // LUA_OPSHR
        /// Performs arithmetic negation (unary `-`).
        case unm = 12 // LUA_OPUNM
        /// Performs bitwise NOT (`~`).
        case bnot = 13 // LUA_OPBNOT
    }

    /// Perform a Lua arithmetic or bitwise operation on the value(s) on the top of the stack.
    ///
    /// See [`lua_arith`](https://www.lua.org/manual/5.4/manual.html#lua_arith). One or two values are popped from the
    /// stack, depending on the operation. The result is left on the top of the stack. May invoke metamethods.
    ///
    /// - Parameter op: The operator to perform.
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a metamethod errored.
    public func arith(_ op: ArithOp) throws {
        let nargs: CInt
        switch op {
            case .unm, .bnot:
                nargs = 1
            default:
                nargs = 2
        }
        precondition(gettop() >= nargs, "Expected at least \(nargs) values on the stack")
        push(function: luaswift_arith, toindex: -1 - nargs)
        push(op.rawValue)
        try pcall(nargs: nargs + 1, nret: 1, traceback: false)
    }

    /// Get the main thread for this state.
    ///
    /// Unless called from within a coroutine, this will be the same as `self`.
    public func getMainThread() -> LuaState {
        // Optimisation - checking pushThread() will always be much less work than doing a lookup in the registry table,
        // even if it probably doesn't make a noticable difference most of the time.
        let isMainThread = pushthread()
        pop()
        if isMainThread {
            return self
        }

        rawget(LUA_REGISTRYINDEX, key: LUA_RIDX_MAINTHREAD)
        defer {
            pop()
        }
        return lua_tothread(self, -1)!
    }

    /// Initializes a `luaL_Buffer` and runs the given code which uses it.
    ///
    /// See [the Lua documentation](https://www.lua.org/manual/5.4/manual.html#luaL_Buffer) for details of how
    /// `luaL_Buffer` works in C.
    ///
    /// This function exists because `luaL_Buffer` cannot be treated like a Swift struct because the Lua buffer
    /// functions internally assume the struct will not move in memory (between the calls to `luaL_buffinit()` and
    /// `luaL_pushresult()`), and Swift makes no such guarantee by default. Calling `withBuffer()`, which forces the
    /// code using it to be scoped, guarantees that the buffer object is not relocated, and also ensures
    /// `luaL_pushresult()` is always called.
    ///
    /// Normally in Swift there isn't much need for `luaL_Buffer` -- Swift already has easy memory management -- but
    /// sometimes when using Swift to interface with another C library, it can be useful to write code that's as
    /// structurally similar as possible to what the C code to access it would be. At such points using `luaL_Buffer`
    /// from Swift might be desirable, and `withBuffer()` exists to facilitate that.
    ///
    /// `luaL_buffinit()` and `luaL_pushresult()` are automatically called, and should not be called by `fn`. If
    /// `fn` throws, `luaL_pushresult()` is still called. `withBuffer()` only `throws` if `fn` does, hence why the
    /// example below does not need to write `try L.withBuffer()`.
    ///
    /// Example:
    /// ```swift
    /// import CLua
    /// // ...
    /// let chunksize = 2048
    /// L.withBuffer() { b in
    ///     // Populate b however is appropriate, for example:
    ///     while true {
    ///         let ptr = luaL_prepbuffsize(b, chunksize)!
    ///         let n = fread(ptr, 1, chunksize, some_file)
    ///         luaL_addsize(b, n)
    ///         if n < chunksize {
    ///             break
    ///         }
    ///     }
    /// }
    /// // The resulting string is left on the top of the stack
    /// ```
    ///
    /// - Parameter fn: Closure which uses the `luaL_Buffer`.
    public func withBuffer(_ fn: (UnsafeMutablePointer<luaL_Buffer>) throws -> Void) rethrows {
        var buf = luaL_Buffer()
        try withUnsafeMutablePointer(to: &buf) { b in
            luaL_buffinit(self, b)
            defer {
                luaL_pushresult(b)
            }
            try fn(b)
        }
    }

    /// Concatenate the `n` topmost items on the stack.
    ///
    /// The `n` topmost items are popped from the stack, and the result of concatenating them is left on the stack. May
    /// invoke `__concat` metamethods.
    ///
    /// - Parameter n: The number of items to concatenate.
    /// - Throws: an error (of type determined by whether a ``LuaErrorConverter`` is set) if a `__concat` metamethod
    ///   errored.
    public func concat(_ n: CInt) throws {
        precondition(n <= lua_gettop(self), "Cannot concat more values than are on the stack")
        push(luaswift_concat, toindex: -n - 1)
        push(n)
        try pcall(nargs: n + 1, nret: 1)
    }

    // MARK: - String match/gsub

    /// Swift wrapper around `string.match()`.
    ///
    /// This helper function allows Lua-style pattern matching on Swift Strings. See
    /// [`string.match()`](https://www.lua.org/manual/5.4/manual.html#pdf-string.match) for details.
    ///
    /// - Parameter string: The string to search in.
    /// - Parameter pattern: The pattern to search for. This can use any of the pattern items described
    ///   [in the Lua manual](https://www.lua.org/manual/5.4/manual.html#6.4.1).
    /// - Parameter pos: The position in `string` to start searching from. Note this is a _Lua_ string offset, ie is
    ///   one-based and dependent on what byte sequence the default string encoding outputs. By default `pos` is 1, ie
    ///   the search starts from the beginning of `string`.
    /// - Returns: An array of the pattern captures, or `nil` if the pattern was not found. Each array item will be
    ///   either a String, or an Int if the pattern was `()`. Note that string indexes returned by `()` will _not_
    ///   be adjusted to be zero-based - they will be exactly the values returned by `string.match()`.
    /// - Throws: ``LuaArgumentError`` if an error was thrown by `string.match()`, for example because of an invalid
    ///   pattern item in `pattern`, or if a result `string` is not decodable using the default String encoding.
    /// - Precondition: The `string` library must be opened in this LuaState.
    public func match(string: String, pattern: String, pos: Int = 1) throws -> [AnyHashable]? {
        let top = gettop()
        defer {
            settop(top)
        }
        let t = getglobal("string")
        precondition(t == .table, "String library not opened?")
        rawget(-1, utf8Key: "match")
        remove(-2) // string

        push(string)
        push(pattern)
        push(pos)
        do {
            try pcall(nargs: 3, nret: MultiRet, traceback: false)
        } catch {
            throw LuaArgumentError(errorString: String(describing: error))
        }
        if isnil(top + 1) {
            return nil
        }
        var result: [AnyHashable] = []
        for arg in top + 1 ... gettop() {
            if isinteger(arg) {
                result.append(tointeger(arg)!)
            } else {
                // No need to check it's of Lua type string, there's nothing else match will return
                guard let str = tostring(arg) else {
                    let resultIdx = arg - top
                    throw LuaArgumentError(errorString: "Match result #\(resultIdx) is not decodable using the default String encoding")
                }
                result.append(str)
            }
        }
        return result
    }

    private func checkStringMatch(array: [AnyHashable], index: Int) throws -> String {
        guard let result = array[index] as? String else {
            throw LuaArgumentError(errorString: "Match result #\(index+1) is not a string")
        }
        return result
    }

    private func checkMatchSize(_ array: [AnyHashable], _ size: Int) throws {
        if array.count != size {
            throw LuaArgumentError(errorString: "Expected \(size) match results, actually got \(array.count)")
        }
    }

    /// Convenience wrapper around `match()` for when the pattern results in a single string.
    ///
    /// As per ``match(string:pattern:pos:)`` except that `pattern` must contain exactly zero or one captures, and the
    /// single result is returned as an optional String rather than an optional array with a single element.
    ///
    /// > Note: Attempting to use a `()` capture will result in `LuaArgumentError` being thrown (if the pattern
    ///   matches). Call ``match(string:pattern:pos:)`` instead to use `()` captures.
    ///
    /// - Throws: ``LuaArgumentError`` if an error was thrown by `match()`, for example because of an invalid pattern
    ///   item in `pattern`, or if `match()` did not return nil or exactly one String result.
    public func matchString(string: String, pattern: String, pos: Int = 1) throws -> String? {
        guard let result = try match(string: string, pattern: pattern, pos: pos) else {
            return nil
        }
        try checkMatchSize(result, 1)
        return try checkStringMatch(array: result, index: 0)
    }

    /// Convenience wrapper around `match()` for when the pattern results in exactly two strings.
    ///
    /// As per ``match(string:pattern:pos:)`` except that `pattern` must contain exactly two string captures, and the
    /// result is returned as a tuple rather than an array.
    ///
    /// > Note: Attempting to use a `()` capture will result in `LuaArgumentError` being thrown (if the pattern
    ///   matches). Call ``match(string:pattern:pos:)`` instead to use `()` captures.
    ///
    /// - Throws: ``LuaArgumentError`` if an error was thrown by `match()`, for example because of an invalid pattern
    ///   item in `pattern`, or if `match()` did not return nil or exactly two String results.
    public func matchStrings(string: String, pattern: String, pos: Int = 1) throws -> (String, String)? {
        guard let result = try match(string: string, pattern: pattern, pos: pos) else {
            return nil
        }
        try checkMatchSize(result, 2)
        return (
            try checkStringMatch(array: result, index: 0),
            try checkStringMatch(array: result, index: 1)
        )
    }

    /// Convenience wrapper around `match()` for when the pattern results in exactly three strings.
    ///
    /// As per ``match(string:pattern:pos:)`` except that `pattern` must contain exactly three string captures, and the
    /// result is returned as a tuple rather than an array.
    ///
    /// > Note: Attempting to use a `()` capture will result in `LuaArgumentError` being thrown (if the pattern
    ///   matches). Call ``match(string:pattern:pos:)`` instead to use `()` captures.
    ///
    /// - Throws: ``LuaArgumentError`` if an error was thrown by `match()`, for example because of an invalid pattern
    ///   item in `pattern`, or if `match()` did not return nil or exactly three String results.
    public func matchStrings(string: String, pattern: String, pos: Int = 1) throws -> (String, String, String)? {
        guard let result = try match(string: string, pattern: pattern, pos: pos) else {
            return nil
        }
        try checkMatchSize(result, 3)
        return (
            try checkStringMatch(array: result, index: 0),
            try checkStringMatch(array: result, index: 1),
            try checkStringMatch(array: result, index: 2)
        )
    }

    /// Convenience wrapper around `match()` for when the pattern results in exactly four strings.
    ///
    /// As per ``match(string:pattern:pos:)`` except that `pattern` must contain exactly four string captures, and the
    /// result is returned as a tuple rather than an array.
    ///
    /// > Note: Attempting to use a `()` capture will result in `LuaArgumentError` being thrown (if the pattern
    ///   matches). Call ``match(string:pattern:pos:)`` instead to use `()` captures.
    ///
    /// - Throws: ``LuaArgumentError`` if an error was thrown by `match()`, for example because of an invalid pattern
    ///   item in `pattern`, or if `match()` did not return nil or exactly four String results.
    public func matchStrings(string: String, pattern: String, pos: Int = 1) throws -> (String, String, String, String)? {
        guard let result = try match(string: string, pattern: pattern, pos: pos) else {
            return nil
        }
        try checkMatchSize(result, 4)
        return (
            try checkStringMatch(array: result, index: 0),
            try checkStringMatch(array: result, index: 1),
            try checkStringMatch(array: result, index: 2),
            try checkStringMatch(array: result, index: 3)
        )
    }

    // Top item of stack must be repl
    private func dogsub(string: String, pattern: String, maxReplacements: Int?) throws -> String {
        let t = getglobal("string")
        precondition(t == .table, "String library not opened?")
        rawget(-1, utf8Key: "gsub")
        remove(-2) // string

        push(string)
        push(pattern)
        lua_rotate(self, -4, -1) // Puts repl on top of stack
        push(maxReplacements)

        do {
            try pcall(nargs: 4, nret: 1, traceback: false)
        } catch {
            throw LuaArgumentError(errorString: String(describing: error))
        }
        defer {
            pop(1)
        }
        guard let result = tostring(-1) else {
            throw LuaArgumentError(errorString: "Result of gsub is not decodable using the default String encoding")
        }
        return result
    }

    /// Swift wrapper around `string.gsub()`.
    ///
    /// This helper function allows Lua-style pattern string replacements from Swift. See
    /// [`string.gsub()`](https://www.lua.org/manual/5.4/manual.html#pdf-string.gsub) for details.
    ///
    /// - Parameter string: The string to search in.
    /// - Parameter pattern: The pattern to search for. This can use any of the pattern items described in
    ///   [the Lua manual](https://www.lua.org/manual/5.4/manual.html#6.4.1).
    /// - Parameter repl: What to replace `pattern` with. This string can include `%1` etc patterns as described in the
    ///   `string.gsub()` documentation.
    /// - Parameter maxReplacements: If specified, only replace up to this number of occurrences of `pattern`.
    /// - Returns: A copy of `string` with occurrences of `pattern` replaced by `repl`.
    /// - Throws: ``LuaArgumentError`` if an error was thrown by `string.gsub()`, for example because of an invalid
    ///   pattern item in `pattern`, or if the resulting `string` is not decodable using the default String encoding.
    /// - Precondition: The `string` library must be opened in this LuaState.
    public func gsub(string: String, pattern: String, repl: String, maxReplacements: Int? = nil) throws -> String {
        push(repl)
        return try dogsub(string: string, pattern: pattern, maxReplacements: maxReplacements)
    }

    /// Swift wrapper around `string.gsub()`.
    /// 
    /// This helper function allows Lua-style pattern string replacements from Swift. See
    /// [`string.gsub()`](https://www.lua.org/manual/5.4/manual.html#pdf-string.gsub) for details.
    /// 
    /// - Parameter string: The string to search in.
    /// - Parameter pattern: The pattern to search for. This can use any of the pattern items described in
    ///   [the Lua manual](https://www.lua.org/manual/5.4/manual.html#6.4.1).
    /// - Parameter repl: What to replace `pattern` with. As with `string.gsub()` the first capture is looked up in
    ///   this dictionary and if a value is found, it is used as the replacement string.
    /// - Parameter maxReplacements: If specified, only replace up to this number of occurrences of `pattern`.
    /// - Returns: A copy of `string` with occurrences of `pattern` replaced by `repl`.
    /// - Throws: ``LuaArgumentError`` if an error was thrown by `string.gsub()`, for example because of an invalid
    ///   pattern item in `pattern`, or if the resulting `string` is not decodable using the default String encoding.
    /// - Precondition: The `string` library must be opened in this LuaState.
    public func gsub(string: String, pattern: String, repl: [String: String], maxReplacements: Int? = nil) throws -> String {
        push(repl)
        return try dogsub(string: string, pattern: pattern, maxReplacements: maxReplacements)
    }

    /// Swift wrapper around `string.gsub()`.
    ///
    /// This helper function allows Lua-style pattern string replacements from Swift. See
    /// [`string.gsub()`](https://www.lua.org/manual/5.4/manual.html#pdf-string.gsub) for details.
    ///
    /// - Parameter string: The string to search in.
    /// - Parameter pattern: The pattern to search for. This can use any of the pattern items described in
    ///   [the Lua manual](https://www.lua.org/manual/5.4/manual.html#6.4.1).
    /// - Parameter repl: A closure which returns what to replace the matched pattern with. Will be called once for each
    ///   match, receiving the captures as an array and should return the replacement String, or `nil` to not replace
    ///   that instance.
    /// - Parameter maxReplacements: If specified, only replace up to this number of occurrences of `pattern`.
    /// - Returns: A copy of `string` with occurrences of `pattern` replaced by `repl`.
    /// - Throws: ``LuaArgumentError`` if an error was thrown by `string.gsub()`, for example because of an invalid
    ///   pattern item in `pattern`, or if the resulting `string` is not decodable using the default String encoding.
    /// - Precondition: The `string` library must be opened in this LuaState.
    public func gsub(string: String, pattern: String, repl: ([String]) -> String?, maxReplacements: Int? = nil) throws -> String {
        return try withoutActuallyEscaping(repl) { escapingRepl in
            var replVar = escapingRepl
            let closure: LuaClosure = { L in
                var args: [String] = []
                for i in 1 ... L.gettop() {
                    guard let str = L.tostring(i) else {
                        throw LuaArgumentError(errorString: "Capture \(i) is not decodable using the default String encoding")
                    }
                    args.append(str)
                }
                let result = replVar(args)
                L.push(result)
                return 1
            }
            defer {
                replVar = { _ in return nil }
            }
            push(closure)
            return try dogsub(string: string, pattern: pattern, maxReplacements: maxReplacements)
        }
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
    /// - Parameter path: Path to a Lua text or binary file.
    /// - Parameter displayPath: If set, use this instead of `file` in Lua stacktraces.
    /// - Parameter mode: Whether to only allow text files, compiled binary chunks, or either.
    /// - Throws: [`LuaLoadError.fileError`](doc:Lua/LuaLoadError/fileError(_:)) if `file` cannot be opened.
    ///   [`LuaLoadError.parseError`](doc:Lua/LuaLoadError/parseError(_:)) if the file cannot be parsed.
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
    /// - Throws: [`LuaLoadError.parseError`](doc:Lua/LuaLoadError/parseError(_:)) if the data cannot be parsed.
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
    /// - Throws: [`LuaLoadError.parseError`](doc:Lua/LuaLoadError/parseError(_:)) if the data cannot be parsed.
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
    /// - Throws: [`LuaLoadError.parseError`](doc:Lua/LuaLoadError/parseError(_:)) if the string cannot be parsed.
    public func load(string: String, name: String? = nil) throws {
        try load(data: Array<UInt8>(string.utf8), name: name ?? string, mode: .text)
    }

    /// Load a Lua chunk from file with ``load(file:displayPath:mode:)`` and execute it.
    ///
    /// Any values returned from the file are left on the top of the stack.
    ///
    /// - Parameter path: Path to a Lua text or binary file.
    /// - Parameter mode: Whether to only allow text files, compiled binary chunks, or either.
    /// - Throws: [`LuaLoadError.fileError`](doc:Lua/LuaLoadError/fileError(_:)) if `file` cannot be opened.
    ///   [`LuaLoadError.parseError`](doc:Lua/LuaLoadError/parseError(_:)) if the file cannot be parsed.
    public func dofile(_ path: String, mode: LoadMode = .text) throws {
        try load(file: path, mode: mode)
        try pcall(nargs: 0, nret: LUA_MULTRET)
    }

    /// Load a Lua chunk from a string with ``load(string:name:)`` and execute it.
    ///
    /// Any values returned from the chunk are left on the top of the stack.
    ///
    /// - Parameter string: The Lua script to load.
    /// - Parameter name: The name to give to the resulting chunk. If not specified, the string parameter itself will
    ///   be used as the name.
    /// - Throws: [`LuaLoadError.parseError`](doc:Lua/LuaLoadError/parseError(_:)) if the string cannot be parsed.
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
    /// - Parameter def: If specified, this value is returned if the argument is none or nil. If not specified then
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
