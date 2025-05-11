// Copyright (c) 2023-2025 Tom Sutcliffe
// See LICENSE file for license information.

/// An `Error` type representing a String error thrown by the Lua runtime.
///
/// Unless ``Lua/Swift/UnsafeMutablePointer/setErrorConverter(_:)`` has been called, this will be the error type used
/// by all the `LuaState.pcall()` functions, plus anything which indirectly uses them, such as
/// ``Lua/Swift/UnsafeMutablePointer/get(_:)``.
public struct LuaCallError: Error, Equatable, CustomStringConvertible, Pushable {

    /// Construct a `LuaCallError` with the specified string error.
    public init(_ error: String) {
        self.errorString = error
    }

    /// Pops a value from the stack and constructs a `LuaCallError` from it.
    ///
    /// The `errorString` member is constructed by calling `tostring(-1, convert: true)`. If that returns `nil` (eg due
    /// to a string not being valid in the default encoding, or a `__tostring` metamethod erroring), `errorString` will
    /// be set to `"<invalid value>"`.
    public static func popFromStack(_ L: LuaState) -> LuaCallError {
        defer {
            L.pop()
        }
        if let str = L.tostring(-1, convert: true) {
            return LuaCallError(str)
        } else {
            return LuaCallError("<invalid string>")
        }
    }

    /// Pushes the underlying error string on to the stack.
    public func push(onto L: LuaState) {
        L.push(errorString)
    }

    /// The string representation of the Lua error value.
    public let errorString: String

    // Conformance to CustomStringConvertible
    public var description: String { return errorString }
}

/// A Protocol that enables custom Errors to be thrown from functions like `pcall()`.
///
/// Normally all Lua errors are translated into ``LuaCallError``. Calling
/// ``Lua/Swift/UnsafeMutablePointer/setErrorConverter(_:)`` with an implementation of this protocol allows this
/// behavior to be customized. See ``Lua/Swift/UnsafeMutablePointer/setErrorConverter(_:)`` for more details.
public protocol LuaErrorConverter {
    func popErrorFromStack(_ L: LuaState) -> Error
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
