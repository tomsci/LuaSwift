// Copyright (c) 2023-2025 Tom Sutcliffe
// See LICENSE file for license information.

import CLua

#if !LUASWIFT_NO_FOUNDATION
import Foundation
#endif

/// Contains debug information about a function or stack frame.
///
/// Which members will be non-nil is dependent on what ``WhatInfo`` fields were requested in the call to
/// ``Lua/Swift/UnsafeMutablePointer/getInfo(_:what:)`` or similar. See the individual ``WhatInfo`` enum cases for
/// information about what fields they cause to be set.
///
/// This struct is a Swift-friendly equivalent to [`lua_Debug`](https://www.lua.org/manual/5.4/manual.html#lua_Debug).
/// Unlike `lua_Debug`, `LuaDebug` instances are self-contained and safe to store or pass around.
public struct LuaDebug {
    /// Determines what ``LuaDebug`` fields are filled in when calling
    /// ``Lua/Swift/UnsafeMutablePointer/getInfo(_:what:)`` or similar.
    ///
    /// The following convenience variables are also available: ``Lua/Swift/Set/allNonHook``,
    /// ``Lua/Swift/Set/allNonCall``, ``Lua/Swift/Set/allHook``. For example:
    ///
    /// ```swift
    /// L.getStackInfo(level: 1, what: .allNonHook)
    /// ```
    public enum WhatInfo: String, CaseIterable {
        /// Sets ``LuaDebug/function``.
        case function = "f"

        /// Sets ``LuaDebug/name`` and ``LuaDebug/namewhat``.
        case name = "n"

        /// Sets ``LuaDebug/currentline``.
        case currentline = "l"

        /// Sets ``LuaDebug/source``, ``LuaDebug/short_src``, ``LuaDebug/what``, ``LuaDebug/linedefined``,
        /// ``LuaDebug/lastlinedefined``.
        case source = "S"

        /// Sets ``LuaDebug/validlines``.
        case validlines = "L"

        /// Sets ``LuaDebug/nups``, ``LuaDebug/nparams``, ``LuaDebug/isvararg``.
        case paraminfo = "u"

        /// Sets ``LuaDebug/istailcall``.
        case istailcall = "t"

        /// Sets ``LuaDebug/ftransfer`` and ``LuaDebug/ntransfer``.
        ///
        /// - Note: will be ignored unless Lua 5.4 is being used.
        case transfers = "r"
    }

    public enum NameType: String {
        case global
        case local
        case method
        case field
        case other = ""
    }

    public enum FunctionType: String {
        case lua
        case c
        case main
    }

    /// The name of the function, if known.
    ///
    /// Will be `nil` if `.name` was not specified in the `what` parameter, or if no name could be determined.
    public let name: String?

    /// How the name was determined.
    ///
    /// Will be `nil` if `.name` was not specified in the `what` parameter, or if no name could be determined.
    public let namewhat: NameType?

    /// The type of the function.
    ///
    /// Will be `nil` if `.source` was not specified in the `what` parameter.
    public let what: FunctionType?

    /// The source of the chunk that created the function.
    ///
    /// Will be `nil` if `.source` was not specified in the `what` parameter. If the function was loaded from a binary
    /// chunk that did not supply a `name`, then `source` will be `"=?"` (in Lua 5.4).
    public let source: String?

    /// The line number in the function which is currently being executed.
    ///
    /// Will be `nil` if `.currentline` was not specified in the `what` parameter, if the `LuaDebug` instance was
    /// not created from a function on the call stack, if the function is a C function, or if the function was stripped
    /// of debugging information.
    public let currentline: CInt?

    /// The line number where the definition of the function starts.
    ///
    /// Will be `nil` if `.source`. was not specified in the `what` parameter, or if the function is a C function.
    public let linedefined: CInt?

    /// The line number where the definition of the function ends.
    ///
    /// Will be `nil` if `.source`. was not specified in the `what` parameter, or if the function is a C function.
    public let lastlinedefined: CInt?

    /// The number of upvalues to the function.
    ///
    /// Will be `nil` if `.paraminfo` was not specified in the `what` parameter.
    public let nups: Int?

    /// The number of parameters to the function.
    ///
    /// Will be `nil` if `.paraminfo` was not specified in the `what` parameter. Will always be zero for C functions.
    public let nparams: Int?

    /// Whether the function is variadic.
    ///
    /// Will be `nil` if `.paraminfo` was not specified in the `what` parameter. Will always be `true` for C functions.
    public let isvararg: Bool?

    /// true if this function invocation was called by a tail call.
    ///
    /// Will be `nil` if `.istailcall` was not specified in the `what` parameter.
    public let istailcall: Bool?

    /// The stack index of the first value being transferred by a hook.
    ///
    /// Will be `nil` if `.transfers` was not specified in the `what` parameter, the Lua version being used is older
    /// than 5.4, or if the `LuaDebug` instance was not created from a call or return hook.
    public let ftransfer: Int?

    /// The number of values being transferred.
    ///
    /// See ``ftransfer``. Will be `nil` if `ftransfer` is `nil`.
    public let ntransfer: Int?

