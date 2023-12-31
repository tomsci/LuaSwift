// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

import CLua

internal enum MetafieldName: String {
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

internal enum InternalMetafieldValue {
    case function(lua_CFunction)
    case closure(LuaClosure)
    case value(LuaValue)
}

/// Describes a metatable to be used in a call to ``Lua/Swift/UnsafeMutablePointer/register(_:)-4rb3q``.
///
/// See <doc:BridgingSwiftToLua#Default-metatables>.
public struct DefaultMetatable {
    internal let mt: [MetafieldName: InternalMetafieldValue]

    public struct FunctionType {
        internal let value: InternalMetafieldValue
        public static func function(_ f: lua_CFunction) -> Self { return Self(value: .function(f)) }
        public static func closure(_ c: @escaping LuaClosure) -> Self { return Self(value: .closure(c)) }
        public static func value(_ v: LuaValue) -> Self { return Self(value: .value(v)) }
    }

    public init(
        add: FunctionType? = nil,
        sub: FunctionType? = nil,
        mul: FunctionType? = nil,
        div: FunctionType? = nil,
        mod: FunctionType? = nil,
        pow: FunctionType? = nil,
        unm: FunctionType? = nil,
        idiv: FunctionType? = nil,
        band: FunctionType? = nil,
        bor: FunctionType? = nil,
        bxor: FunctionType? = nil,
        bnot: FunctionType? = nil,
        shl: FunctionType? = nil,
        shr: FunctionType? = nil,
        concat: FunctionType? = nil,
        len: FunctionType? = nil,
        eq: FunctionType? = nil,
        lt: FunctionType? = nil,
        le: FunctionType? = nil,
        index: FunctionType? = nil,
        newindex: FunctionType? = nil,
        call: FunctionType? = nil,
        close: FunctionType? = nil,
        tostring: FunctionType? = nil)
    {
        var mt: [MetafieldName: InternalMetafieldValue] = [:]

        mt[.add] = add?.value
        mt[.sub] = sub?.value
        mt[.mul] = mul?.value
        mt[.div] = div?.value
        mt[.mod] = mod?.value
        mt[.pow] = pow?.value
        mt[.unm] = unm?.value
        mt[.idiv] = idiv?.value
        mt[.band] = band?.value
        mt[.bor] = bor?.value
        mt[.bxor] = bxor?.value
        mt[.bnot] = bnot?.value
        mt[.shl] = shl?.value
        mt[.shr] = shr?.value
        mt[.concat] = concat?.value
        mt[.len] = len?.value
        mt[.eq] = eq?.value
        mt[.lt] = lt?.value
        mt[.le] = le?.value
        mt[.index] = index?.value
        mt[.newindex] = newindex?.value
        mt[.call] = call?.value
        mt[.close] = close?.value
        mt[.tostring] = tostring?.value

        self.mt = mt
    }
}

/// Describes a metatable to be used in a call to ``Lua/Swift/UnsafeMutablePointer/register(_:)-8rgnn``.
///
/// A metatable defines what properties and/or methods on a type used with
/// ``Lua/Swift/UnsafeMutablePointer/push(userdata:toindex:)`` are accessible from Lua.
///
/// `Metatable` is usually used directly in a call to ``Lua/Swift/UnsafeMutablePointer/register(_:)-8rgnn`` like:
/// ```swift
/// L.register(Metatable(for: /* type */,
///                      fields: [ /* ... */ ],
///                      /* metafields ... */
/// )
/// ```
/// `fields` defines all the properties and functions that the value should have in Lua. It is a dictionary of names to
/// some form of closure, depending on the field type. It is a convenience alternative to specifying an explicit
/// `index` metafield (see below) using type inference on the closure to avoid some of the type conversion boilerplate
/// that would otherwise have to be written. Various helper functions are defined by ``Metatable/FieldType`` for 
/// different types of field. See <doc:BridgingSwiftToLua#Defining-a-metatable> for examples.
///
/// `fields`, and all other metafields that can be specified in the constructor such as `call`, `tostring` etc, are
/// all optional - the resulting metatable contains only the (meta)fields specified. A completely empty metatable which
/// does nothing except define a unique type Lua-side is perfectly valid and can be useful in some circumstances.
///
/// The remaining optional parameters to the `Metatable` constructor are for defining metafields -- each argument
/// usually defines a function which is called when the relevant Lua metamethod event occurs. Various helpers are
/// defined to assist with this -- from `.closure { ... }` which provides the most flexibility, to `.memberfn
/// { ... }` which uses type inference to reduce the amount of boilerplate that needs to be written, at the cost of
/// slightly limiting expressiveness. See [`init(...)`][init] for the complete list of metafields. These correspond to
/// all the metafields [defined by Lua](https://www.lua.org/manual/5.4/manual.html#2.4) that are valid for userdata and
/// that aren't used internally by LuaSwift.
///
/// Metafield names in Swift are defined without the leading underscores used in the Lua names - so for example the
/// `index` argument to the `Metamethod` constructor refers to the `__index` metafield in Lua.
///
/// [init]: doc:Metatable/init(for:fields:add:sub:mul:div:mod:pow:unm:idiv:band:bor:bxor:bnot:shl:shr:concat:len:eq:lt:le:index:newindex:call:close:tostring:)
public struct Metatable<T> {
    internal let mt: [MetafieldName: InternalMetafieldValue]
    internal let unsynthesizedFields: [String: FieldType]?

