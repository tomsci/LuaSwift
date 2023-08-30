// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

#if !LUASWIFT_NO_FOUNDATION // canImport(Foundation)

import Foundation
import CLua

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

public extension UnsafeMutablePointer where Pointee == lua_State {
    /// Convert the value at the given stack index into a Swift `String`.
    ///
    /// If the value is is not a Lua string and `convert` is `false`, or if the string data cannot be converted to the
    /// specified encoding, this returns `nil`. If `convert` is true, `nil` will only be returned if the string failed
    /// to parse using `encoding`.
    ///
    /// - Parameter index: The stack index.
    /// - Parameter encoding: The encoding to use to decode the string data, or `nil` to use the default encoding.
    /// - Parameter convert: If true and the value at the given index is not a Lua string, it will be converted to a
    ///   string (invoking `__tostring` metamethods if necessary) before being decoded. If a metamethod errors, returns
    ///   `nil`.
    /// - Returns: the value as a `String`, or `nil` if it could not be converted.
    func tostring(_ index: CInt, encoding: ExtendedStringEncoding? = nil, convert: Bool = false) -> String? {
        let enc = encoding ?? getDefaultStringEncoding()
        if let data = todata(index) {
            return String(data: Data(data), encoding: enc)
        } else if convert {
            let tostringfn: lua_CFunction = { (L: LuaState!) in
                var len: Int = 0
                let ptr = luaL_tolstring(L, 1, &len)
                lua_pushlstring(L, ptr, len)
                return 1
            }
            push(tostringfn)
            lua_pushvalue(self, index)
            do {
                try pcall(nargs: 1, nret: 1)
            } catch {
                return nil
            }
            defer {
                pop()
            }
            return tostring(-1, encoding: encoding, convert: false)
        } else {
            return nil
        }
    }

    func tostring(_ index: CInt, encoding: String.Encoding, convert: Bool = false) -> String? {
        return tostring(index, encoding: .stringEncoding(encoding), convert: convert)
    }

    /// Override the default string encoding.
    ///
    /// See `getDefaultStringEncoding()`. If this function is not called, the default encoding is UTF-8.
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

    func push(string: String, encoding: String.Encoding) {
        push(string: string, encoding: .stringEncoding(encoding))
    }

    /// Push a string onto the stack, using the specified encoding.
    ///
    /// - Parameter string: The `String` to push.
    /// - Parameter encoding: The encoding to use to encode the string data.
    func push(string: String, encoding: ExtendedStringEncoding) {
        guard let data = string.data(using: encoding) else {
            assertionFailure("Cannot represent string in the given encoding?!")
            pushnil()
            return
        }
        push(data)
    }

    /// Push any type conforming to `ContiguousBytes` on to the stack, as a string.
    ///
    /// - Parameter bytes: the data to push
    func push(bytes: ContiguousBytes) {
        bytes.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Void in
            let chars = buf.bindMemory(to: CChar.self)
            lua_pushlstring(self, chars.baseAddress, chars.count)
        }
    }

    /// Load a Lua chunk from memory, without executing it.
    ///
    /// This overload permits any type conforming to Foundation's `ContiguousBytes`. On return, the function
    /// representing the file is left on the top of the stack.
    ///
    /// - Parameter bytes: The data to load.
    /// - Parameter name: The name of the chunk, for use in stacktraces. Optional.
    /// - Parameter mode: Whether to only allow text, compiled binary chunks, or either.
    /// - Throws: `LuaLoadError.parseError` if the data cannot be parsed.
    func load(bytes: ContiguousBytes, name: String?, mode: LoadMode = .text) throws {
        var err: CInt = 0
        bytes.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Void in
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
}

extension Data: Pushable {
    public func push(state L: LuaState) {
        L.push(bytes: self)
    }
}

extension LuaValue {
    public func tostring(encoding: ExtendedStringEncoding? = nil, convert: Bool = false) -> String? {
        push(state: L)
        let result = L.tostring(-1, encoding: encoding, convert: convert)
        L.pop()
        return result
    }

    public func tostring(encoding: String.Encoding, convert: Bool = false) -> String? {
        push(state: L)
        let result = L.tostring(-1,  encoding: encoding, convert: convert)
        L.pop()
        return result
    }
}

#endif