    /// A printable version of `source`, for error messages.
    ///
    /// Will be `nil` if `.source` was not specified in the `what` parameter.
    public let short_src: String?

    /// The function itself, as a `LuaValue`.
    ///
    /// Will be `nil` if `.function` was not specified in the `what` parameter.
    public let function: LuaValue?

    /// An array of line numbers which contain code that's part of this function.
    ///
    /// Will be `nil` if `.validlines` was not specified in the `what` parameter, or if the function is a C function.
    /// A function stripped of debugging information currently always results in an empty array.
    public let validlines: [CInt]?

    public init(from ar: lua_Debug, fields: Set<WhatInfo>, state: LuaState) {
        if fields.contains(.name) {
            name = ar.name != nil ? String(cString: ar.name) : nil
            namewhat = .init(rawValue: String(cString: ar.namewhat)) ?? .other
        } else {
            name = nil
            namewhat = nil
        }

        if fields.contains(.source) {
            what = .init(rawValue: String(cString: ar.what).lowercased())
            var srclen: Int = 0
            withUnsafePointer(to: ar) { ptr in
                srclen = luaswift_lua_Debug_srclen(ptr)
            }
            var sourceArray = Array<CChar>(UnsafeBufferPointer(start: ar.source, count: srclen))
            sourceArray.append(0) // Ensure it's null terminated
            source = String(validatingUTF8: sourceArray)
            linedefined = ar.linedefined == -1 ? nil : ar.linedefined
            lastlinedefined = ar.lastlinedefined == -1 ? nil : ar.lastlinedefined
            // Why on earth does Swift bridge char[] to tuple (which is _not_ a Sequence) and not Array??
            short_src = withUnsafeBytes(of: ar.short_src) { rawbuf in
                rawbuf.withMemoryRebound(to: CChar.self) { buf in
                    var arr = Array<CChar>(buf)
                    arr.append(0) // Ensure null terminated
                    return String(validatingUTF8: arr)
                }
            }
        } else {
            what = nil
            source = nil
            linedefined = nil
            lastlinedefined = nil
            short_src = nil
        }

        if fields.contains(.currentline) && ar.currentline != -1 {
            currentline = ar.currentline
        } else {
            currentline = nil
        }

        if fields.contains(.paraminfo) {
            nups = Int(ar.nups)
            nparams = Int(ar.nparams)
            isvararg = ar.isvararg != 0
        } else {
            nups = nil
            nparams = nil
            isvararg = nil
        }

        if fields.contains(.istailcall) {
            istailcall = ar.istailcall != 0
        } else {
            istailcall = nil
        }

        if fields.contains(.transfers) && LUA_VERSION.is54orLater() {
            (ftransfer, ntransfer) = withUnsafePointer(to: ar) { ptr in
                var ftransfer: CUnsignedShort = 0
                var ntransfer: CUnsignedShort = 0
                luaswift_lua_Debug_gettransfers(ptr, &ftransfer, &ntransfer)
                if ftransfer == 0 {
                    return (nil, nil)
                } else {
                    return (Int(ftransfer), Int(ntransfer))
                }
            }
        } else {
            ftransfer = nil
            ntransfer = nil
        }

        if fields.contains(.validlines) {
            var lines: [CInt]? = nil
            if let linesSet: [CInt: Any] = state.tovalue(-1) {
                lines = []
                for (k, _) in linesSet {
                    lines!.append(k)
                }
                lines!.sort()
            }
            validlines = lines
            state.pop()
        } else {
            validlines = nil
        }

        if fields.contains(.function) {
            function = state.popref()
        } else {
            function = nil
        }
    }
}

/// A temporary object used to access information about a Lua stack frame.
///
/// This type permits multiple different ways to access the local variables in the stack frame. The most basic is
/// ``pushLocal(_:)`` which pushes the nth local on to the stack, and also returns the local name. ``findLocal(name:)``
/// searches for a local of the given name and returns its index, suitable for passing to other functions which take an
/// `n` parameter such as ``setLocal(n:value:)``.
///
/// The second access method is to use ``localNames()`` to iterate the variable indexes and names.
///
/// The final option is to use the LuaValue-based ``locals`` property, which behaves similarly to
/// ``Lua/Swift/UnsafeMutablePointer/globals``.
///
/// Objects of this type are only valid during the execution of
/// ``Lua/Swift/UnsafeMutablePointer/withStackFrameFor(level:_:)``. Do not store the value for future use.
public final class LuaStackFrame {
    let L: LuaState
    var ar: UnsafeMutablePointer<lua_Debug>

    init(L: LuaState, ar: UnsafeMutablePointer<lua_Debug>) {
        self.L = L
        self.ar = ar
    }

    /// Pushes the nth local value in this stack frame on to the stack.
    ///
    /// If `n` is larger than the number of locals in scope, then `nil` is returned and nothing is pushed onto
    /// the stack.
    ///
    /// - Parameter n: Which local to return.
    /// - Returns: The name of the value pushed to the stack, or `nil` if `n` is greater than the number of locals in
    ///   scope.
    @discardableResult
    public func pushLocal(_ n: CInt) -> String? {
        if let name = lua_getlocal(L, ar, n) {
            return String(cString: name)
        } else {
            return nil
        }
    }