    // Sooo much boilerplate so the caller doesn't have it.

    /// Represents all the ways to implement a field in a metatable.
    public struct FieldType {
        internal let value: InternalUserdataField
        // Helpers defined in an extension below, for clarity
    }

    /// Represents all the ways to implement various metamethods that don't use a more specific helper type.
    public struct FunctionType {
        internal let value: InternalMetafieldValue
        public static func function(_ f: lua_CFunction) -> Self { return Self(value: .function(f)) }
        public static func closure(_ c: @escaping LuaClosure) -> Self { return Self(value: .closure(c)) }
        public static func value(_ v: LuaValue) -> Self { return Self(value: .value(v)) }
    }

    /// Represents all the ways to implement a `eq` metamethod.
    public struct EqType {
        internal let value: InternalMetafieldValue
        public static func function(_ f: lua_CFunction) -> EqType { return EqType(value: .function(f)) }
        public static func closure(_ c: @escaping LuaClosure) -> EqType { return EqType(value: .closure(c)) }
        public static func value(_ v: LuaValue) -> Self { return Self(value: .value(v)) }
    }

    /// Represents all the ways to implement a `lt` metamethod.
    public struct LtType {
        internal let value: InternalMetafieldValue
        public static func function(_ f: lua_CFunction) -> Self { return Self(value: .function(f)) }
        public static func closure(_ c: @escaping LuaClosure) -> Self { return Self(value: .closure(c)) }
        public static func value(_ v: LuaValue) -> Self { return Self(value: .value(v)) }
    }

    /// Represents all the ways to implement a `le` metamethod.
    public struct LeType {
        internal let value: InternalMetafieldValue
        public static func function(_ f: lua_CFunction) -> Self { return Self(value: .function(f)) }
        public static func closure(_ c: @escaping LuaClosure) -> Self { return Self(value: .closure(c)) }
        public static func value(_ v: LuaValue) -> Self { return Self(value: .value(v)) }
    }

    /// Represents all the ways to implement a `index` metamethod.
    public struct IndexType {
        internal let value: InternalMetafieldValue
        public static func function(_ f: lua_CFunction) -> Self { return Self(value: .function(f)) }
        public static func closure(_ c: @escaping LuaClosure) -> Self { return Self(value: .closure(c)) }
        public static func value(_ v: LuaValue) -> Self { return Self(value: .value(v)) }
        public static func memberfn(_ indexfn: @escaping (T, String) throws -> Any?) -> Self {
            return .closure { L in
                let obj: T = try L.checkArgument(1)
                guard let memberName = L.tostringUtf8(2) else {
                    throw L.argumentError(2, "expected UTF-8 string member name")
                }
                let result = try indexfn(obj, memberName)
                L.push(any: result)
                return 1
            }
        }
        // Not specifiable directly - used by impl of fields
        internal static func synthesize(fields: [String: FieldType]) -> InternalMetafieldValue {
            return .closure { L in
                guard let memberName = L.tostringUtf8(2) else {
                    throw L.argumentError(2, "expected UTF-8 string member name")
                }
                switch fields[memberName]?.value {
                case .property(let getter):
                    return try getter(L)
                case .rwproperty(let getter, _):
                    return try getter(L)
                case .function(let fn):
                    L.push(function: fn)
                case .closure(let closure):
                    L.push(closure)
                case .value(let value):
                    L.push(value)
                case .none:
                    L.pushnil()
                }
                return 1
            }
        }
    }

