// Copyright (c) 2025 Tom Sutcliffe
// See LICENSE file for license information.

import CLua

// Documented in Metaobject.md
public struct Metaobject<T>: Pushable {
    internal let extraFields: [String : StaticFieldType]?
    internal let constructor: InternalMetafieldValue?
    internal let metatableStatics: [String : InternalUserdataField]?

    /// Helper class that defines all the ways to implement a field in a metaobject.
    public struct StaticFieldType {
        internal let value: InternalUserdataField

        public static var none: Self { Self(value: .novalue) }

        public static func constant<ValType>(_ value: ValType) -> Self {
            let getter: PusherFn = { L in
                L.push(any: value)
            }
            return Self(value: .constant(getter))
        }

        public static func staticvar<ValType>(_ get: @escaping () -> ValType) -> Self {
            let getter: PusherFn = { L in
                let result = get()
                L.push(any: result)
            }
            return Self(value: .staticvar(getter))
        }

        public static func function(_ function: lua_CFunction) -> Self {
            return Self(value: .function(function))
        }

        public static func closure(_ closure: @escaping LuaClosure) -> Self {
            return Self(value: .closure(closure))
        }

        public static func staticfn<Ret>(_ accessor: @escaping () throws -> Ret) -> Self {
            return Self(value: .closure(LuaState.makeClosure(accessor)))
        }

        public static func staticfn<Arg1, Ret>(_ accessor: @escaping (Arg1) throws -> Ret) -> Self {
            return Self(value: .closure(LuaState.makeClosure(accessor)))
        }

        public static func staticfn<Arg1, Arg2, Ret>(_ accessor: @escaping (Arg1, Arg2) throws -> Ret) -> Self {
            return Self(value: .closure(LuaState.makeClosure(accessor)))
        }

        public static func staticfn<Arg1, Arg2, Arg3, Ret>(_ accessor: @escaping (Arg1, Arg2, Arg3) throws -> Ret) -> Self {
            return Self(value: .closure(LuaState.makeClosure(accessor)))
        }

        public static func staticfn<Arg1, Arg2, Arg3, Arg4, Ret>(_ accessor: @escaping (Arg1, Arg2, Arg3, Arg4) throws -> Ret) -> Self {
            return Self(value: .closure(LuaState.makeClosure(accessor)))
        }
    }

    /// Creates a Metaobject without specifying a constructor.
    ///
    /// - Parameter metatable: The `Metatable` for this type. Can be nil if `T` will always have been registered prior
    ///   to the metaobject being pushed.
    /// - Parameter fields: Any extra fields to add to the metaobject, in addition to the static fields from the
    ///   metatable.
    ///
    /// This is an overloaded initializer, with variants using differently-typed `constructor` parameters. Use this
    /// variant if the type object should not have a constructor -- for example because there are static factory
    /// functions defined in `fields` instead.
    ///
    /// Note that if the `metatable` parameter is omitted and `T` conforms to `PushableWithMetatable`, the
    /// ``init(fields:)`` overload will be automatically used instead.
    public init(metatable: Metatable<T>? = nil, fields: [String : StaticFieldType]? = nil) {
        self.extraFields = fields
        self.constructor = nil
        self.metatableStatics = metatable?.statics
    }