    /// Return the index of the first local variable matching the given name.
    ///
    /// - Parameter name: The local name to search for.
    /// - Returns: The index of the first local variable matching `name`, or `nil` if no matching local was found.
    public func findLocal(name: String) -> CInt? {
        var i: CInt = 1
        while true {
            let iname = lua_getlocal(L, ar, i)
            guard let iname else {
                return nil
            }
            L.pop()
            if String(cString: iname) == name {
                return i
            } else {
                i = i + 1
            }
        }
    }

    private struct LocalsIterator : Sequence, IteratorProtocol {
        let frame: LuaStackFrame
        var i: CInt
        init(frame: LuaStackFrame) {
            self.frame = frame
            self.i = 0
        }
        public mutating func next() -> (index: CInt, name: String)? {
            i = i + 1
            if let name = frame.pushLocal(i) {
                frame.L.pop()
                return (i, name)
            } else {
                return nil
            }
        }
    }

    /// Returns a sequence of all the valid local variable indexes and names.
    ///
    /// This allows iterating of all the locals in the stack frame, for example:
    /// ```swift
    /// L.withStackFrameFor(level: 1) { frame in
    ///     for (index, name) in frame!.localNames() {
    ///         print("Local \(index) is named \(name)")
    ///     }
    /// }
    /// ```
    ///
    /// Or to return all the valid local names in order as an array of Strings:
    /// ```swift
    /// let names = frame.localNames().map({ $0.name })
    /// ```
    public func localNames() -> some Sequence<(index: CInt, name: String)> {
        return LocalsIterator(frame: self)
    }

    /// Sets the nth local variable to the value on top of the stack.
    ///
    /// > Note: Unlike [`lua_setlocal()`](https://www.lua.org/manual/5.4/manual.html#lua_setlocal), the value is always
    ///   popped from the stack regardless of whether the function succeeds or not.
    ///
    /// - Parameter n: Which local variable to set.
    /// - Returns: `true` if `n` was a valid local variable which was updated, `false` otherwise.
    @discardableResult
    public func setLocal(n: CInt) -> Bool {
        let ret = lua_setlocal(L, ar, n)
        if ret != nil {
            return true
        } else {
            L.pop()
            return false
        }
    }

    /// Sets the nth local variable to the specified value.
    ///
    /// - Parameter n: Which local variable to set.
    /// - Parameter value: The value to assign to the local.
    /// - Returns: `true` if `n` was a valid local variable which was updated, `false` otherwise.
    @discardableResult
    public func setLocal<V: Pushable>(n: CInt, value: V) -> Bool {
        L.push(value)
        return setLocal(n: n)
    }

    /// Get debug information about the stack frame this instance refers to.
    ///
    /// - Parameter what: What information to retrieve.
    /// - Returns: a struct containing the requested information.
    public func getInfo(_ what: Set<LuaDebug.WhatInfo> = .allNonHook) -> LuaDebug {
        lua_getinfo(L, what.rawValue, ar)
        return LuaDebug(from: ar.pointee, fields: what, state: L)
    }

    /// Returns an object representing the local variables as `LuaValues`.
    private(set) lazy public var locals = LuaLocalVariables(frame: self)
}

/// A type representing the local variables defined in a Lua stack frame as `LuaValues`.
///
/// This object can be subscripted by integer index, which which looks up the local for that index, or by String which
/// searches for a local with that name.
///
/// ```swift
/// let val: LuaValue = frame.locals[1] // Same as frame.locals.get(1)?.value ?? LuaValue()
/// frame.locals["foo"] = L.ref(any: "bar")
/// ```
///
/// It can also be iterated:
///
/// ```swift
/// for (index, name, val) in frame.locals {
///     print("Local \(index) is named \(name) and has type \(val.type.tostring())")
/// }
/// ```
///
/// Objects of this type are only valid during the execution of
/// ``Lua/Swift/UnsafeMutablePointer/withStackFrameFor(level:_:)``. Do not store the value for future use.
public struct LuaLocalVariables : Sequence {
    let frame: LuaStackFrame

    /// Returns the name and value of the nth local value in this stack frame.
    ///
    /// See [`debug.getlocal()`](https://www.lua.org/manual/5.4/manual.html#pdf-debug.getlocal) for more information
    /// about local variable indexes.
    ///
    /// - Parameter n: Which local to return.
    /// - Returns: The name and value of the given local, or `nil` if `n` is greater than the number of locals in scope
    ///   in this stack frame.
    public func get(_ n: CInt) -> (name: String, value: LuaValue)? {
        if let name = frame.pushLocal(n) {
            return (name: name, value: frame.L.popref())
        } else {
            return nil
        }
    }