    /// Represents all the ways to implement a `newindex` metamethod.
    public struct NewIndexType {
        internal let value: InternalMetafieldValue
        public static func function(_ f: lua_CFunction) -> Self { return Self(value: .function(f)) }
        public static func closure(_ c: @escaping LuaClosure) -> Self { return Self(value: .closure(c)) }
        public static func value(_ v: LuaValue) -> Self { return Self(value: .value(v)) }
        public static func memberfn(_ newindexfn: @escaping (T, String, LuaValue) throws -> Void) -> Self {
            return .closure { L in
                let obj: T = try L.checkArgument(1)
                guard let memberName = L.tostringUtf8(2) else {
                    throw L.argumentError(2, "expected UTF-8 string member name")
                }
                let newVal = L.ref(index: 3)
                try newindexfn(obj, memberName, newVal)
                return 0
            }
        }
    }

    /// Represents all the ways to implement a `call` metamethod.
    public struct CallType {
        internal let value: InternalMetafieldValue
        public static func function(_ f: lua_CFunction) -> Self { return Self(value: .function(f)) }
        public static func closure(_ c: @escaping LuaClosure) -> Self { return Self(value: .closure(c)) }
        public static func value(_ v: LuaValue) -> Self { return Self(value: .value(v)) }
        public static func memberfn<Ret>(_ accessor: @escaping (T) throws -> Ret) -> Self {
            return .closure(LuaState.makeClosure(accessor))
        }
        public static func memberfn<Arg1, Ret>(_ accessor: @escaping (T, Arg1) throws -> Ret) -> Self {
            return .closure(LuaState.makeClosure(accessor))
        }
        public static func memberfn<Arg1, Arg2, Ret>(_ accessor: @escaping (T, Arg1, Arg2) throws -> Ret) -> Self {
            return .closure(LuaState.makeClosure(accessor))
        }
        public static func memberfn<Arg1, Arg2, Arg3, Ret>(_ accessor: @escaping (T, Arg1, Arg2, Arg3) throws -> Ret) -> Self {
            return .closure(LuaState.makeClosure(accessor))
        }
    }

    /// Represents all the ways to implement a `close` metamethod.
    public struct CloseType {
        internal let value: InternalMetafieldValue
        public static func function(_ f: lua_CFunction) -> Self { return Self(value: .function(f)) }
        public static func closure(_ c: @escaping LuaClosure) -> Self { return Self(value: .closure(c)) }
        public static func value(_ v: LuaValue) -> Self { return Self(value: .value(v)) }

        /// Synthesize a `close` metamethod in this metatable.
        ///
        /// Specify `close: .synthesize` to create a `close` metamethod. This behaves in one of two ways, depending on
        /// whether `T` conforms to ``Closable``. If it does, then the synthesized metamethod will call
        /// ``Closable/close()``, for example to make a class `Foo` closable:
        /// 
        /// ```swift
        /// class Foo: Closable {
        ///     func close() {
        ///         // Do whatever
        ///     }
        ///     // .. rest of definition as applicable
        /// }
        /// 
        /// L.register(Metatable(for: Foo.self,
        ///     close: .synthesize // This will call Foo.close()
        /// ))
        /// ```
        /// 
        /// If `T` does _not_ conform to `Closable`, then  `close: .synthesize` will create a metamethod which
        /// deinits the Swift value, which will leave the object unusable from Lua after the variable is closed. This
        /// may be problematic for some scenarios, hence it is recommended such types should implement `Closable`.
        public static var synthesize: Self {
            return .function { L in
                let rawptr = lua_touserdata(L, 1)!
                let anyPtr = rawptr.bindMemory(to: Any.self, capacity: 1)
                if let closable = anyPtr.pointee as? Closable {
                    closable.close()
                } else {
                    anyPtr.deinitialize(count: 1)
                    // Leave anyPtr in a safe state for __gc
                    anyPtr.initialize(to: false)
                }
                return 0
            }
        }
        public static func memberfn(_ accessor: @escaping (T) throws -> Void) -> Self {
            return .closure(LuaState.makeClosure(accessor))
        }
    }

