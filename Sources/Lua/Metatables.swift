// Copyright (c) 2023-2025 Tom Sutcliffe
// See LICENSE file for license information.

import CLua

internal typealias UserdataToAnyFn = (LuaState, CInt) -> Any
internal typealias PushValFn = (LuaState, Any) -> Void
internal typealias GcFn = (UnsafeMutableRawPointer) -> Void

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
    case pairs = "__pairs"
    case name = "__name"
}

internal enum InternalMetafieldValue {
    case function(lua_CFunction)
    case closure(LuaClosure)
    case memberClosure(LuaMemberClosure)
    case novalue
    case string(String) // Only for __name
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
        tostring: FunctionType? = nil,
        pairs: FunctionType? = nil,
        name: String? = nil)
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
        mt[.pairs] = pairs?.value
        if let name {
            mt[.name] = .string(name)
        }
        self.mt = mt
    }
}

/// Describes a metatable to be used in a call to ``Lua/Swift/UnsafeMutablePointer/register(_:)-8rgnn``.
///
/// A metatable defines what properties and/or methods on a type used with
/// ``Lua/Swift/UnsafeMutablePointer/push(userdata:toindex:)`` are accessible from Lua.
///
/// `Metatable` is usually used directly in a call to ``Lua/Swift/UnsafeMutablePointer/register(_:)-8rgnn``, or in
/// implementations of the ``PushableWithMetatable`` protocol. For example:
///
/// ```swift
/// L.register(Metatable</*type*/>(
///     fields: [ /* ... */ ],
///     /* metamethods ... */
/// ))
///
/// // ...or...
///
/// class Foo: PushableWithMetatable {
///     static let metatable = Metatable<Foo>(fields: [ /* ... */ ])
///     /* ... */
/// }
/// ```
///
/// `fields` defines all the properties and functions that the value should have in Lua. It is a dictionary of names to
/// some form of closure, depending on the field type. It is a convenience alternative to specifying an explicit
/// `index` metamethod (see below) using type inference on the closure to avoid some of the type conversion boilerplate
/// that would otherwise have to be written. Various helper functions are defined by ``Metatable/FieldType`` for 
/// different types of field.
///
/// See <doc:BridgingSwiftToLua#Defining-a-metatable> for examples.
///
/// `fields`, and all other metamethods that can be specified in the constructor such as `call`, `tostring` etc, are
/// all optional - the resulting metatable contains only the (meta)fields specified. A completely empty metatable which
/// does nothing except define a unique type Lua-side is perfectly valid and can be useful in some circumstances.
///
/// The remaining optional parameters to the `Metatable` constructor are for defining metamethods -- each argument
/// usually defines a function which is called when the relevant Lua metamethod event occurs. Various helpers are
/// defined to assist with this -- from `.closure { ... }` which provides the most flexibility, to `.memberfn
/// { ... }` which uses type inference to reduce the amount of boilerplate that needs to be written, at the cost of
/// slightly limiting expressiveness. See [`init(...)`][init] for the complete list of metamethods. These correspond to
/// all the metamethods [defined by Lua](https://www.lua.org/manual/5.4/manual.html#2.4) that are valid for userdata and
/// that aren't used internally by LuaSwift.
///
/// Metamethod names in Swift are defined without the leading underscores used in the Lua names - so for example the
/// `index` argument to the `Metatable` constructor refers to the `__index` metamethod in Lua.
///
/// > Note: declaring a `close` metamethod will have no effect if running with a Lua version prior to 5.4.
///
/// [init]: doc:Metatable/init(fields:add:sub:mul:div:mod:pow:unm:idiv:band:bor:bxor:bnot:shl:shr:concat:len:eq:lt:le:index:newindex:call:close:tostring:pairs:name:)
public struct Metatable<T> {
    internal let mt: [MetafieldName: InternalMetafieldValue]
    internal let unsynthesizedFields: [String: InternalUserdataField]?

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
        public static var none: Self { return Self(value: .novalue) }
    }

    /// Represents all the ways to implement a `eq` metamethod.
    public struct EqType {
        internal let value: InternalMetafieldValue
        public static func function(_ f: lua_CFunction) -> Self { return Self(value: .function(f)) }
        public static func closure(_ c: @escaping LuaClosure) -> Self { return Self(value: .closure(c)) }
        public static var none: Self { return Self(value: .novalue) }
    }

    /// Represents all the ways to implement a `lt` metamethod.
    public struct LtType {
        internal let value: InternalMetafieldValue
        public static func function(_ f: lua_CFunction) -> Self { return Self(value: .function(f)) }
        public static func closure(_ c: @escaping LuaClosure) -> Self { return Self(value: .closure(c)) }
        public static var none: Self { return Self(value: .novalue) }
    }

    /// Represents all the ways to implement a `le` metamethod.
    public struct LeType {
        internal let value: InternalMetafieldValue
        public static func function(_ f: lua_CFunction) -> Self { return Self(value: .function(f)) }
        public static func closure(_ c: @escaping LuaClosure) -> Self { return Self(value: .closure(c)) }
        public static var none: Self { return Self(value: .novalue) }
    }

    /// Represents all the ways to implement a `index` metamethod.
    public struct IndexType {
        internal let value: InternalMetafieldValue
        public static func function(_ f: lua_CFunction) -> Self { return Self(value: .function(f)) }
        public static func closure(_ c: @escaping LuaClosure) -> Self { return Self(value: .closure(c)) }
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
        internal static func synthesize(fields: [String: InternalUserdataField]) -> LuaMemberClosure {
            return { L, mtPtr in
                guard let memberName = L.tostringUtf8(2) else {
                    throw L.argumentError(2, "expected UTF-8 string member name")
                }
                switch fields[memberName] {
                case .property(let getter):
                    return try getter(L, mtPtr)
                case .rwproperty(let getter, _):
                    return try getter(L, mtPtr)
                case .function(let fn):
                    L.push(function: fn)
                case .closure(let closure):
                    L.push(closure)
                case .constant(let closure):
                    return try closure(L)
                case .memberClosure(let closure):
                    L.push({ L in
                        try closure(L, mtPtr)
                    })
                case .novalue:
                    L.pushnil()
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
        public static func memberfn(_ newindexfn: @escaping (inout T, String, LuaValue) throws -> Void) -> Self {
            return Self(value: .memberClosure { L, mtPtr in
                let obj: UnsafeMutablePointer<T> = try L.checkUserdata(1)
                guard let memberName = L.tostringUtf8(2) else {
                    throw L.argumentError(2, "expected UTF-8 string member name")
                }
                let newVal = L.ref(index: 3)
                try newindexfn(&obj.pointee, memberName, newVal)
                return 0
            })
        }
    }

    /// Represents all the ways to implement a `call` metamethod.
    public struct CallType {
        internal let value: InternalMetafieldValue
        public static func function(_ f: lua_CFunction) -> Self { return Self(value: .function(f)) }
        public static func closure(_ c: @escaping LuaClosure) -> Self { return Self(value: .closure(c)) }
        public static func memberfn<Ret>(_ accessor: @escaping (inout T) throws -> Ret) -> Self {
            return .init(value: .memberClosure(LuaState.makeMemberClosure(accessor)))
        }
        public static func memberfn<Arg1, Ret>(_ accessor: @escaping (inout T, Arg1) throws -> Ret) -> Self {
            return .init(value: .memberClosure(LuaState.makeMemberClosure(accessor)))
        }
        public static func memberfn<Arg1, Arg2, Ret>(_ accessor: @escaping (inout T, Arg1, Arg2) throws -> Ret) -> Self {
            return .init(value: .memberClosure(LuaState.makeMemberClosure(accessor)))
        }
        public static func memberfn<Arg1, Arg2, Arg3, Ret>(_ accessor: @escaping (inout T, Arg1, Arg2, Arg3) throws -> Ret) -> Self {
            return .init(value: .memberClosure(LuaState.makeMemberClosure(accessor)))
        }
    }

    /// Represents all the ways to implement a `close` metamethod.
    public struct CloseType {
        internal let value: InternalMetafieldValue
        public static func function(_ f: lua_CFunction) -> Self { return Self(value: .function(f)) }
        public static func closure(_ c: @escaping LuaClosure) -> Self { return Self(value: .closure(c)) }
        public static var none: Self { return Self(value: .novalue) }

        public static func memberfn(_ accessor: @escaping (inout T) throws -> Void) -> Self {
            return .init(value: .memberClosure(LuaState.makeMemberClosure(accessor)))
        }
    }

    /// Represents all the ways to implement a `tostring` metamethod.
    public struct TostringType {
        internal let value: InternalMetafieldValue
        public static func function(_ f: lua_CFunction) -> Self { return Self(value: .function(f)) }
        public static func closure(_ c: @escaping LuaClosure) -> Self { return Self(value: .closure(c)) }

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
        /// L.register(Metatable<Foo>(tostring: .synthesize))
        /// L.push(userdata: Foo())
        /// print(L.tostring(-1, convert: true))
        /// // Outputs "MyCustomDescription"
        /// ```
        ///
        /// Implementing `CustomStringConvertible` is not _required_ to use `tostring: .synthesize` however -- the
        /// Swift-generated `String(describing:)` implementation can equally be used instead.
        public static var synthesize: Self {
            return .init(value: .memberClosure(LuaState.makeMemberClosure({ (val: T) in
                return String(describing: val)
            })))
        }

        public static func memberfn(_ accessor: @escaping (T) throws -> String) -> Self {
            return .init(value: .memberClosure(LuaState.makeMemberClosure(accessor)))
        }
    }

    public struct PairsType {
        internal let value: InternalMetafieldValue
        public static func function(_ f: lua_CFunction) -> Self { return Self(value: .function(f)) }
        public static func closure(_ c: @escaping LuaClosure) -> Self { return Self(value: .closure(c)) }
    }

    /// See ``Metatable``.
    public init(
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
        tostring: TostringType? = nil,
        pairs: PairsType? = nil,
        name: String? = nil)
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
        mt[.index] = index?.value // might be overridden below
        mt[.newindex] = newindex?.value // ditto
        mt[.call] = call?.value
        mt[.close] = close?.value
        mt[.tostring] = tostring?.value
        mt[.pairs] = pairs?.value
        if let name {
            mt[.name] = .string(name)
        }

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

            // Having properties means we have to synthesize an __index metamethod
            if anyProperties {
                mt[.index] = .memberClosure(IndexType.synthesize(fields: fields.mapValues { $0.value }))
                if anyRwProperties {
                    precondition(newindex == nil,
                        "If any read-write properties are specified, newindex must be nil")
                    mt[.newindex] = .memberClosure { L, mtPtr in
                        guard let memberName = L.tostringUtf8(2) else {
                            throw L.argumentError(2, "expected UTF-8 string member name")
                        }
                        switch fields[memberName]?.value {
                        case .rwproperty(_, let setter):
                            return try setter(L, mtPtr)
                        default:
                            throw L.argumentError(2, "no set function defined for property \(memberName)")
                        }
                    }
                }
                unsynthesizedFields = nil
            } else {
                unsynthesizedFields = fields.mapValues { $0.value }
            }
        } else {
            unsynthesizedFields = nil
        }

        self.mt = mt
    }

    internal init(mt: [MetafieldName: InternalMetafieldValue], unsynthesizedFields: [String: InternalUserdataField]?) {
        self.mt = mt
        self.unsynthesizedFields = unsynthesizedFields
    }

    /// Returns the type object for this metatable, ie `T.self`.
    public var type: T.Type {
        return T.self
    }

    internal let toany: UserdataToAnyFn = { L, index in
        // Note, we're not checking the type here, that's the caller's responsibility to do in advance.
        let typedPtr: T = L.unchecked_touserdata(index)!
        return typedPtr as Any
    }

    internal let pushval: PushValFn = { L, untypedVal in
        let typedVal: T = untypedVal as! T
        let udata = luaswift_newuserdata(L, MemoryLayout<T>.size)!
        let udataPtr = udata.bindMemory(to: T.self, capacity: 1)
        udataPtr.initialize(to: typedVal)
    }

    internal let gc: GcFn = { rawPtr in
        let typedPtr = rawPtr.assumingMemoryBound(to: T.self)
        typedPtr.deinitialize(count: 1)
    }

    /// Defines a metatable suitable for use in a derived class whose parent conforms to `PushableWithMetatable`.
    ///
    /// When defining a `metatable` on a derived class, when the parent already conforms to `PushableWithMetatable`,
    /// calling this function on the parent's metatable creates a metatable for the derived class that calls into the
    /// parent where appropriate. Usage:
    /// 
    /// ```swift
    /// class Base: PushableWithMetatable {
    ///     // ...
    ///     class var metatable: Metatable<Base> { return Metatable(/* ... */) }
    /// }
    ///
    /// class Derived: Base {
    ///     // ...
    ///     class override var metatable: Metatable<Base> {
    ///         return Base.metatable.subclass(type: Derived.self, /* ... */)
    ///     }
    /// }
    /// ```
    ///
    /// See ``PushableWithMetatable`` for more information.
    public func subclass<D>(
        type: D.Type,
        fields: [String: Metatable<D>.FieldType]? = nil,
        add: Metatable<D>.FunctionType? = nil,
        sub: Metatable<D>.FunctionType? = nil,
        mul: Metatable<D>.FunctionType? = nil,
        div: Metatable<D>.FunctionType? = nil,
        mod: Metatable<D>.FunctionType? = nil,
        pow: Metatable<D>.FunctionType? = nil,
        unm: Metatable<D>.FunctionType? = nil,
        idiv: Metatable<D>.FunctionType? = nil,
        band: Metatable<D>.FunctionType? = nil,
        bor: Metatable<D>.FunctionType? = nil,
        bxor: Metatable<D>.FunctionType? = nil,
        bnot: Metatable<D>.FunctionType? = nil,
        shl: Metatable<D>.FunctionType? = nil,
        shr: Metatable<D>.FunctionType? = nil,
        concat: Metatable<D>.FunctionType? = nil,
        len: Metatable<D>.FunctionType? = nil,
        eq: Metatable<D>.EqType? = nil,
        lt: Metatable<D>.LtType? = nil,
        le: Metatable<D>.LeType? = nil,
        index: Metatable<D>.IndexType? = nil,
        newindex: Metatable<D>.NewIndexType? = nil,
        call: Metatable<D>.CallType? = nil,
        close: Metatable<D>.CloseType? = nil,
        tostring: Metatable<D>.TostringType? = nil,
        pairs: Metatable<D>.PairsType? = nil,
        name: String? = nil) -> Metatable<T>
    {
        var mt: [MetafieldName: InternalMetafieldValue] = [:]
        var unsynthesizedFields: [String: InternalUserdataField]? = nil
        let parent = self

        mt[.add] = add?.value ?? parent.mt[.add]
        mt[.sub] = sub?.value ?? parent.mt[.sub]
        mt[.mul] = mul?.value ?? parent.mt[.mul]
        mt[.div] = div?.value ?? parent.mt[.div]
        mt[.mod] = mod?.value ?? parent.mt[.mod]
        mt[.pow] = pow?.value ?? parent.mt[.pow]
        mt[.unm] = unm?.value ?? parent.mt[.unm]
        mt[.idiv] = idiv?.value ?? parent.mt[.idiv]
        mt[.band] = band?.value ?? parent.mt[.band]
        mt[.bor] = bor?.value ?? parent.mt[.bor]
        mt[.bxor] = bxor?.value ?? parent.mt[.bxor]
        mt[.bnot] = bnot?.value ?? parent.mt[.bnot]
        mt[.shl] = shl?.value ?? parent.mt[.shl]
        mt[.shr] = shr?.value ?? parent.mt[.shr]
        mt[.concat] = concat?.value ?? parent.mt[.concat]
        mt[.len] = len?.value ?? parent.mt[.len]
        mt[.eq] = eq?.value ?? parent.mt[.eq]
        mt[.lt] = lt?.value ?? parent.mt[.lt]
        mt[.le] = le?.value ?? parent.mt[.le]
        mt[.index] = index?.value ?? parent.mt[.index]
        mt[.newindex] = newindex?.value ?? parent.mt[.newindex]
        mt[.call] = call?.value ?? parent.mt[.call]
        mt[.close] = close?.value ?? parent.mt[.close]
        mt[.tostring] = tostring?.value ?? parent.mt[.tostring]
        mt[.pairs] = pairs?.value ?? parent.mt[.pairs]
        if let name {
            mt[.name] = .string(name)
        } else {
            mt[.name] = parent.mt[.name]
        }

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

            var allDerivedFields = fields.mapValues { $0.value }
            if let parentUnsythesizedFields = parent.unsynthesizedFields {
                for (name, field) in parentUnsythesizedFields {
                    if allDerivedFields[name] == nil {
                        allDerivedFields[name] = field
                    }
                }
            }

            if anyProperties {
                // We have to synthesize an index, including either parent's unsynthesizedFields (if it has any) or
                // caling into its index
                let indexFn = Metatable<D>.IndexType.synthesize(fields: allDerivedFields)

                // We unwind T's __index metafield to get at the underlying LuaClosure/LuaMemberClosures to avoid
                // unnecessary extra pcalls (in the most likely case).
                let parentIndexFn: LuaMemberClosure
                switch parent.mt[.index] {
                case .function(let cfunction):
                    // We have to push and pcall this, because we cannot risk the possibility that the caller used a
                    // real C function that could call lua_error
                    parentIndexFn = { L, mtPtr in
                        L.push(function: cfunction)
                        L.push(index: 1)
                        L.push(index: 2)
                        try L.pcall(nargs: 2, nret: 1)
                        return 1
                    }
                case .closure(let closure):
                    parentIndexFn = { L, mt in
                        return try closure(L)
                    }
                case .memberClosure(let closure):
                    parentIndexFn = closure
                default:
                    parentIndexFn = { L, mt in
                        L.pushnil()
                        return 1
                    }
                }

                mt[.index] = .memberClosure { L, mtPtr in
                    // Cross fingers that indexFn doesn't mess with the stack (it shouldn't, but...)
                    var nret = try indexFn(L, mtPtr)
                    if L.isnil(-1) {
                        L.pop()
                        nret = try parentIndexFn(L, mtPtr)
                    }
                    return nret
                }

                if anyRwProperties {
                    precondition(newindex == nil,
                        "If any read-write properties are specified, newindex must be nil")
                    let parentNewIndexFn: LuaMemberClosure
                    switch parent.mt[.newindex] {
                    case .function(let cfunction):
                        // We have to push and pcall this, because we cannot risk the possibility that the caller used a
                        // real C function that could call lua_error
                        parentNewIndexFn = { L, mtPtr in
                            L.push(function: cfunction)
                            L.push(index: 1)
                            L.push(index: 2)
                            L.push(index: 3)
                            try L.pcall(nargs: 3, nret: 0)
                            return 0
                        }
                    case .closure(let closure):
                        parentNewIndexFn = { L, mt in
                            return try closure(L)
                        }
                    case .memberClosure(let closure):
                        parentNewIndexFn = closure
                    default:
                        parentNewIndexFn = { L, mt in
                            let memberName: String = try L.checkArgument(2)
                            throw L.argumentError(2, "no set function defined for property \(memberName)")
                        }
                    }
                    mt[.newindex] = .memberClosure { L, mtPtr in
                        guard let memberName = L.tostringUtf8(2) else {
                            throw L.argumentError(2, "expected UTF-8 string member name")
                        }
                        print("newindex \(memberName)")
                        switch fields[memberName]?.value {
                        case .rwproperty(_, let setter):
                            return try setter(L, mtPtr)
                        default:
                            return try parentNewIndexFn(L, mtPtr)
                        }
                    }
                }
            } else {
                // We can only use unsynthesizedFields if neither us nor parent has a .index
                if let parentIndexFn = parent.mt[.index] {
                    // We haven't declared any additional properties, so we can call straight into the parent
                    mt[.index] = parentIndexFn
                } else {
                    unsynthesizedFields = allDerivedFields
                }
            }
        }

        return Metatable<T>(mt: mt, unsynthesizedFields: unsynthesizedFields)
    }
}

