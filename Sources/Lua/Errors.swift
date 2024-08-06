// Copyright (c) 2023-2024 Tom Sutcliffe
// See LICENSE file for license information.

/// An `Error` type representing an error thrown by the Lua runtime.
public struct LuaCallError: Error, Equatable, CustomStringConvertible, Pushable {
    private init(_ error: LuaValue) {
        self.errorValue = error
        // Construct this now in case the Error is not examined until the after the LuaState has gone out of scope
        // (at which point you'll at least be able to still use the string version)
        self.errorString = error.tostring(convert: true) ?? "<no error description available>"
    }

    /// Construct a `LuaCallError` with a string error. `errorValue` will be `nil`.
    public init(_ error: String) {
        self.errorValue = nil
        self.errorString = error
    }

    /// Pops a value from the stack and constructs a `LuaCallError` from it.
    ///
    /// If the value is a string decodable using the default string encoding, `errorString` in the resulting
    /// `LuaCallError` will be set to that string and `errorValue` will be nil. Otherwise, the value will be stored
    /// in `errorValue` and `errorString` will be set to the result of calling `tostring()` on the value.
    public static func popFromStack(_ L: LuaState) -> LuaCallError {
        defer {
            L.pop()
        }
        if let str = L.tostring(-1) {
            return LuaCallError(str)
        } else {
            return LuaCallError(L.ref(index: -1))
        }
    }

    /// Pushes the underlying error object (or string) on to the stack.
    public func push(onto L: LuaState) {
        if let errorValue {
            L.push(errorValue)
        } else {
            L.push(errorString)
        }
    }

    /// The underlying Lua error value that was thrown by `lua_error()`.
    ///
    /// If the underlying Lua error was not a `string`, errorValue will be set to that value. If the error was a string
    /// that could be decoded using the default string encoding, then `errorValue` will be `nil`. 

    /// > Important: Like all `LuaValue` objects, this is only valid until the `LuaState` that created it is closed.
    ///   After that point, only `errorString` can be used.
    public let errorValue: LuaValue?

    /// The string representation of the Lua error value.
    ///
    /// If the thrown error value was a `string` decodable using the default string encoding, this is that object as a
    /// Swift `String`. Otherwise, `errorString` will be set to the result of `tostring(errorValue)`.
    public let errorString: String

    // Conformance to CustomStringConvertible
    public var description: String { return errorString }
}

/// Errors than can be thrown by ``Lua/Swift/UnsafeMutablePointer/load(file:displayPath:mode:)`` (and other overloads).
///
/// This type's implementation of `Pushable` pushes the underlying error string.
public enum LuaLoadError: Error, Equatable {
    /// An error indicating that the specified file could not be found or opened.
    ///
    /// The associated value is the error string returned from the open operation.
    case fileError(String)
    /// An error indicating that invalid Lua syntax was encountered during parsing.
    ///
    /// The associated value is the error string returned from the Lua compiler.
    case parseError(String)
}

extension LuaLoadError: CustomStringConvertible, Pushable {
    public var description: String {
        switch self {
        case .fileError(let err): return "LuaLoadError.fileError(\(err))"
        case .parseError(let err): return "LuaLoadError.parseError(\(err))"
        }
    }

    public func push(onto L: LuaState) {
        switch self {
        case .fileError(let err):
            L.push(err)
        case .parseError(let err):
            L.push(err)
        }
    }
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
    /// A `pairs` operation was attempted on a value that does not support it.
    case notIterable
    /// `len` was called on a Lua value that does not support the length operator.
    case noLength
}

extension LuaValueError: CustomStringConvertible {
   public var description: String {
       switch self {
       case .nilValue: return "LuaValueError.nilValue"
       case .notIndexable: return "LuaValueError.notIndexable"
       case .notNewIndexable: return "LuaValueError.notNewIndexable"
       case .notCallable: return "LuaValueError.notCallable"
       case .notIterable: return "LuaValueError.notIterable"
       case .noLength: return "LuaValueError.noLength"
       }
   }
}

/// Error thrown from `match` and `gsub` wrapper functions.
///
/// Indicates that the function arguments were not valid. For example, would be
/// thrown by ``Lua/Swift/UnsafeMutablePointer/matchStrings(string:pattern:pos:)-5g0g4`` (which expects two String
/// results) if `pattern` contained only one capture.
///
public struct LuaArgumentError : Error, Equatable, CustomStringConvertible {
    public init(errorString: String) {
        self.errorString = errorString
    }

    public let errorString: String

    public var description: String { return errorString }
}