    /// Represents all the ways to implement a `tostring` metamethod.
    public struct TostringType {
        internal let value: InternalMetafieldValue
        public static func function(_ f: lua_CFunction) -> Self { return Self(value: .function(f)) }
        public static func closure(_ c: @escaping LuaClosure) -> Self { return Self(value: .closure(c)) }
        public static func value(_ v: LuaValue) -> Self { return Self(value: .value(v)) }

        /// Synthesize a `tostring` metamethod in this metatable.
        ///
        /// Specify `tostring: .synthesize` to create a `tostring` metamethod which uses the Swift `String(describing:)`
        /// API to create the result. This is compatible with `CustomStringConvertible` (as well as everything else
        /// `String(describing:)` accepts) so one way to configure a custom `tostring` metamethod is to implement
        /// `CustomStringConvertible` and then specify `tostring: .synthesize`:
        ///
        /// ```swift
        /// class Foo: CustomStringConvertible {
        ///     var description: {
        ///         return "MyCustomDescription"
        ///     }
        /// }
        ///
        /// // ...
        ///
        /// L.register(Metatable(for: Foo.self, tostring: .synthesize))
        /// L.push(userdata: Foo())
        /// print(L.tostring(-1, convert: true))
        /// // Outputs "MyCustomDescription"
        /// ```
        ///
        /// Implementing `CustomStringConvertible` is not _required_ to use `tostring: .synthesize` however -- the
        /// Swift-generated `String(describing:)` implementation can equally be used instead.
        public static var synthesize: Self {
            return .function { (L: LuaState!) in
                if let val: Any = L.touserdata(1) {
                    L.push(String(describing: val))
                } else {
                    // Should only be possible if the value has been closed and didn't support Closable
                    luaL_getmetafield(L, 1, "__name")
                    let typeName = L.tostringUtf8(-1) ?? "?"
                    L.push(utf8String: "\(typeName): nil")
                }
                return 1
            }
        }
    }

    /// See ``Metatable``.
    public init(
        for type: T.Type,
        fields: [String: FieldType]? = nil,
        add: FunctionType? = nil,
        sub: FunctionType? = nil,
        mul: FunctionType? = nil,
        div: FunctionType? = nil,
        mod: FunctionType? = nil,
        pow: FunctionType? = nil,
        unm: FunctionType? = nil,
        idiv: FunctionType? = nil,
        band: FunctionType? = nil,
        bor: FunctionType? = nil,
        bxor: FunctionType? = nil,
        bnot: FunctionType? = nil,
        shl: FunctionType? = nil,
        shr: FunctionType? = nil,
        concat: FunctionType? = nil,
        len: FunctionType? = nil,
        eq: EqType? = nil,
        lt: LtType? = nil,
        le: LeType? = nil,
        index: IndexType? = nil,
        newindex: NewIndexType? = nil,
        call: CallType? = nil,
        close: CloseType? = nil,
        tostring: TostringType? = nil)
    {
        var mt: [MetafieldName: InternalMetafieldValue] = [:]

        // fields
        var anyProperties = false
        var anyRwProperties = false
        if let fields {
            precondition(index == nil,
                "If any fields are specified, index must be nil")

            for (_, v) in fields {
                if case .property = v.value {
                    anyProperties = true
                } else if case .rwproperty = v.value {
                    anyProperties = true
                    anyRwProperties = true
                }
            }

            if anyProperties {
                mt[.index] = IndexType.synthesize(fields: fields)
                if anyRwProperties {
                    precondition(newindex == nil,
                        "If any properties with setters are specified, newindex must be nil")
                    mt[.newindex] = .closure { L in
                        guard let memberName = L.tostringUtf8(2) else {
                            throw L.argumentError(2, "expected UTF-8 string member name")
                        }
                        switch fields[memberName]?.value {
                        case .rwproperty(_, let setter):
                            return try setter(L)
                        default:
                            throw L.argumentError(2, "no set function defined for property \(memberName)")
                        }
                    }
                }
                unsynthesizedFields = nil
            } else {
                unsynthesizedFields = fields
            }
        } else {
            unsynthesizedFields = nil
        }

        mt[.add] = add?.value
        mt[.sub] = sub?.value
        mt[.mul] = mul?.value
        mt[.div] = div?.value
        mt[.mod] = mod?.value
        mt[.pow] = pow?.value
        mt[.unm] = unm?.value
        mt[.idiv] = idiv?.value
        mt[.band] = band?.value
        mt[.bor] = bor?.value
        mt[.bxor] = bxor?.value
        mt[.bnot] = bnot?.value
        mt[.shl] = shl?.value
        mt[.shr] = shr?.value
        mt[.concat] = concat?.value
        mt[.len] = len?.value
        mt[.eq] = eq?.value
        mt[.lt] = lt?.value
        mt[.le] = le?.value
        if let index {
            mt[.index] = index.value
        }
        if let newindex {
            mt[.newindex] = newindex.value
        }
        mt[.call] = call?.value
        mt[.close] = close?.value
        mt[.tostring] = tostring?.value

        self.mt = mt
    }

