// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

/// An enumeraton of all the metafield names valid when registering a metatable.
///
/// See ``Lua/Swift/UnsafeMutablePointer/registerMetatable(for:fields:metafields:)``.
public enum MetafieldName: String {
    case add = "__add"
    case sub = "__sub"
    case mul = "__mul"
    case div = "__div"
    case mod = "__mod"
    case pow = "__pow"
    case unm = "__unm"
    case idiv = "__idiv"
    case band = "__band"
    case bor = "__bor"
    case bxor = "__bxor"
    case bnot = "__bnot"
    case shl = "__shl"
    case shr = "__shr"
    case concat = "__concat"
    case len = "__len"
    case eq = "__eq"
    case lt = "__lt"
    case le = "__le"
    case index = "__index"
    case newindex = "__newindex"
    case call = "__call"
    case close = "__close"
    case tostring = "__tostring"
}

public enum MetafieldValue {
    case function(lua_CFunction)
    case closure(LuaClosure)
    case synthesize
}

extension MetafieldValue {
    internal func isSynthesize() -> Bool {
        switch self {
        case .synthesize:
            return true
        default:
            return false
        }
    }
}

internal enum InternalUserdataField {
    case function(lua_CFunction)
    case closure(LuaClosure)
    case property(LuaClosure)
    case rwproperty(LuaClosure, LuaClosure)
}

/// Helper struct used in the registration of metatables.
public struct UserdataField<T> {
    internal let value: InternalUserdataField

    /// Used to define a property field in a metatable.
    ///
    /// For example, given a class like:
    ///
    /// ```swift
    /// class Foo {
    ///     var prop: String?
    /// }
    /// ```
    ///
    /// The `prop` property could be (readonly) exposed to Lua with:
    ///
    /// ```swift
    /// L.registerMetatable(for: Foo.self, fields: [
    ///     "prop": .property { $0.prop }
    /// ])
    /// ```
    ///
    /// To make it so `prop` can be assigned to from Lua, specify both `get:` and `set:` closures:
    ///
    /// ```swift
    /// L.registerMetatable(for: Foo.self, fields: [
    ///     "prop": .property(get: { $0.prop }, set: { $0.prop = $1 })
    /// ])
    /// ```
    ///
    /// See ```Lua/Swift/UnsafeMutablePointer/registerMetatable(for:fields:metafields:)``.
    public static func property<ValType>(get: @escaping (T) -> ValType, set: Optional<(T, ValType) -> Void> = nil) -> UserdataField {
        let getter: LuaClosure = { L in
            let obj: T = try L.checkArgument(1)
            let result = get(obj)
            L.push(any: result)
            return 1
        }

        if let set {
            let setter: LuaClosure = { L in
                let obj: T = try L.checkArgument(1)
                // Arg 2 is the member name in a __newindex call
                let newVal: ValType = try L.checkArgument(3, type: ValType.self) // TODO: handle optional types...
                set(obj, newVal)
                return 0
            }
            return UserdataField(value: .rwproperty(getter, setter))
        } else {
            return UserdataField(value: .property(getter))
        }
    }

    public static func function(_ function: lua_CFunction) -> UserdataField {
        return UserdataField(value: .function(function))
    }

    public static func closure(_ closure: @escaping LuaClosure) -> UserdataField {
        return UserdataField(value: .closure(closure))
    }

    /// Used to define a zero-arguments member function in a metatable.
    ///
    /// For example, given a class like:
    ///
    /// ```swift
    /// class Foo {
    ///     var count = 0
    ///     func inc() {
    ///         count = count + 1
    ///     }
    /// }
    /// ```
    ///
    /// The `inc()` function could be exposed to Lua by using `.memberfunc` with a closure like:
    ///
    /// ```swift
    /// L.registerMetatable(for: Foo.self, fields: [
    ///     "inc": .memberfunc { $0.inc() }
    /// ])
    /// ```
    ///
    /// The Swift closure may return any value (including `Void`) which can be translated using
    /// ``Lua/Swift/UnsafeMutablePointer/push(any:toindex:)``.
    ///
    /// See ```Lua/Swift/UnsafeMutablePointer/registerMetatable(for:fields:metafields:)``.
    public static func memberfn<Ret>(_ accessor: @escaping (T) -> Ret) -> UserdataField {
        return .closure { L in
            let obj: T = try L.checkArgument(1)
            let result = accessor(obj)
            L.push(any: result)
            return 1
        }
    }