    /// Creates a Metaobject specifying a LuaClosure constructor.
    ///
    /// - Parameter metatable: The `Metatable` for this type. Can be nil if `T` will always have been registered prior
    ///   to the metaobject being pushed.
    /// - Parameter fields: Any extra fields to add to the metaobject, in addition to the static fields from the
    ///   metatable.
    /// - Parameter constructor: The closure to use as the resulting value's `call` metamethod (ie when Lua code calls
    ///   `Metaobj(...)`. Note that any arguments to the closure start at index 2, due to the metaobject being at index
    ///   one. The closure should push a `T` instance on to the stack returning exactly one result.
    ///
    /// This is an overloaded initializer, with variants using differently-typed `constructor` parameters. This variant
    /// is the most flexible, and allows for custom argument parsing - for example supporting arguments that can be of
    /// multiple different types, effectively allowing an overloaded constructor.
    ///
    /// Note that if the `metatable` parameter is omitted and `T` conforms to `PushableWithMetatable`, the
    /// ``init(fields:constructor:)-97c5d`` overload will be automatically used instead.
    public init(metatable: Metatable<T>? = nil, fields: [String : StaticFieldType]? = nil, constructor: @escaping LuaClosure) {
        self.extraFields = fields
        self.constructor = .closure(constructor)
        self.metatableStatics = metatable?.statics
    }

    /// Creates a Metaobject with a constructor that takes no arguments.
    ///
    /// - Parameter metatable: The `Metatable` for this type. Can be nil if `T` will always have been registered prior
    ///   to the metaobject being pushed.
    /// - Parameter fields: Any extra fields to add to the metaobject, in addition to the static fields from the
    ///   metatable.
    /// - Parameter constructor: The closure to use as the resulting value's constructor.
    ///
    /// This is an overloaded initializer, with variants using differently-typed `constructor` parameters. This variant
    /// should be used when the type `T` needs no arguments to be constructed.
    ///
    /// Note that if the `metatable` parameter is omitted and `T` conforms to `PushableWithMetatable`, the
    /// ``init(fields:constructor:)-4pzsb`` overload will be automatically used instead.
    public init(metatable: Metatable<T>? = nil, fields: [String : StaticFieldType]? = nil, constructor: @escaping () -> T) {
        self.extraFields = fields
        self.constructor = .closure(LuaState.makeClosure(constructor))
        self.metatableStatics = metatable?.statics
    }

    /// Creates a Metaobject with a constructor that takes one argument.
    ///
    /// - Parameter metatable: The `Metatable` for this type. Can be nil if `T` will always have been registered prior
    ///   to the metaobject being pushed.
    /// - Parameter fields: Any extra fields to add to the metaobject, in addition to the static fields from the
    ///   metatable.
    /// - Parameter constructor: The closure to use as the resulting value's constructor.
    ///
    /// This is an overloaded initializer, with variants using differently-typed `constructor` parameters. This variant
    /// should be used when the type `T` needs no arguments to be constructed.
    ///
    /// Note that if the `metatable` parameter is omitted and `T` conforms to `PushableWithMetatable`, the
    /// ``init(fields:constructor:)-488t3`` overload will be automatically used instead.
    public init<Arg1>(metatable: Metatable<T>? = nil, fields: [String : StaticFieldType]? = nil, constructor: @escaping (Arg1) -> T) {
        self.extraFields = fields
        self.constructor = .closure(LuaState.makeClosure(startingIndex: 2, constructor))
        self.metatableStatics = metatable?.statics
    }

    /// Creates a Metaobject with a constructor that takes two arguments.
    ///
    /// - Parameter metatable: The `Metatable` for this type. Can be nil if `T` will always have been registered prior
    ///   to the metaobject being pushed.
    /// - Parameter fields: Any extra fields to add to the metaobject, in addition to the static fields from the
    ///   metatable.
    /// - Parameter constructor: The closure to use as the resulting value's constructor.
    ///
    /// This is an overloaded initializer, with variants using differently-typed `constructor` parameters. This variant
    /// should be used when the type `T` constructor takes two arguments.
    ///
    /// Note that if the `metatable` parameter is omitted and `T` conforms to `PushableWithMetatable`, the
    /// ``init(fields:constructor:)-256nw`` overload will be automatically used instead.
    public init<Arg1, Arg2>(metatable: Metatable<T>? = nil, fields: [String : StaticFieldType]? = nil, constructor: @escaping (Arg1, Arg2) -> T) {
        self.extraFields = fields
        self.constructor = .closure(LuaState.makeClosure(startingIndex: 2, constructor))
        self.metatableStatics = metatable?.statics
    }