    // Only for supporting legacy registerMetatable() API
    internal init(for type: T.Type, legacyApiMetafields: [MetafieldName: InternalMetafieldValue]) {
        mt = legacyApiMetafields
        unsynthesizedFields = nil
    }
}

extension Metatable.EqType where T: Equatable {
    /// Synthesize a `eq` metamethod in this metatable.
    ///
    /// The generated metamethod uses the Swift `==` operator, therefore `T` must conform to `Equatable`.
    public static var synthesize: Metatable.EqType {
        return Metatable.EqType(value: .closure { L in
            if let lhs: T = L.touserdata(1),
               let rhs: T = L.touserdata(2) {
                L.push(lhs == rhs)
            } else {
                L.push(false)
            }
            return 1
        })
    }
}

extension Metatable.LtType where T: Comparable {
    /// Synthesize a `lt` metamethod in this metatable.
    ///
    /// The generated metamethod uses the Swift `<` operator, therefore `T` must conform to `Comparable`.
    public static var synthesize: Metatable.LtType {
        return Metatable.LtType(value: .closure { L in
            if let lhs: T = L.touserdata(1),
               let rhs: T = L.touserdata(2) {
                L.push(lhs < rhs)
            } else {
                L.push(false)
            }
            return 1
        })
    }
}

extension Metatable.LeType where T: Comparable {
    /// Synthesize a `le` metamethod in this metatable.
    ///
    /// The generated metamethod uses the Swift `<=` operator, therefore `T` must conform to `Comparable`.
    public static var synthesize: Metatable.LeType {
        return Metatable.LeType(value: .closure { L in
            if let lhs: T = L.touserdata(1),
               let rhs: T = L.touserdata(2) {
                L.push(lhs <= rhs)
            } else {
                L.push(false)
            }
            return 1
        })
    }
}

internal enum InternalUserdataField {
    case function(lua_CFunction)
    case closure(LuaClosure)
    case value(LuaValue)
    case property(LuaClosure)
    case rwproperty(LuaClosure, LuaClosure)
}

/// Helper struct used in the registration of metatables.
extension Metatable.FieldType {

    /// Used to define a property field in a metatable.
    ///
    /// Specify just a `get:` closure to define a readonly property, include a `set:` closure as well to define a
    /// read-write property. For example, given a class like:
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
    /// See ``Lua/Swift/UnsafeMutablePointer/register(_:)-8rgnn``.
    public static func property<ValType>(get: @escaping (T) -> ValType, set: Optional<(T, ValType) -> Void> = nil) -> Metatable.FieldType {
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
            return Metatable.FieldType(value: .rwproperty(getter, setter))
        } else {
            return Metatable.FieldType(value: .property(getter))
        }
    }

    public static func function(_ function: lua_CFunction) -> Metatable.FieldType {
        return Metatable.FieldType(value: .function(function))
    }