    /// Returns the index and value of the fist local value with the specified name in this stack frame.
    ///
    /// See [`debug.getlocal()`](https://www.lua.org/manual/5.4/manual.html#pdf-debug.getlocal) for more information
    /// about local variable indexes.
    ///
    /// - Parameter name: The name of the local to return.
    /// - Returns: The index and value of the given local, or `nil` if there are no locals with the given name in scope.
    public func get(_ name: String) -> (index: CInt, value: LuaValue)? {
        if let index = frame.findLocal(name: name) {
            frame.pushLocal(index)
            return (index: index, value: frame.L.popref())
        } else {
            return nil
        }
    }

    /// Return the locals as a dictionary of names to LuaValues.
    ///
    /// Note that if there are multiple locals with the same name (such as anonymous temporaries) only the
    /// first one will be present (in order to be consistent with the behaviour of ``LuaStackFrame/findLocal(name:)``).
    public func toDict() -> [String : LuaValue] {
        var result: [String : LuaValue] = [:]
        for (_, name, val) in self {
            if result[name] == nil {
                result[name] = val
            }
        }
        return result
    }

    private struct LocalValuesIterator : IteratorProtocol {
        let frame: LuaStackFrame
        var i: CInt
        init(frame: LuaStackFrame) {
            self.frame = frame
            self.i = 0
        }
        public mutating func next() -> (index: CInt, name: String, value: LuaValue)? {
            i = i + 1
            if let name = frame.pushLocal(i) {
                let value = frame.L.popref()
                return (index: i, name: name, value: value)
            } else {
                return nil
            }
        }
    }

    public func makeIterator() -> some IteratorProtocol<(index: CInt, name: String, value: LuaValue)> {
        return LocalValuesIterator(frame: frame)
    }

    /// Access a local variable by index.
    public subscript(n: CInt) -> LuaValue {
        get {
            return get(n)?.value ?? LuaValue.nilValue
        }
        set {
            frame.setLocal(n: n, value: newValue)
        }
    }

    /// Access a local variable by name.
    public subscript(name: String) -> LuaValue {
        get {
            return get(name)?.value ?? LuaValue.nilValue
        }
        set {
            if let index = frame.findLocal(name: name) {
                frame.setLocal(n: index, value: newValue)
            }
        }
    }
}

extension Set where Element == LuaDebug.WhatInfo {
    public var rawValue: String {
        return self.map({ $0.rawValue }).joined()
    }

    /// Sets all the fields applicable in any use of `LuaDebug`.
    public static var allNonCall: Set<Element> {
        return [.function, .name, .source, .validlines, .paraminfo]
    }

    /// All the fields that can set, except for those only relevant inside hooks.
    public static var allNonHook: Set<Element> {
        return allNonCall.union([.currentline, .istailcall])
    }

    /// All fields that can be set inside hooks.
    public static var allHook: Set<Element> {
        return allNonHook.union([.transfers])
    }
}


/// Helper type used by ``LuaHook`` functions.
///
/// Instances of this class are passed to ``LuaHook`` functions, and contain helper functions only relevant to be called
/// from within hooks. For convenience, `LuaHookContext` also contains a copy of the  `LuaState` and `LuaHookEvent`
/// which triggered the hook.
///
/// Do not store or reuse instances of this class outside of the hook function they were passed in to.
public final class LuaHookContext {
    public let L: LuaState
    /// The type of event which triggered the hook.
    public let event: LuaHookEvent
    /// The line number that triggered the event, if the event is ``LuaHookEvent/line``.
    public let currentline: CInt?
    private var ar: UnsafeMutablePointer<lua_Debug>
    internal var yielded = false

    internal init?(L: LuaState, ar: UnsafeMutablePointer<lua_Debug>) {
        self.L = L
        self.ar = ar
        guard let event = LuaHookEvent(rawValue: ar.pointee.event) else {
            return nil
        }
        self.event = event
        if event == .line {
            self.currentline = ar.pointee.currentline
        } else {
            self.currentline = nil
        }
    }

    /// Get debug information about what was executing when the hook was triggered.
    ///
    /// - Parameter what: What information to retrieve.
    /// - Returns: a struct containing the requested information.
    public func getInfo(_ what: Set<LuaDebug.WhatInfo>) -> LuaDebug {
        lua_getinfo(L, what.rawValue, ar)
        var fields = what
        if event == .line {
            // currentline already valid regardless of what's in what
            fields.insert(.currentline)
        }
        return LuaDebug(from: ar.pointee, fields: fields, state: L)
    }

    /// Yield from a hook.
    ///
    /// Call this function as the last statement in a `LuaHook` function, to yield from the hook. This is the only
    /// permitted way to yield from a hook; it is an error to call
    /// ``Lua/Swift/UnsafeMutablePointer/yield(nresults:continuation:)`` or `lua_yield()`/`lua_yieldk()` from within a
    /// `LuaHook`. As per the `lua_Hook` [documentation](https://www.lua.org/manual/5.4/manual.html#lua_Hook) only
    /// `line` and `count` hooks are permitted to yield.
    ///
    /// - Precondition: The hook event must be [`line`](doc:LuaHookEvent/line) or [`count`](doc:LuaHookEvent/count).
    public func yield() {
        precondition(event == .line || event == .count)
        yielded = true
    }
}