    /// Creates a Metaobject with a constructor that takes three arguments.
    ///
    /// - Parameter metatable: The `Metatable` for this type. Can be nil if `T` will always have been registered prior
    ///   to the metaobject being pushed.
    /// - Parameter fields: Any extra fields to add to the metaobject, in addition to the static fields from the
    ///   metatable.
    /// - Parameter constructor: The closure to use as the resulting value's constructor.
    ///
    /// This is an overloaded initializer, with variants using differently-typed `constructor` parameters. This variant
    /// should be used when the type `T` constructor takes three arguments.
    ///
    /// Note that if the `metatable` parameter is omitted and `T` conforms to `PushableWithMetatable`, the
    /// ``init(fields:constructor:)-458i6`` overload will be automatically used instead.
    public init<Arg1, Arg2, Arg3>(metatable: Metatable<T>? = nil, fields: [String : StaticFieldType]? = nil, constructor: @escaping (Arg1, Arg2, Arg3) -> T) {
        self.extraFields = fields
        self.constructor = .closure(LuaState.makeClosure(startingIndex: 2, constructor))
        self.metatableStatics = metatable?.statics
    }

    /// Creates a Metaobject with a constructor that takes four arguments.
    ///
    /// - Parameter metatable: The `Metatable` for this type. Can be nil if `T` will always have been registered prior
    ///   to the metaobject being pushed.
    /// - Parameter fields: Any extra fields to add to the metaobject, in addition to the static fields from the
    ///   metatable.
    /// - Parameter constructor: The closure to use as the resulting value's constructor.
    ///
    /// This is an overloaded initializer, with variants using differently-typed `constructor` parameters. This variant
    /// should be used when the type `T` constructor takes four arguments.
    ///
    /// Note that if the `metatable` parameter is omitted and `T` conforms to `PushableWithMetatable`, the
    /// ``init(fields:constructor:)-3b953`` overload will be automatically used instead.
    public init<Arg1, Arg2, Arg3, Arg4>(metatable: Metatable<T>? = nil, fields: [String : StaticFieldType]? = nil, constructor: @escaping (Arg1, Arg2, Arg3, Arg4) -> T) {
        self.extraFields = fields
        self.constructor = .closure(LuaState.makeClosure(startingIndex: 2, constructor))
        self.metatableStatics = metatable?.statics
    }

    public func push(onto L: LuaState) {
        let statics: [String : InternalUserdataField]
        if let mtstatics = self.metatableStatics {
            statics = mtstatics
        } else {
            precondition(L.isMetatableRegistered(for: T.self),
                "When metatable argument to Metaobject constructor is nil, metatable must be registered before calling push")
            L.pushMetatable(for: T.self)
            guard let mtPtr = lua_topointer(L, -1),
                  let umt = L.getState().userdataMetatables[mtPtr] else {
                fatalError("Couldn't find untyped metatable for type \(T.self))")
            }
            statics = umt.statics
            L.pop() // mt
        }

        var mtfields: [String : Metatable<T>.FieldType] = [:]
        if let extraFields {
            for (name, field) in extraFields {
                mtfields[name] = .init(value: field.value)
            }
        }

        for (name, field) in statics {
            // Make sure that extraFields takes precedence
            if mtfields[name] == nil {
                mtfields[name] = .init(value: field)
            }
        }

        let callfn: Metatable<T>.CallType?
        if let constructor {
            callfn = .init(value: constructor)
        } else {
            callfn = nil
        }

        let mt = Metatable(fields: mtfields, call: callfn)
        // We don't actually register this Metatable, we're just using its logic for synthesizing index metamethods for
        // properties and suchlike.

        L.newtable() // the var
        L.newtable() // the metatable for it
        for (name, fn) in mt.mt {
            if case .memberClosure(let closure) = fn, name == .index {
                // None of the things being synthesized actually need the memberClosure mtPtr so we can pass in any old
                // value here - use L again as it's conveniently available.
                let fakeMtPtr = L
                L.push({ L in
                    return try closure(L, fakeMtPtr)
                })
                L.rawset(-2, utf8Key: name.rawValue)
                continue
            }

            switch fn {
            case .function(let fn):
                L.push(function: fn)
            case .closure(let closure):
                L.push(closure)
            default:
                fatalError("Unhandled Metaobject mt type for \(name.rawValue)")
            }
            L.rawset(-2, utf8Key: name.rawValue)
        }
        lua_setmetatable(L, -2)

        if let fields = mt.unsynthesizedFields {
            for (name, field) in fields {
                switch field {
                case .function(let function):
                    L.push(function: function)
                case .closure(let closure):
                    L.push(closure)
                case .constant(let getter):
                    getter(L)
                case .staticvar(let getter):
                    getter(L)
                case .staticfn(let closure):
                    L.push(closure)
                case .memberClosure(_), .property(_), .rwproperty(_, _):
                    fatalError() // By definition cannot hit this
                case .novalue:
                    L.pushnil()
                }
                L.rawset(-2, utf8Key: name)
            }
        }
    }
}