    /// Used to define a one-argument member function in a metatable.
    ///
    /// For example, given a class like:
    ///
    /// ```swift
    /// class Foo {
    ///     var count = 0
    ///     func inc(by amount: Int) {
    ///         count = count + amount
    ///     }
    /// }
    /// ```
    ///
    /// The `inc()` function could be exposed to Lua by using `.memberfunc` with a closure like:
    ///
    /// ```swift
    /// L.registerMetatable(for: Foo.self, fields: [
    ///     "inc": .memberfunc { $0.inc(by: $1) }
    /// ])
    /// ```
    ///
    /// The Swift closure may return any value (including `Void`) which can be translated using
    /// ``Lua/Swift/UnsafeMutablePointer/push(any:toindex:)``. Any argument type which can be converted from Lua using
    /// ``Lua/Swift/UnsafeMutablePointer/tovalue(_:)`` (including optionals) can be used.
    ///
    /// See ```Lua/Swift/UnsafeMutablePointer/registerMetatable(for:fields:metafields:)``.
    public static func memberfn<Arg1, Ret>(_ accessor: @escaping (T, Arg1) -> Ret) -> UserdataField {
        return .closure { L in
            let obj: T = try L.checkArgument(1)
            let arg1: Arg1 = try L.checkArgument(2)
            let result = accessor(obj, arg1)
            L.push(any: result)
            return 1
        }
    }

    /// Used to define a two-argument member function in a metatable.
    ///
    /// The Swift closure may return any value (including `Void`) which can be translated using
    /// ``Lua/Swift/UnsafeMutablePointer/push(any:toindex:)``. Any argument type which can be converted from Lua using
    /// ``Lua/Swift/UnsafeMutablePointer/tovalue(_:)`` (including optionals) can be used.
    ///
    /// See ```Lua/Swift/UnsafeMutablePointer/registerMetatable(for:fields:metafields:)``.
    public static func memberfn<Arg1, Arg2, Ret>(_ accessor: @escaping (T, Arg1, Arg2) -> Ret) -> UserdataField {
        return .closure { L in
            let obj: T = try L.checkArgument(1)
            let arg1: Arg1 = try L.checkArgument(2)
            let arg2: Arg2 = try L.checkArgument(3)
            let result = accessor(obj, arg1, arg2)
            L.push(any: result)
            return 1
        }
    }

    public static func memberfn<Arg1, Arg2, Arg3, Ret>(_ accessor: @escaping (T, Arg1, Arg2, Arg3) -> Ret) -> UserdataField {
        return .closure { L in
            let obj: T = try L.checkArgument(1)
            let arg1: Arg1 = try L.checkArgument(2)
            let arg2: Arg2 = try L.checkArgument(3)
            let arg3: Arg3 = try L.checkArgument(4)
            let result = accessor(obj, arg1, arg2, arg3)
            L.push(any: result)
            return 1
        }
    }

    public static func staticfn<Ret>(_ accessor: @escaping () -> Ret) -> UserdataField {
        return .closure { L in
            let result = accessor()
            L.push(any: result)
            return 1
        }
    }

    public static func staticfn<Arg1, Ret>(_ accessor: @escaping (Arg1) -> Ret) -> UserdataField {
        return .closure { L in
            let arg1: Arg1 = try L.checkArgument(1)
            let result = accessor(arg1)
            L.push(any: result)
            return 1
        }
    }

    public static func staticfn<Arg1, Arg2, Ret>(_ accessor: @escaping (Arg1, Arg2) -> Ret) -> UserdataField {
        return .closure { L in
            let arg1: Arg1 = try L.checkArgument(1)
            let arg2: Arg2 = try L.checkArgument(2)
            let result = accessor(arg1, arg2)
            L.push(any: result)
            return 1
        }
    }

    public static func staticfn<Arg1, Arg2, Arg3, Ret>(_ accessor: @escaping (Arg1, Arg2, Arg3) -> Ret) -> UserdataField {
        return .closure { L in
            let arg1: Arg1 = try L.checkArgument(1)
            let arg2: Arg2 = try L.checkArgument(2)
            let arg3: Arg3 = try L.checkArgument(3)
            let result = accessor(arg1, arg2, arg3)
            L.push(any: result)
            return 1
        }
    }

}