/// Describes what type of event triggered a call to the debugging hook.
///
/// See ``LuaHook``.
public enum LuaHookEvent: CInt {
    /// A function was called.
    case call = 0 // LUA_HOOKCALL
    /// A function was returned from.
    case ret = 1 // LUA_HOOKRET
    /// Called when the interpreter is about to start executing from a new line of code.
    ///
    /// Only called when executing Lua functions.
    case line = 2 // LUA_HOOKLINE
    /// Called after every so many interpreter instructions (as defined by the `count` parameter to `setHook()`).
    case count = 3 // LUA_HOOKCOUNT
    /// A function was tailed called. Tail calls do not have a corresponding `ret` event.
    case tailcall = 4 // LUA_HOOKTAILCALL
}

/// A debugging hook function, suitable for passing to ``Lua/Swift/UnsafeMutablePointer/setHook(mask:count:function:)``.
///
/// `LuaHook` hooks, unlike their C equivalent [`lua_Hook`](https://www.lua.org/manual/5.4/manual.html#lua_Hook), are
/// standard Swift closures and are therefore allowed to capture values, and throw errors. This is similar to how
/// ``LuaClosure`` compares to [`lua_CFunction`](https://www.lua.org/manual/5.4/manual.html#lua_CFunction).
///
/// When the hook function is called, the `LuaState` argument is the state which is being hooked, the ``LuaHookEvent``
/// describes what event triggered the hook, and the ``LuaHookContext`` argument permits more detailed debugging
/// by calling ``LuaHookContext/getInfo(_:)``. For convenience the context also includes a copy of the `LuaState` and
/// `LuaHookEvent` arguments.
///
/// Hooks can get more information about what was executing by calling
/// [`context.getInfo()`](doc:LuaHookContext/getInfo(_:)). In `line` hooks,
/// [`context.currentline`](doc:LuaHookContext/currentline) always contains the line number without needing a call to
/// `getInfo()` to retrieve it.
///
/// `line` and `count` hooks are allowed to yield by calling [`context.yield()`](doc:LuaHookContext/yield()).
///
/// An example `LuaHook` function might look like this:
/// ```swift
/// func myhook(L: LuaState, event: LuaHookEvent, context: LuaHookContext) {
///     if event == .call {
///         let d = context.getInfo([.name])
///         if d.name == "foo" {
///             print("foo() called!")
///         }
///     }
/// }
/// ```
public typealias LuaHook = (LuaState, LuaHookEvent, LuaHookContext) throws -> Void

/// A class which provides thread-safe hooking functions.
public class LuaHooksState {
    private var mainThread: LuaState
    // Note, the LuaState pointers in hooks and untrackedHookedStates are not owned and cannot be assumed to be valid.
    private var hooks = Dictionary<LuaState, LuaHook>()
    private var untrackedHookedStates = Set<LuaState>()
    private var trackedStatesRef = LUA_NOREF
#if !LUASWIFT_NO_FOUNDATION
    private let lock = NSLock()
#endif

    internal init(mainThread: LuaState) {
        self.mainThread = mainThread
    }

    /// Sets the debugging hook function for the given state.
    ///
    /// While this is a wrapper around [`lua_sethook`](https://www.lua.org/manual/5.4/manual.html#lua_sethook), it
    /// varies in several significant ways. Firstly, the function is of type ``LuaHook`` which can error and capture
    /// values, unlike `lua_Hook` -- this is similar to how ``LuaClosure`` behaves compared to `lua_CFunction`.
    /// Secondly, hook functions set by `setHook()` are not inherited by threads (coroutines) created from that state,
    /// unlike when using `lua_sethook` directly -- this restriction is due to the lifetime issues surrounding the
    /// `LuaHook` being able to capture values. The way hook functions are copied into newly created threads does not
    /// allow them to be easily shared in Swift. If a thread is created by a state that has a LuaSwift hook function
    /// set, a warning will be printed the first time it is triggered in the new thread and the hook will be cleared.
    /// To have hooks run in multiple threads, call `setHook` on each thread separately.
    ///
    /// Replaces any previous hook configured by `setHook()` or by calling `lua_sethook()` directly.
    ///
    /// To disable hooking on a `LuaState`, pass `.none` as the mask argument or a `nil` function (or both).
    ///
    /// For example (using the [`LuaState.setHook()`](doc:Lua/Swift/UnsafeMutablePointer/setHook(mask:count:function:))
    /// convenience function):
    ///
    /// ```swift
    /// let hook: LuaHook = { L, event, context in
    ///     if event == .call {
    ///         let d = context.getInfo([.name])
    ///         if d.name == "foo" {
    ///             print("foo() called!")
    ///         }
    ///     }
    /// }
    /// L.setHook(mask: [.call, .ret], function: hook)
    ///
    /// // Could equally be written:
    ///
    /// L.setHook(mask: .call) { L, event, context in
    ///     let d = context.getInfo([.name])
    ///     if d.name == "foo" {
    ///         print("foo() called!")
    ///     }
    /// }
    /// ```
    ///
    /// This function is thread-safe (to the extent that `lua_sethook()` is), and can be called even when the `state` is
    /// executing on another thread, providing there is no possibility that the state might be garbage collected before
    /// the call completes. That being said, `LuaState.setHook()` should be used in preference when possible, to avoid
    /// the following scenario:
    ///
    /// * If a hook is set on a non-main-thread state using `LuaHooksState.setHook()`,
    /// * and the hook is never triggered before the state is garbage collected,
    /// * nor is the hook cleared with `LuaState.setHook()` before that point...
    ///
    /// ...then a small amount of memory will be leaked until the state is closed entirely with `LuaState.close()`. This
    /// leak can be avoided by ensuring any one of the three conditions above are mitigated: for example, by using
    /// `LuaState.setHook()` instead of `LuaHooksState.setHook()`, or by clearing the hook before the state is collected
    /// by calling `state.setHook(mask: .none, function: nil)`.
    ///
    /// - Parameter state: What state to apply the hook to. Must be related to (or the same as) the state on which
    ///   `getHooks()` was called to retrieve this `LuaHooksState` instance.
    /// - Parameter mask: What to hook. Specify `.none` to disable hooking.
    /// - Parameter count: How frequently to call the `count` hook, in interpreter instructions. Ignored unless `mask`
    ///   contains `.count`.
    /// - Parameter function: The hook function to set, or `nil` to disable hooking.
    public func setHook(forState state: LuaState, mask: LuaState.HookMask, count: CInt = 0, function: LuaHook?) {
        precondition(state.getMainThread() == mainThread,
            "Cannot set a hook on a state unrelated to the one this LuaHooksState belongs to")

        if let function, mask.rawValue != 0 {
            locked {
                hooks[state] = function
                untrackedHookedStates.insert(state)
            }
            lua_sethook(state, luaswift_hookfn, mask.rawValue, count)
        } else {
            lua_sethook(state, nil, 0, 0)
            locked {
                hooks[state] = nil
                untrackedHookedStates.remove(state)
            }
        }
    }