extension Metaobject where T: PushableWithMetatable, T.ValueType == T {

    /// Creates a Metaobject for a PushableWithMetatable type without specifying a constructor.
    ///
    /// - Parameter fields: Any extra fields to add to the metaobject, in addition to the static fields from the
    ///   metatable.
    ///
    /// This is an overloaded initializer, with variants using differently-typed `constructor` parameters. Use this
    /// variant if the type object should not have a constructor -- for example because there are static factory
    /// functions defined in `fields` instead.
    ///
    /// Note that this overload will automatically be used instead of ``init(metatable:fields:)`` if the `metatable`
    /// parameter is omitted and `T` conforms to `PushableWithMetatable`.
    public init(fields: [String : StaticFieldType]? = nil) {
        self.init(metatable: T.metatable, fields: fields)
    }

    /// Creates a Metaobject for a PushableWithMetatable type specifying a LuaClosure constructor.
    ///
    /// - Parameter fields: Any extra fields to add to the metaobject, in addition to the static fields from the
    ///   metatable.
    /// - Parameter constructor: The closure to use as the resulting value's `call` metamethod (ie when Lua code calls
    ///   `Metaobj(...)`. Note that any arguments to the closure start at index 2, due to the metaobject being at index
    ///   one. The closure should push a `T` instance on to the stack returning exactly one result.
    ///
    /// This is an overloaded initializer, with variants using differently-typed `constructor` parameters. This variant
    /// is the most flexible, and allows for custom argument parsing - for example supporting arguments that can be of
    /// multiple different types, effectively allowing an overloaded constructor.
    ///
    /// Note that this overload will automatically be used instead of ``init(metatable:fields:constructor:)-379zf`` if
    /// the `metatable` parameter is omitted and `T` conforms to `PushableWithMetatable`.
    public init(fields: [String : StaticFieldType]? = nil, constructor: @escaping LuaClosure) {
        self.init(metatable: T.metatable, fields: fields, constructor: constructor)
    }

    /// Creates a Metaobject for a PushableWithMetatable type with a constructor that takes no arguments.
    ///
    /// - Parameter fields: Any extra fields to add to the metaobject, in addition to the static fields from the
    ///   metatable.
    /// - Parameter constructor: The closure to use as the resulting value's constructor.
    ///
    /// This is an overloaded initializer, with variants using differently-typed `constructor` parameters. This variant
    /// should be used when the type `T` needs no arguments to be constructed.
    ///
    /// Note that this overload will automatically be used instead of ``init(metatable:fields:constructor:)-4jfps`` if
    /// the `metatable` parameter is omitted and `T` conforms to `PushableWithMetatable`.
    public init(fields: [String : StaticFieldType]? = nil, constructor: @escaping () -> T) {
        self.init(metatable: T.metatable, fields: fields, constructor: constructor)
    }

