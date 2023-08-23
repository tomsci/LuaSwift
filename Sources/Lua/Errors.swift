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

import Foundation // For LocalizedError

/// An `Error` type representing an error thrown by Lua code.
public struct LuaCallError: Error, Equatable, CustomStringConvertible, LocalizedError {
    init(_ error: LuaValue) {
        self.error = error
        // Construct this now in case the Error is not examined until the after the LuaState has gone out of scope
        // (at which point you'll at least be able to still use the string version)
        self.errorString = error.tostring(convert: true) ?? "<no error description available>"
    }

    /// The underlying Lua error object that was thrown by `lua_error()`. May not necessarily be a string. Note like all
    /// `LuaValue`s, this is only valid until the `LuaState` that created it is closed. After that point, only
    /// `errorString` can be used.
    public let error: LuaValue

    /// The string representation of the Lua error object. Will be set to a generic value if the error object was not
    /// a string or implemented a `__tostring` metafield.
    public let errorString: String

    // Conformance to CustomStringConvertible
    public var description: String { return errorString }

    // Conformance to LocalizedError
    public var errorDescription: String? { return self.description }
}

/// Errors than can be thrown by `LuaState.load()`
public enum LuaLoadError: Error, Equatable {
    case fileNotFound
    case parseError(String)
}

extension LuaLoadError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .fileNotFound: return "LuaLoadError.fileNotFound"
        case .parseError(let err): return "LuaLoadError.parseError(\(err))"
        }
    }
    public var errorDescription: String? { return self.description }
}

/// Errors that can be thrown while using `LuaValue` (in addition to ``Lua/LuaCallError``).
public enum LuaValueError: Error, Equatable {
    /// A call or index was attempted on a `nil` value.
    case nilValue
    /// An index operation was attempted on a value that does not support it.
    case notIndexable
    /// A newindex operation was attempted on a value that does not support it.
    case notNewIndexable
    /// A call operation was attempted on a value that does not support it.
    case notCallable
    /// `len` was called on a Lua value that does not support the length operator.
    case noLength
}

extension LuaValueError: CustomStringConvertible, LocalizedError {
   public var description: String {
       switch self {
       case .nilValue: return "LuaValueError.nilValue"
       case .notIndexable: return "LuaValueError.notIndexable"
       case .notNewIndexable: return "LuaValueError.notNewIndexable"
       case .notCallable: return "LuaValueError.notCallable"
       case .noLength: return "LuaValueError.noLength"
       }
   }
   public var errorDescription: String? { return self.description }
}
