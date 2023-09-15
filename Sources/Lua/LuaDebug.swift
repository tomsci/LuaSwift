// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

import CLua

/// Contains debug information about a function.
///
/// Which members will be non-nil is dependent on what ``WhatInfo`` fields were requested in the call to
/// ``Lua/Swift/UnsafeMutablePointer/getInfo(_:what:)`` or similar. See the individual ``WhatInfo`` enum cases for
/// information about what fields they cause to be set.
///
/// This struct is a Swift-friendly equivalent to [`lua_Debug`](http://www.lua.org/manual/5.4/manual.html#lua_Debug).
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

    public init(from ar: lua_Debug, fields: Set<WhatInfo>, state: LuaState?) {
        if fields.contains(.name) {
            name = ar.name != nil ? String(cString: ar.name) : nil
            namewhat = .init(rawValue: String(cString: ar.namewhat)) ?? .other
        } else {
            name = nil
            namewhat = nil
        }

        if fields.contains(.source) {
            what = .init(rawValue: String(cString: ar.what).lowercased())
            var sourceArray = Array<CChar>(UnsafeBufferPointer(start: ar.source, count: ar.srclen))
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

        if fields.contains(.transfers) {
            ftransfer = Int(ar.ftransfer)
            ntransfer = Int(ar.ntransfer)
        } else {
            ftransfer = nil
            ntransfer = nil
        }

        if let state, fields.contains(.validlines) {
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

        if let state, fields.contains(.function) {
            function = state.popref()
        } else {
            function = nil
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

    /// Get debug information about a function in the call stack.
    ///
    /// - Parameter level: What level of the call stack to get info for. Level 0 is the current running function,
    ///   level 1 is the function that called the current function, etc.
    /// - Parameter what: What information to retrieve.
    /// - Returns: a struct containing the requested information, or `nil` if `level` is larger than the stack is.
    public func getStackInfo(level: CInt, what: Set<LuaDebug.WhatInfo> = .allNonHook) -> LuaDebug? {
        var ar = lua_Debug()
        if lua_getstack(self, level, &ar) == 0 {
            return nil
        }
        lua_getinfo(self, what.rawValue, &ar)
        return LuaDebug(from: ar, fields: what, state: self)
    }

    /// Get debug information about the function on the top of the stack.
    ///
    /// Pops the function from the stack.
    ///
    /// - Parameter what: What information to retrieve.
    /// - Returns: a struct containing the requested information.
    public func getTopFunctionInfo(what: Set<LuaDebug.WhatInfo> = .allNonCall) -> LuaDebug {
        precondition(gettop() > 0 && type(-1) == .function, "Must be a function on top of the stack")
        var ar = lua_Debug()
        lua_getinfo(self, ">" + what.rawValue, &ar)
        return LuaDebug(from: ar, fields: what, state: self)
    }

    /// Get debug information about a function.
    ///
    /// - Parameter ar: must be a valid activation record that was filled by a previous call to
    ///   `lua_getstack` or given as argument to a hook.
    /// - Parameter what: What information to retrieve.
    /// - Returns: a struct containing the requested information.
    public func getInfo(_ ar: inout lua_Debug, what: Set<LuaDebug.WhatInfo>) -> LuaDebug {
        lua_getinfo(self, what.rawValue, &ar)
        return LuaDebug(from: ar, fields: what, state: self)
    }

}