    private func locked<Ret>(_ closure: () -> Ret) -> Ret {
#if LUASWIFT_NO_FOUNDATION
        return closure()
#else
        return lock.withLock {
            return closure()
        }
#endif
    }

    /// Gets the debugging hook function for the given state, if one has been set.
    ///
    /// If a debugging hook has been set on this state using ``setHook(forState:mask:count:function:)``, returns that
    /// hook, and `nil` otherwise. This function can be called from any thread.
    public func getHook(forState state: LuaState) -> LuaHook? {
        if !luaswift_hooksequal(lua_gethook(state), luaswift_hookfn) {
            // If this doesn't match then something else must have called lua_sethook() so we should return nil, as
            // whatever we may think is set can't actually be in effect.
            return nil
        }
        return locked {
            return hooks[state]
        }
    }

    internal static let callHook: luaswift_Hook = { (L: LuaState!, ar: UnsafeMutablePointer<lua_Debug>!) in
        guard let hook = L.getHook() else {
            print("Hook called from untracked thread - unregistering hook")
            lua_sethook(L, nil, 0, 0)
            return 0
        }

        guard let context = LuaHookContext(L: L, ar: ar) else {
            print("Unknown hook event \(ar.pointee.event), ignoring!")
            return 0
        }

        do {
            try hook(L, context.event, context)
            if context.yielded {
                return LUASWIFT_CALLCLOSURE_YIELD
            } else {
                return 0
            }
        } catch {
            L.push(error: error)
            return LUASWIFT_CALLCLOSURE_ERROR
        }
    }

    internal func updateStateTracking(_ L: LuaState) {
        var hookSet: Bool! = nil
        var shouldAddToTracker: Bool! = nil
        locked {
            hookSet = hooks[L] != nil
            shouldAddToTracker = untrackedHookedStates.remove(L) != nil && hookSet
        }
        if shouldAddToTracker {
            if trackedStatesRef == LUA_NOREF {
                L.newtable(weakKeys: true) // map of states to StateTrackers, which are GC'd when the state is.
                trackedStatesRef = luaL_ref(L, LUA_REGISTRYINDEX)
            }
            L.rawget(LUA_REGISTRYINDEX, key: trackedStatesRef) // pushes table
            L.rawset(-1, key: L, value: StateTracker(L))
            L.pop() // table
        } else if !hookSet && trackedStatesRef != LUA_NOREF {
            // Remove it from trackedStatesRef, if necessary
            L.rawget(LUA_REGISTRYINDEX, key: trackedStatesRef) // pushes table
            L.rawget(-1, key: L)
            let tracker: StateTracker? = L.touserdata(-1)
            if let tracker {
                // Prevent it erroneously calling stateWasCollected when it is GC'd
                tracker.close()
            }
            L.pop() // tracker
            L.rawset(-1, key: L, value: .nilValue)
            L.pop() // table
        }
    }

    internal func stateWasCollected(runningState: LuaState, collectedState: LuaState) {
        locked {
            hooks[collectedState] = nil
            untrackedHookedStates.remove(collectedState)
        }
    }

