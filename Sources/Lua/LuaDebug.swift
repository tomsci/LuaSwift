// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

import CLua

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

    public let name: String?
    public let namewhat: NameType?
    public let what: FunctionType?
    public let source: String?
    public let currentline: CInt?
    public let linedefined: CInt?
    public let lastlinedefined: CInt?
    public let nups: Int?
    public let nparams: Int?
    public let isvararg: Bool?
    public let istailcall: Bool?
    public let ftransfer: Int?
    public let ntransfer: Int?
    public let short_src: String?
    public let function: LuaValue?
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
            linedefined = ar.linedefined
            lastlinedefined = ar.lastlinedefined
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

        if fields.contains(.currentline) {
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
                return (Int(ftransfer), Int(ntransfer))
            }
        } else {
            ftransfer = nil
            ntransfer = nil
        }

        if fields.contains(.validlines) {
            var lines: [CInt] = []
            if let linesSet: [CInt: Any] = state.tovalue(-1) {
                for (k, _) in linesSet {
                    lines.append(k)
                }
            }
            lines.sort()
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
/// ``pushLocal(_:)`` which pushes the nth local onto the stack, and also returns the local name. ``findLocal(name:)``
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
public class LuaStackFrame {
    let L: LuaState
    var ar: lua_Debug

    init(L: LuaState, ar: lua_Debug) {
        self.L = L
        self.ar = ar
    }

    /// Pushes the nth local value in this stack frame onto the stack.
    ///
    /// If `n` is larger than the number of locals in scope, then `nil` is returned and nothing is pushed onto
    /// the stack.
    ///
    /// - Parameter n: Which local to return.
    /// - Returns: The name of the value pushed to the stack, or `nil` if `n` is greater than the number of locals in
    ///   scope.
    @discardableResult
    public func pushLocal(_ n: CInt) -> String? {
        let name = withUnsafePointer(to: ar) { arPtr in
            return lua_getlocal(L, arPtr, n)
        }
        if let name {
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
        return withUnsafePointer(to: ar) { arPtr -> CInt? in
            var i: CInt = 1
            while true {
                let iname = lua_getlocal(L, arPtr, i)
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
        let ret = withUnsafePointer(to: ar) { arPtr in
            return lua_setlocal(L, arPtr, n)
        }
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
        let ret = withUnsafePointer(to: ar) { arPtr in
            return lua_setlocal(L, arPtr, n)
        }
        if ret != nil {
            return true
        } else {
            L.pop()
            return false
        }
    }

    /// Get debug information about the stack frame this instance refers to.
    ///
    /// - Parameter what: What information to retrieve.
    /// - Returns: a struct containing the requested information.
    public func getInfo(_ what: Set<LuaDebug.WhatInfo> = .allNonHook) -> LuaDebug {
        var ar = self.ar
        lua_getinfo(L, what.rawValue, &ar)
        return LuaDebug(from: ar, fields: what, state: L)
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
            let info = LuaStackFrame(L: self, ar: ar)
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
        lua_getinfo(self, what.rawValue, &ar)
        return LuaDebug(from: ar, fields: what, state: self)
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

}
