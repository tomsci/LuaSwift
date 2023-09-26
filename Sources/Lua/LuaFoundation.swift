// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

#if !LUASWIFT_NO_FOUNDATION // canImport(Foundation)

import Foundation
import CLua

/// Represents all the String encodings that this framework can convert strings to and from.
///
/// This enum exists because CoreFoundation contains many encodings not supported by `String.Encoding`.
public enum LuaStringEncoding {
    case stringEncoding(String.Encoding)
    case cfStringEncoding(CFStringEncodings)
}

public extension String {
    init?(data: Data, encoding: LuaStringEncoding) {
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

    func data(using encoding: LuaStringEncoding) -> Data? {
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

extension UnsafeMutablePointer where Pointee == lua_State {
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
    public func tostring(_ index: CInt, encoding: LuaStringEncoding? = nil, convert: Bool = false) -> String? {
        let enc = encoding ?? getDefaultStringEncoding()
        if let data = todata(index) {
            return String(data: Data(data), encoding: enc)
        } else if convert {
            push(function: luaswift_tostring)
            push(index: index)
            do {
                try pcall(nargs: 1, nret: 1)
            } catch {
                return nil
            }
            defer {
                pop()
            }
            return String(data: Data(todata(-1)!), encoding: enc)
        } else {
            return nil
        }
    }

    /// Convert the value at the given stack index into a Swift `String`.
    ///
    /// If the value is is not a Lua string and `convert` is `false`, or if the string data cannot be converted to the
    /// specified encoding, this returns `nil`. If `convert` is true, `nil` will only be returned if the string failed
    /// to parse using `encoding`.
    ///
    /// See also ``tostring(_:encoding:convert:)-9syls`` to use encodings other than `String.Encoding`.
    ///
    /// - Parameter index: The stack index.
    /// - Parameter encoding: The encoding to use to decode the string data.
    /// - Parameter convert: If true and the value at the given index is not a Lua string, it will be converted to a
    ///   string (invoking `__tostring` metamethods if necessary) before being decoded. If a metamethod errors, returns
    ///   `nil`.
    /// - Returns: the value as a `String`, or `nil` if it could not be converted.
    public func tostring(_ index: CInt, encoding: String.Encoding, convert: Bool = false) -> String? {
        return tostring(index, encoding: .stringEncoding(encoding), convert: convert)
    }

    /// Override the default string encoding.
    ///
    /// See ``getDefaultStringEncoding()``. If this function is not called, the default encoding is UTF-8.
    public func setDefaultStringEncoding(_ encoding: LuaStringEncoding) {
        getState().defaultStringEncoding = encoding
    }

    /// Get the default string encoding.
    ///
    /// This is the encoding which Lua strings are assumed to be in if an explicit encoding is not supplied when
    /// converting strings to or from Lua, for example when calling ``tostring(_:encoding:convert:)-9syls`` or ``push(string:)``. By default, it is
    /// assumed all Lua strings are (or should be) UTF-8.
    public func getDefaultStringEncoding() -> LuaStringEncoding {
        return maybeGetState()?.defaultStringEncoding ?? .stringEncoding(.utf8)
    }

    /// Push a string onto the stack, using the specified encoding.
    ///
    /// See also ``push(string:encoding:)-75xks`` to use encodings other than `String.Encoding`.
    ///
    /// - Parameter string: The `String` to push.
    /// - Parameter encoding: The encoding to use to encode the string data.
    public func push(string: String, encoding: String.Encoding) {
        push(string: string, encoding: .stringEncoding(encoding))
    }

    /// Push a string onto the stack, using the specified encoding.
    ///
    /// - Parameter string: The `String` to push.
    /// - Parameter encoding: The encoding to use to encode the string data.
    public func push(string: String, encoding: LuaStringEncoding) {
        guard let data = string.data(using: encoding) else {
            assertionFailure("Cannot represent string in the given encoding?!")
            pushnil()
            return
        }
        push(data)
    }

    /// Push any type conforming to `ContiguousBytes` on to the stack, as a Lua `string`.
    ///
    /// - Parameter bytes: the data to push.
    public func push(bytes: ContiguousBytes) {
        bytes.withUnsafeBytes { buf in
            push(buf)
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
    /// - Throws: ``LuaLoadError/parseError(_:)`` if the data cannot be parsed.
    public func load(bytes: ContiguousBytes, name: String?, mode: LoadMode) throws {
        try bytes.withUnsafeBytes { buf in
            try load(buffer: buf, name: name, mode: mode)
        }
    }
}

extension Data: Pushable {
    public func push(state L: LuaState) {
        L.push(bytes: self)
    }
}

extension NSNumber: Pushable {
    public func push(state L: LuaState) {
        if let int = self as? Int {
            L.push(int)
        } else {
            // Conversion to Double cannot fail
            // Curiously the Swift compiler knows enough to know this won't fail and tells us off for using the `!`
            // in a scenario when it won't fail, but helpfully doesn't provide us with a mechanism to actually get
            // a non-optional Double. The double-parenthesis tells it we know what we're doing.
            L.push((self as! Double))
        }
    }
}

extension LuaValue {
    public func tostring(encoding: LuaStringEncoding? = nil, convert: Bool = false) -> String? {
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

extension LuaCallError: LocalizedError {
    public var errorDescription: String? { return self.description }
}

extension LuaLoadError: LocalizedError {
    public var errorDescription: String? { return self.description }
}

extension LuaValueError: LocalizedError {
   public var errorDescription: String? { return self.description }
}

#endif