    public static func closure(_ closure: @escaping LuaClosure) -> Metatable.FieldType {
        return Metatable.FieldType(value: .closure(closure))
    }

    public static func value(_ value: LuaValue) -> Metatable.FieldType {
        return Metatable.FieldType(value: .value(value))
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
    /// The `inc()` function could be exposed to Lua by using `.memberfn` with a closure like:
    ///
    /// ```swift
    /// L.registerMetatable(for: Foo.self, fields: [
    ///     "inc": .memberfn { $0.inc() }
    /// ])
    /// ```
    ///
    /// The Swift closure may return any value which can be translated using
    /// ``Lua/Swift/UnsafeMutablePointer/push(tuple:)``. This includes returning `Void` (meaning the Lua function
    /// returns no results) or returning a tuple of N values (meaning the Lua function returns N values).
    ///
    /// See ``Lua/Swift/UnsafeMutablePointer/register(_:)-8rgnn``.
    public static func memberfn<Ret>(_ accessor: @escaping (T) throws -> Ret) -> Metatable.FieldType {
        return .closure(LuaState.makeClosure(accessor))
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
    /// The `inc()` function could be exposed to Lua by using `.memberfn` with a closure like:
    ///
    /// ```swift
    /// L.registerMetatable(for: Foo.self, fields: [
    ///     "inc": .memberfn { $0.inc(by: $1) }
    /// ])
    /// ```
    ///
    /// The Swift closure may return any value which can be translated using
    /// ``Lua/Swift/UnsafeMutablePointer/push(tuple:)``. This includes returning Void (meaning the Lua function returns
    /// no results) or returning a tuple of N values (meaning the Lua function returns N values). Any argument type
    /// which can be converted from Lua using ``Lua/Swift/UnsafeMutablePointer/tovalue(_:)`` (including optionals) can
    /// be used.
    ///
    /// See ``Lua/Swift/UnsafeMutablePointer/register(_:)-8rgnn``.
    public static func memberfn<Arg1, Ret>(_ accessor: @escaping (T, Arg1) throws -> Ret) -> Metatable.FieldType {
        return .closure(LuaState.makeClosure(accessor))
    }

    /// Used to define a two-argument member function in a metatable.
    ///
    /// The Swift closure may return any value which can be translated using
    /// ``Lua/Swift/UnsafeMutablePointer/push(tuple:)``. This includes returning Void (meaning the Lua function returns
    /// no results) or returning a tuple of N values (meaning the Lua function returns N values). Any argument type
    /// which can be converted from Lua using ``Lua/Swift/UnsafeMutablePointer/tovalue(_:)`` (including optionals) can
    /// be used.
    ///
    /// See ``Lua/Swift/UnsafeMutablePointer/register(_:)-8rgnn``.
    public static func memberfn<Arg1, Arg2, Ret>(_ accessor: @escaping (T, Arg1, Arg2) throws -> Ret) -> Metatable.FieldType {
        return .closure(LuaState.makeClosure(accessor))
    }

    public static func memberfn<Arg1, Arg2, Arg3, Ret>(_ accessor: @escaping (T, Arg1, Arg2, Arg3) throws -> Ret) -> Metatable.FieldType {
        return .closure(LuaState.makeClosure(accessor))
    }

    public static func staticfn<Ret>(_ accessor: @escaping () throws -> Ret) -> Metatable.FieldType {
        return .closure(LuaState.makeClosure(accessor))
    }

    public static func staticfn<Arg1, Ret>(_ accessor: @escaping (Arg1) throws -> Ret) -> Metatable.FieldType {
        return .closure(LuaState.makeClosure(accessor))
    }

    public static func staticfn<Arg1, Arg2, Ret>(_ accessor: @escaping (Arg1, Arg2) throws -> Ret) -> Metatable.FieldType {
        return .closure(LuaState.makeClosure(accessor))
    }

    public static func staticfn<Arg1, Arg2, Arg3, Ret>(_ accessor: @escaping (Arg1, Arg2, Arg3) throws -> Ret) -> Metatable.FieldType {
        return .closure(LuaState.makeClosure(accessor))
    }
}