    internal class StateTracker: Pushable {
        internal init(_ L: LuaState) {
            trackedState = L
        }
        private var trackedState: LuaState?

        static let gc: lua_CFunction = { (L: LuaState!) in
            guard let ptr: UnsafeMutablePointer<StateTracker> = L.unchecked_touserdata(1) else {
                assertionFailure("Failed to decode StateTracker in gc!")
                return 0
            }
            if let trackedState = ptr.pointee.trackedState {
                L.getState().hooks!.stateWasCollected(runningState: L, collectedState: trackedState)
            }
            ptr.deinitialize(count: 1)
            return 0
        }

        func close() {
            trackedState = nil
        }

        func push(onto L: LuaState) {
            if !L.isMetatableRegistered(for: StateTracker.self) {
                L.register(Metatable<StateTracker>())
                L.pushMetatable(for: StateTracker.self)
                L.push(function: StateTracker.gc)
                L.rawset(-2, utf8Key: "__gc")
                L.pop()
            }
            L.push(userdata: self)
        }
    }

    // Following are for test code only (via Internals.swift)

    internal var _hooks: Dictionary<LuaState, LuaHook> {
        return hooks
    }

    internal var _untrackedHookedStates: Set<LuaState> {
        return untrackedHookedStates
    }

    internal var _trackedStatesRef: CInt {
        return trackedStatesRef
    }

}

extension UnsafeMutablePointer where Pointee == lua_State {

    /// Invokes the given closure with a ``LuaStackFrame`` referring to the given stack level.
    ///
    /// When called with a level greater than the stack depth, `body` is invoked with a `nil` argument.
    ///
    /// Do not store or return the `LuaStackFrame` for later use.
    ///
    /// Usage:
    /// ```swift
    /// L.withStackFrameFor(level: level) { (frame: LuaStackFrame?) in
    ///     /* Use `frame` to query the given level of the stack */
    /// }
    /// ```
    ///
    /// - Parameter level: What level of the call stack to get info for. Level 0 is the current running function,
    ///   level 1 is the function that called the current function, etc.
    /// - Parameter body: The closure to execute.
    /// - Returns: The return value, if any, of the body closure.
    public func withStackFrameFor<Result>(level: CInt, _ body: (LuaStackFrame?) throws -> Result) rethrows -> Result {
        var ar = lua_Debug()
        if lua_getstack(self, level, &ar) == 0 {
            return try body(nil)
        } else {
            let info = LuaStackFrame(L: self, ar: &ar)
            return try body(info)
        }
    }

    /// Get debug information about a function in the call stack.
    ///
    /// Equivalent to:
    /// ```swift
    /// L.withStackFrameFor(level: level) { frame in
    ///     return frame?.getInfo(what)
    /// }
    /// ```
    ///
    /// - Parameter level: What level of the call stack to get info for. Level 0 is the current running function,
    ///   level 1 is the function that called the current function, etc.
    /// - Parameter what: What information to retrieve.
    /// - Returns: a struct containing the requested information, or `nil` if `level` is larger than the stack is.
    public func getStackInfo(level: CInt, what: Set<LuaDebug.WhatInfo> = .allNonHook) -> LuaDebug? {
        return withStackFrameFor(level: level) { frame in
            return frame?.getInfo(what)
        }
    }

    /// Get debug information about the function on the top of the stack.
    ///
    /// Does not pop the function from the stack.
    ///
    /// - Parameter what: What information to retrieve.
    /// - Returns: a struct containing the requested information.
    /// - Precondition: The value on the top of the stack must be a function.
    public func getTopFunctionInfo(what: Set<LuaDebug.WhatInfo> = .allNonCall) -> LuaDebug {
        precondition(gettop() > 0 && type(-1) == .function, "Must be a function on top of the stack")
        var ar = lua_Debug()
        push(index: -1)
        lua_getinfo(self, ">" + what.rawValue, &ar)
        return LuaDebug(from: ar, fields: what, state: self)
    }

    /// Get debug information from an activation record.
    ///
    /// - Parameter ar: must be a valid activation record that was filled by a previous call to
    ///   `lua_getstack` or given as argument to a hook.
    /// - Parameter what: What information to retrieve.
    /// - Returns: a struct containing the requested information.
    public func getInfo(_ ar: inout lua_Debug, what: Set<LuaDebug.WhatInfo>) -> LuaDebug {
        return getInfo(ptr: &ar, what: what)
    }

    /// Get debug information from an activation record.
    ///
    /// - Parameter ptr: must be a valid activation record that was filled by a previous call to
    ///   `lua_getstack` or given as argument to a hook.
    /// - Parameter what: What information to retrieve.
    /// - Returns: a struct containing the requested information.
    public func getInfo(ptr: UnsafeMutablePointer<lua_Debug>, what: Set<LuaDebug.WhatInfo>) -> LuaDebug {
        lua_getinfo(self, what.rawValue, ptr)
        return LuaDebug(from: ptr.pointee, fields: what, state: self)
    }

    /// Wrapper around [`luaL_where()`](https://www.lua.org/manual/5.4/manual.html#luaL_where).
    public func getWhere(level: CInt) -> String {
        luaL_where(self, level)
        defer {
            pop()
        }
        return tostring(-1)!
    }