    /// Creates a Metaobject for a PushableWithMetatable type with a constructor that takes one argument.
    ///
    /// - Parameter fields: Any extra fields to add to the metaobject, in addition to the static fields from the
    ///   metatable.
    /// - Parameter constructor: The closure to use as the resulting value's constructor.
    ///
    /// This is an overloaded initializer, with variants using differently-typed `constructor` parameters. This variant
    /// should be used when the type `T` needs no arguments to be constructed.
    ///
    /// Note that this overload will automatically be used instead of ``init(metatable:fields:constructor:)-jxvw`` if
    /// the `metatable` parameter is omitted and `T` conforms to `PushableWithMetatable`.
    public init<Arg1>(fields: [String : StaticFieldType]? = nil, constructor: @escaping (Arg1) -> T) {
        self.init(metatable: T.metatable, fields: fields, constructor: constructor)
    }

    /// Creates a Metaobject for a PushableWithMetatable type with a constructor that takes two arguments.
    ///
    /// - Parameter fields: Any extra fields to add to the metaobject, in addition to the static fields from the
    ///   metatable.
    /// - Parameter constructor: The closure to use as the resulting value's constructor.
    ///
    /// This is an overloaded initializer, with variants using differently-typed `constructor` parameters. This variant
    /// should be used when the type `T` needs no arguments to be constructed.
    ///
    /// Note that this overload will automatically be used instead of ``init(metatable:fields:constructor:)-39bia`` if
    /// the `metatable` parameter is omitted and `T` conforms to `PushableWithMetatable`.
    public init<Arg1, Arg2>(fields: [String : StaticFieldType]? = nil, constructor: @escaping (Arg1, Arg2) -> T) {
        self.init(metatable: T.metatable, fields: fields, constructor: constructor)
    }

    /// Creates a Metaobject for a PushableWithMetatable type with a constructor that takes three arguments.
    ///
    /// - Parameter fields: Any extra fields to add to the metaobject, in addition to the static fields from the
    ///   metatable.
    /// - Parameter constructor: The closure to use as the resulting value's constructor.
    ///
    /// This is an overloaded initializer, with variants using differently-typed `constructor` parameters. This variant
    /// should be used when the type `T` needs no arguments to be constructed.
    ///
    /// Note that this overload will automatically be used instead of ``init(metatable:fields:constructor:)-12ify`` if
    /// the `metatable` parameter is omitted and `T` conforms to `PushableWithMetatable`.
    public init<Arg1, Arg2, Arg3>(fields: [String : StaticFieldType]? = nil, constructor: @escaping (Arg1, Arg2, Arg3) -> T) {
        self.init(metatable: T.metatable, fields: fields, constructor: constructor)
    }

    /// Creates a Metaobject for a PushableWithMetatable type with a constructor that takes four arguments.
    ///
    /// - Parameter fields: Any extra fields to add to the metaobject, in addition to the static fields from the
    ///   metatable.
    /// - Parameter constructor: The closure to use as the resulting value's constructor.
    ///
    /// This is an overloaded initializer, with variants using differently-typed `constructor` parameters. This variant
    /// should be used when the type `T` needs no arguments to be constructed.
    ///
    /// Note that this overload will automatically be used instead of ``init(metatable:fields:constructor:)-8jbcm`` if
    /// the `metatable` parameter is omitted and `T` conforms to `PushableWithMetatable`.
    public init<Arg1, Arg2, Arg3, Arg4>(fields: [String : StaticFieldType]? = nil, constructor: @escaping (Arg1, Arg2, Arg3, Arg4) -> T) {
        self.init(metatable: T.metatable, fields: fields, constructor: constructor)
    }

}