extension Metatable { // Swift doesn't yet support `where Base: AnyObject, T: Base`
    /// Cast a Metatable to a different type.
    ///
    /// This API is only for use by types implementing ``PushableWithMetatable`` in a derived class, in order to
    /// satisfy the type constraints of the protocol. In any other circumstances it will produce a Metatable that won't
    /// do anything useful.
    ///
    /// As such, `T` should derive from `Base` (and `Base` must be a class type). The Swift compiler does not yet
    /// enforce this however.
    ///
    /// > Warning: The use of derived classes with PushableWithMetatable no longer requires this API; therefore it has
    ///   been deprecated and will be removed in a future release. See the documentation for ``PushableWithMetatable``
    ///   for how to use
    ///   [`subclass()`](doc:subclass(type:fields:add:sub:mul:div:mod:pow:unm:idiv:band:bor:bxor:bnot:shl:shr:concat:len:eq:lt:le:index:newindex:call:close:tostring:pairs:name:))
    ///   instead.
    @available(*, deprecated, message: "Will be removed in v2.0.0. Use subclass(...) instead.")
    public func downcast<Base>() -> Metatable<Base> {
        return Metatable<Base>(mt: self.mt, unsynthesizedFields: self.unsynthesizedFields)
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

extension Metatable.CloseType where T: Closable {
    /// Synthesize a `close` metamethod in this metatable.
    ///
    /// Specify `close: .synthesize` to create a `close` metamethod based on `T` conforming to
    ///  ``Closable``, which calls ``Closable/close()``. For example to make a class `Foo` closable:
    /// 
    /// ```swift
    /// class Foo: Closable {
    ///     func close() {
    ///         // Do whatever
    ///     }
    ///     // .. rest of definition as applicable
    /// }
    /// 
    /// L.register(Metatable<Foo>(
    ///     close: .synthesize // This will call Foo.close()
    /// ))
    /// ```
    ///
    /// > Important: In LuaSwift v1.0 and earler, `synthesize` was available even when `T` didn't implement `Closable`,
    /// albeit with slightly unclear semantics. Due to changes in the implementation, this is no longer possible and
    /// `T` must implement `Closable` to use `synthesize`.
    public static var synthesize: Self {
        return .init(value: .memberClosure{ L, mtPtr in
            let obj: UnsafeMutablePointer<T> = try L.checkUserdata(1, mtPtr)
            obj.pointee.close()
            return 0
        })
    }
}

internal enum InternalUserdataField {
    case function(lua_CFunction)
    case closure(LuaClosure)
    case property(LuaMemberClosure)
    case rwproperty(LuaMemberClosure, LuaMemberClosure)
    case constant(LuaClosure)
    case memberClosure(LuaMemberClosure)
    case novalue
}

/// Helper struct used in the registration of metatables.
extension Metatable.FieldType {

    public static var none: Self { Self(value: .novalue) }

    /// Defines a property field in a metatable.
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
    /// L.register(Metatable<Foo>(fields: [
    ///     "prop": .property { $0.prop }
    /// ]))
    /// ```
    ///
    /// To make it so `prop` can be assigned to from Lua, specify both `get:` and `set:` closures:
    ///
    /// ```swift
    /// L.register(Metatable<Foo>(fields: [
    ///     "prop": .property(get: { $0.prop }, set: { $0.prop = $1 })
    /// ]))
    /// ```
    ///
    /// See ``Lua/Swift/UnsafeMutablePointer/register(_:)-8rgnn``.
    public static func property<ValType>(get: @escaping (T) -> ValType, set: Optional<(inout T, ValType) -> Void> = nil) -> Metatable.FieldType {
        let getter: LuaMemberClosure = { L, mtPtr in
            let obj: UnsafeMutablePointer<T> = try L.checkUserdata(1, mtPtr)
            let result = get(obj.pointee)
            L.push(any: result)
            return 1
        }

        if let set {
            let setter: LuaMemberClosure = { L, mtPtr in
                let obj: UnsafeMutablePointer<T> = try L.checkUserdata(1, mtPtr)
                // Arg 2 is the member name in a __newindex call
                let newVal: ValType = try L.checkArgument(3, type: ValType.self)
                set(&obj.pointee, newVal)
                return 0
            }
            return Metatable.FieldType(value: .rwproperty(getter, setter))
        } else {
            return Metatable.FieldType(value: .property(getter))
        }
    }

    /// Defines a static computed property in a metatable.
    ///
    /// For example, given a class or struct like this, with a member that is both static and computed:
    ///
    /// ```swift
    /// struct Foo {
    ///     static var prop: String {
    ///         return somethingNotNecessarilyConstant()
    ///     }
    /// }
    /// ```
    ///
    /// it cannot be included in a Metatable using `.constant` because that assumes the value won't ever change;
    /// nor is `.property` applicable because that assumes a member property. Instead, use `.staticvar`:
    ///
    /// ```swift
    /// L.register(Metatable<Foo>(fields: [
    ///     "prop": .staticvar { return Foo.prop }
    /// ]))
    /// ```
    public static func staticvar<ValType>(_ get: @escaping () -> ValType) -> Metatable.FieldType {
        let getter: LuaMemberClosure = { L, _ in
            let result = get()
            L.push(any: result)
            return 1
        }
        return Metatable.FieldType(value: .property(getter))
    }

    /// Defines a read-only property field in a metatable.
    ///
    /// This helper function defines a read-only property field in a metatable, using a key path. For example:
    ///
    /// ```swift
    /// struct Foo {
    ///     let value: Int
    /// }
    /// 
    /// L.register(Metatable<Foo>(fields: [
    ///     "value": .roproperty(\.value)
    /// ])
    /// ```
    ///
    /// If you are not concerned with explicitly controlling whether the property is writable or not, and want the
    /// metatable to follow the definition of the property (ie to be writable for `var` properties and not for `let`)
    /// then specify `.property` instead of `.roproperty` and the appropriate overload will be selected automatically.
    public static func roproperty<ValType>(_ keyPath: KeyPath<T, ValType>) -> Metatable.FieldType {
        let getter: LuaMemberClosure = { L, mtPtr in
            let obj: UnsafeMutablePointer<T> = try L.checkUserdata(1, mtPtr)
            let result: ValType = obj.pointee[keyPath: keyPath]
            L.push(any: result)
            return 1
        }
        return Metatable.FieldType(value: .property(getter))
    }

    /// Defines a read-write property field in a metatable.
    ///
    /// This helper function defines a read-write property field in a metatable, using a key path. For example:
    ///
    /// ```swift
    /// struct Foo {
    ///     var value: Int
    /// }
    /// 
    /// L.register(Metatable<Foo>(fields: [
    ///     "value": .rwproperty(\.value)
    /// ])
    /// ```
    ///
    /// If you are not concerned with explicitly controlling whether the property is writable or not, and want the
    /// metatable to follow the definition of the property (ie to be writable for `var` properties and not for `let`)
    /// then specify `.property` instead of `.rwproperty` and the appropriate overload will be selected automatically.
    public static func rwproperty<ValType>(_ keyPath: WritableKeyPath<T, ValType>) -> Metatable.FieldType {
        let getter: LuaMemberClosure = { L, mtPtr in
            let obj: UnsafeMutablePointer<T> = try L.checkUserdata(1, mtPtr)
            let result: ValType = obj.pointee[keyPath: keyPath]
            L.push(any: result)
            return 1
        }
        let setter: LuaMemberClosure = { L, mtPtr in
            let obj: UnsafeMutablePointer<T> = try L.checkUserdata(1, mtPtr)
            // Arg 2 is the member name in a __newindex call
            let newVal: ValType = try L.checkArgument(3, type: ValType.self)
            obj.pointee[keyPath: keyPath] = newVal
            return 0
        }
        return Metatable.FieldType(value: .rwproperty(getter, setter))
    }

    /// Defines a read-only property field in a metatable.
    ///
    /// This is an overloaded function, this overload will be used if the key path is not writable and will define a
    /// read-only property. For example:
    ///
    /// ```swift
    /// struct Foo {
    ///     let value: Int // Note: value is 'let'
    /// }
    /// 
    /// L.register(Metatable<Foo>(fields: [
    ///     "value": .property(\.value) // Produces a read-only property
    /// ])
    /// ```
    ///
    /// See also ``property(_:)-6z9uc``.
    public static func property<ValType>(_ keyPath: KeyPath<T, ValType>) -> Metatable.FieldType {
        return roproperty(keyPath)
    }

    /// Defines a read-write property field in a metatable.
    ///
    /// This is an overloaded function, this overload will be used if the key path is  writable and will define a
    /// read-write property. For example:
    ///
    /// ```swift
    /// struct Foo {
    ///     var value: Int // Note: value is 'var'
    /// }
    /// 
    /// L.register(Metatable<Foo>(fields: [
    ///     "value": .property(\.value) // Produces a read-write property
    /// ])
    /// ```
    /// See also ``property(_:)-7zd5t``.
    public static func property<ValType>(_ keyPath: WritableKeyPath<T, ValType>) -> Metatable.FieldType {
        return rwproperty(keyPath)
    }

    /// Add a constant value to the metatable.
    ///
    /// This value is shared by all instances using this metatable, and as such is only suitable to use if the value
    /// will never change over the lifetime of the `LuaState`. For anything more dynamic, use
    /// [`.staticvar`](doc:staticvar(_:)) or [`.property`](doc:property(get:set:)) as appropriate.
    public static func constant<ValType>(_ value: ValType) -> Metatable.FieldType {
        // This closure only exists to type-erase value
        let getter: LuaClosure = { L in
            L.push(any: value)
            return 1
        }
        return Metatable.FieldType(value: .constant(getter))
    }

    public static func function(_ function: lua_CFunction) -> Metatable.FieldType {
        return Metatable.FieldType(value: .function(function))
    }

    public static func closure(_ closure: @escaping LuaClosure) -> Metatable.FieldType {
        return Metatable.FieldType(value: .closure(closure))
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
    /// L.register(Metatable<Foo>(fields: [
    ///     "inc": .memberfn { $0.inc() }
    /// ]))
    /// ```
    ///
    /// The Swift closure may return any value which can be translated using
    /// ``Lua/Swift/UnsafeMutablePointer/push(tuple:)``. This includes returning `Void` (meaning the Lua function
    /// returns no results) or returning a tuple of N values (meaning the Lua function returns N values).
    ///
    /// See ``Lua/Swift/UnsafeMutablePointer/register(_:)-8rgnn``.
    public static func memberfn<Ret>(_ accessor: @escaping (inout T) throws -> Ret) -> Metatable.FieldType {
        return .init(value: .memberClosure(LuaState.makeMemberClosure(accessor)))
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
    /// L.register(Metatable<Foo>(fields: [
    ///     "inc": .memberfn { $0.inc(by: $1) }
    /// ]))
    /// ```
    ///
    /// The Swift closure may return any value which can be translated using
    /// ``Lua/Swift/UnsafeMutablePointer/push(tuple:)``. This includes returning Void (meaning the Lua function returns
    /// no results) or returning a tuple of N values (meaning the Lua function returns N values). Any argument type
    /// which can be converted from Lua using ``Lua/Swift/UnsafeMutablePointer/tovalue(_:)`` (including optionals) can
    /// be used.
    ///
    /// See ``Lua/Swift/UnsafeMutablePointer/register(_:)-8rgnn``.
    public static func memberfn<Arg1, Ret>(_ accessor: @escaping (inout T, Arg1) throws -> Ret) -> Metatable.FieldType {
        return .init(value: .memberClosure(LuaState.makeMemberClosure(accessor)))
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
    public static func memberfn<Arg1, Arg2, Ret>(_ accessor: @escaping (inout T, Arg1, Arg2) throws -> Ret) -> Metatable.FieldType {
        return .init(value: .memberClosure(LuaState.makeMemberClosure(accessor)))
    }

    public static func memberfn<Arg1, Arg2, Arg3, Ret>(_ accessor: @escaping (inout T, Arg1, Arg2, Arg3) throws -> Ret) -> Metatable.FieldType {
        return .init(value: .memberClosure(LuaState.makeMemberClosure(accessor)))
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

/// Protocol for types which declare their own metatable.
///
/// Types conforming to this protocol do not need to call ``Lua/Swift/UnsafeMutablePointer/register(_:)-8rgnn`` to
/// register their metatable, and automatically become `Pushable` without needing to implement
/// ``Pushable/push(onto:)``. The only thing the type needs to do is to declare a static (or class) member `metatable`.
/// For example:
///
/// ```swift
/// struct Foo: PushableWithMetatable {
///     // Normal struct definition...
///     func foo() -> String { return "Foo.foo" }
/// 
///     // PushableWithMetatable conformance here:
///     static var metatable: Metatable<Foo> { Metatable(fields: [
///         "foo": .memberfn { $0.foo() }
///     ])}
/// }
///
/// // No need to call L.register(Foo.metatable)
/// L.push(Foo())
/// ```
///
/// The `PushableWithMetatable` conformance can also be declared in an extension:
///
/// ```swift
/// struct Foo {
///     func foo() -> String { return "Foo.foo" }
/// }
/// 
/// extension Foo: PushableWithMetatable {
///     static var metatable: Metatable<Foo> { Metatable(fields: [
///         "foo": .memberfn { $0.foo() }
///     ])}
/// }
/// ```
///
/// The metatable is registered the first time an instance of this type is pushed (using any of `push(pushable)`,
/// `push(any:)` or `push(userdata:)`), if it isn't already registered. If this protocol is implemented by a base class,
/// instances of derived classes inherit the same metatable as the base class (unless a different metatable was
/// explicitly registered prior to when the first instance of the derived type is pushed).
///
/// It is possible to override a metatable in a derived class, providing the base class metatable was declared as a
/// `class var` and is declared directly in the class -- not, for example, within `extension Xyz :
/// PushableWithMetatable { ... }`. The use of the
/// [`subclass()`](doc:Metatable/subclass(type:fields:add:sub:mul:div:mod:pow:unm:idiv:band:bor:bxor:bnot:shl:shr:concat:len:eq:lt:le:index:newindex:call:close:tostring:pairs:name:))
/// API facilitates inheriting one metatable from another. For example:
///
/// ```swift
/// class Base: PushableWithMetatable {
///     func foo() -> String { return "Base.foo" }
///     class var metatable: Metatable<Base> {
///         return Metatable(fields: [
///             "foo": .memberfn { $0.foo() }
///         ])
///     }
/// }
///
/// class Derived: Base {
///     override func foo() -> String { return "Derived.foo" }
///     func bar() -> String { return "Derived.bar" }
///     class override var metatable: Metatable<Base> {
///         return Base.metatable.subclass(type: Derived.self, fields: [
///             "bar": .memberfn { $0.bar() }
///         ])
///     }
/// }
/// ```
///
/// Note that `Derived.metatable` does not need to explicitly reference `foo` -- it will be included due to it being
/// present in `Base.metatable`. Note also that the derived metatable still has to have type `Metatable<Base>` -- the
/// `subclass()` API takes care of correcting the types.
///
/// It is also possible to declare a metatable for protocols, by declaring the protocol conforms to
/// `PushableWithMetatable` and then extending it with a metatable. This should only be done when there's no possible
/// other way an object conforming to the protocol might want to be represented in Lua, however.
///
/// ```swift
/// protocol MyProtocol: PushableWithMetatable {
///     func foo() -> String
/// }
/// 
/// extension MyProtocol {
///     static var metatable: Metatable<any MyProtocol> {
///         return Metatable(fields: [
///             "foo": .memberfn { $0.foo() }
///         ])
///     }
/// }
///
/// ```
/// > Note: Types conforming to `PushableWithMetatable` should not provide an implementation of
/// ``Pushable/push(onto:)``. Always use the default implementation provided by `PushableWithMetatable`.
public protocol PushableWithMetatable: Pushable {
    // Ideally ValueType would be constrained to be the same as Self but I don't think that can be
    // expressed in a way that works for classes (which given the need for downcast(), is fair
    // enough really).
    associatedtype ValueType
    static var metatable: Metatable<ValueType> { get }
}

public extension PushableWithMetatable {
    internal func checkRegistered(_ state: LuaState) {
        if !state.isMetatableRegistered(for: ValueType.self) {
            state.register(Self.metatable)
        }
        if Self.self != ValueType.self && !state.isMetatableRegistered(for: Self.self) {
            state.register(type: Self.self, usingMetatable: Self.metatable)
        }
    }

    func push(onto state: LuaState) {
        state.push(userdata: self)
    }
}