    /// Get the argument names for the function on top of the stack.
    ///
    /// This will return an empty array if the top value on the stack is not a Lua function, or if the function has
    /// no debug information (eg was loaded from a stripped binary chunk). Therefore, use ``getTopFunctionInfo(what:)``
    /// including ``LuaDebug/WhatInfo/paraminfo`` and check ``LuaDebug/nparams`` if you want the argument count in a
    /// way which works even if the function has been stripped.
    ///
    /// Does not pop the function from the stack.
    public func getTopFunctionArguments() -> [String] {
        precondition(gettop() > 0)
        var i: CInt = 1
        var result: [String] = []
        while true {
            if let name = lua_getlocal(self, nil, i) {
                result.append(String(cString: name))
                i = i + 1
            } else {
                break
            }
        }
        return result
    }

    /// What hooks to enable when calling ``setHook(mask:count:function:)``.
    public struct HookMask: OptionSet {
        public let rawValue: CInt
        public init(rawValue: CInt) {
            self.rawValue = rawValue
        }

        /// Include this to set the call hook, enabling ``LuaHookEvent/call`` and ``LuaHookEvent/tailcall`` events.
        public static let call = HookMask(rawValue: LUA_MASKCALL)
        /// Include this to set the return hook, enabling ``LuaHookEvent/ret`` events.
        public static let ret = HookMask(rawValue: LUA_MASKRET)
        /// Include this to set the line hook, enabling ``LuaHookEvent/line`` events.
        public static let line = HookMask(rawValue: LUA_MASKLINE)
        /// Include this to set the count hook, enabling ``LuaHookEvent/count`` events.
        ///
        /// The `count` parameter to `setHook()` must also be specified.
        public static let count = HookMask(rawValue: LUA_MASKCOUNT)
        /// Specify this to disable all hooks.
        public static let none = HookMask(rawValue: 0)
    }

    /// Sets the debugging hook function for this state.
    ///
    /// This function is equivalent to calling `L.getHooks().setHook(forState: L, ...)`. See
    /// [`LuaHooksState.setHook()`](doc:LuaHooksState/setHook(forState:mask:count:function:)) for more information.
    ///
    /// - Parameter mask: What to hook. Specify `.none` to disable hooking.
    /// - Parameter count: How frequently to call the `count` hook, in interpreter instructions. Ignored unless `mask`
    ///   contains `.count`.
    /// - Parameter function: The hook function to set, or `nil` to disable hooking.
    ///
    /// > Important: Unlike `LuaHooksState.setHook()`, this function is not thread-safe and must not be called from a
    ///   thread other than the one where the LuaState is running. See ``getHooks()`` for a (more) thread-safe
    ///   alternative. 
    public func setHook(mask: HookMask, count: CInt = 0, function: LuaHook?) {
        if let function, mask.rawValue != 0 {
            let hooks = getHooks()
            hooks.setHook(forState: self, mask: mask, count: count, function: function)
            hooks.updateStateTracking(self)
        } else {
            if let hooks = maybeGetState()?.hooks {
                hooks.setHook(forState: self, mask: .none, function: nil)
                hooks.updateStateTracking(self)
            } else {
                // We need to call lua_sethook ourselves since the docs say we replace _any_ previous hook.
                lua_sethook(self, nil, 0, 0)
            }
        }
    }

    /// Gets the debugging hook function for this state, if one has been set.
    ///
    /// This function is functionally equivalent to calling `L.getHooks().getHook(forState: L)`.
    /// If a debugging hook has been set on this state using ``setHook(mask:count:function:)``, returns that hook, and
    /// `nil` otherwise.
    ///
    /// > Important: Unlike `lua_gethook`, this function is not thread-safe and must not be called from a thread other
    ///   than the one where the LuaState is running. See ``getHooks()`` for a (more) thread-safe alternative. 
    public func getHook() -> LuaHook? {
        guard let hooks = maybeGetState()?.hooks else {
            // Can't be a hook set
            return nil
        }
        let result = hooks.getHook(forState: self)
        hooks.updateStateTracking(self)
        return result
    }

    /// Returns an object which supports thread-safe hook functions.
    ///
    /// The `LuaState` ``getHook()`` and ``setHook(mask:count:function:)`` functions are not thread-safe. This function
    /// returns an object which does have thread-safe `getHook()` and `setHook()` functions.
    ///
    /// Note, the `getHooks()` function _itself_ is not thread-safe, and must be called from the thread where the
    /// `LuaState` is running (or be called while the `LuaState` is not executing anything). Only the functions defined
    /// by the `LuaHooksState` class are thread-safe. Therefore to safely use `LuaHooksState.setHook()`, call
    /// `getHooks()` from a safe context and store the resulting `LuaHooksState` for later use from an unsafe context.
    public func getHooks() -> LuaHooksState {
        let state = getState()
        if state.hooks == nil {
            state.hooks = LuaHooksState(mainThread: self.getMainThread())
        }
        return state.hooks!
    }
}
