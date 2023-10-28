// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

/// An `Error` type representing an error thrown by Lua code.
public struct LuaCallError: Error, Equatable, CustomStringConvertible, Pushable {
    private init(_ error: LuaValue) {
        self.errorValue = error
        // Construct this now in case the Error is not examined until the after the LuaState has gone out of scope
        // (at which point you'll at least be able to still use the string version)
        self.errorString = error.tostring(convert: true) ?? "<no error description available>"
    }

    /// Construct a `LuaCallError` with a string error. `errorValue` will be nil.
    public init(_ error: String) {
        self.errorValue = nil
        self.errorString = error
    }

    /// Pops a value from the stack and constructs a `LuaCallError` from it.
    public static func popFromStack(_ L: LuaState) -> LuaCallError {
        defer {
            L.pop()
        }
        if L.type(-1) == .string {
            return LuaCallError(L.tostring(-1)!)
        } else {
            return LuaCallError(L.ref(index: -1))
        }
    }

    public func push(onto L: LuaState) {
        if let errorValue {
            L.push(errorValue)
        } else {
            L.push(errorString)
        }
    }

    /// The underlying Lua error object that was thrown by `lua_error()`, if the object thrown was something other than
    /// a string. For string errors, `errorValue` will be nil. Note like all `LuaValue`s, this is only valid until the
    /// `LuaState` that created it is closed. After that point, only `errorString` can be used.
    public let errorValue: LuaValue?

    /// The string representation of the Lua error object. If the thrown error object was a string, this is that object
    /// as a Swift String. Otherwise, `errorString` will be set from the result of `tostring(errorValue)`.
    public let errorString: String

    // Conformance to CustomStringConvertible
    public var description: String { return errorString }
}

/// Errors than can be thrown by ``Lua/Swift/UnsafeMutablePointer/load(file:displayPath:mode:)`` (and other overloads).
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

extension LuaLoadError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .fileError(let err): return "LuaLoadError.fileError(\(err))"
        case .parseError(let err): return "LuaLoadError.parseError(\(err))"
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
