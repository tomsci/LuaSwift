// Copyright (c) 2024 Tom Sutcliffe
// See LICENSE file for license information.

#if !LUASWIFT_NO_FOUNDATION
import Foundation
#endif

internal class LuaEncoder: Encoder {
    enum DeinitStrategy {
        case settop
        case setkey
    }

    let L: LuaState
    // An encoder is always expected to leave exactly one item on the stack
    private let top: CInt
    private let deinitStrategy: DeinitStrategy

    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] = [:]

    init(state: LuaState, codingPath: [CodingKey] = [], deinitStrategy: DeinitStrategy = .settop) {
        self.L = state
        self.codingPath = codingPath
        self.deinitStrategy = deinitStrategy
        top = L.gettop() + 1
    }

    deinit {
        resetStack()
    }

    func resetStack() {
        switch deinitStrategy {
        case .settop:
            L.settop(top)
        case .setkey:
            // There should be value _and_ a key on the stack
            L.settop(top + 1)
            L.rawset(-3)
        }
    }

    func push(key: CodingKey, toindex: CInt = -1) {
        if let intVal = key.intValue {
            L.push(intVal, toindex: toindex)
        } else {
            L.push(key.stringValue, toindex: toindex)
        }
    }

    func invalidValue(_ value: Any, _ description: String) -> EncodingError {
        let ctx = EncodingError.Context(codingPath: self.codingPath, debugDescription: description)
        return EncodingError.invalidValue(value, ctx)
    }

    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        return KeyedEncodingContainer(LuaKeyedContainer(encoder: self))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        return LuaUnkeyedEncodingContainer(encoder: self)
    }
    
    func singleValueContainer() -> SingleValueEncodingContainer {
        return self
    }
}

extension LuaEncoder: SingleValueEncodingContainer {

    func encodeNil() throws {
        L.pushnil()
    }

    func encode(_ value: Bool) throws {
        L.push(value)
    }

    func encode(_ value: Int) throws {
        L.push(value)
    }

    func encode(_ value: Int8) throws {
        L.push(value)
    }

    func encode(_ value: Int16) throws {
        L.push(value)
    }

    func encode(_ value: Int32) throws {
        L.push(value)
    }

    func encode(_ value: Int64) throws {
        L.push(value)
    }

    func encode(_ value: UInt) throws {
        if value <= lua_Integer.max {
            L.push(lua_Integer(value))
        } else {
            let ctx = EncodingError.Context(codingPath: self.codingPath, debugDescription: "UInt value greater than lua_Integer.max")
            throw EncodingError.invalidValue(value, ctx)
        }
    }

    func encode(_ value: UInt8) throws {
        L.push(Int(value))
    }

    func encode(_ value: UInt16) throws {
        L.push(value)
    }

    func encode(_ value: UInt32) throws {
        L.push(value)
    }

    func encode(_ value: UInt64) throws {
        if value <= lua_Integer.max {
            L.push(lua_Integer(value))
        } else {
            throw invalidValue(value, "UInt64 value greater than lua_Integer.max")
        }
    }

    func encode(_ value: Float) throws {
        // should Float be pushable?
        L.push(Double(value))
    }

    func encode(_ value: Double) throws {
        L.push(value)
    }

    func encode(_ value: String) throws {
#if LUASWIFT_NO_FOUNDATION
        L.push(value) // Won't ever error
#else
        guard let data = value.data(using: L.getDefaultStringEncoding()) else {
            throw invalidValue(value, "String not representable in default encoding")
        }
        L.push(bytes: data)
#endif
    }

    func encode<T>(_ value: T) throws where T : Encodable {
#if !LUASWIFT_NO_FOUNDATION
        if let data = value as? ContiguousBytes {
            L.push(bytes: data)
            return
        }
#else
        if let data = value as? [UInt8] {
            L.push(data)
            return
        }
#endif
        try value.encode(to: self)
    }
}

internal class LuaKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    private var encoder: LuaEncoder
    private let L: LuaState

    let codingPath: [CodingKey]

    init(encoder: LuaEncoder) {
        L = encoder.L
        self.encoder = encoder
        self.codingPath = encoder.codingPath
        L.newtable()
    }

    func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        let encoder = LuaEncoder(state: L, codingPath: codingPath + [key], deinitStrategy: .setkey)
        encoder.push(key: key)
        let container = KeyedEncodingContainer(LuaKeyedContainer<NestedKey>(encoder: encoder))
        return container
    }

    func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        let encoder = LuaEncoder(state: L, codingPath: codingPath + [key], deinitStrategy: .setkey)
        encoder.push(key: key)
        let container = LuaUnkeyedEncodingContainer(encoder: encoder)
        return container
    }

    func superEncoder() -> any Encoder {
        // I assume it is implicitly understood that if an Encodable type calls this, it is its responsibility to
        // not use a key called "super". The docs don't really make that clear.
        return doSuperEncoder(forKey: LuaKey.super)
    }

    func superEncoder(forKey key: Key) -> any Encoder {
        return doSuperEncoder(forKey: key)
    }

    private func doSuperEncoder(forKey key: CodingKey) -> any Encoder {
        let encoder = LuaEncoder(state: L, codingPath: codingPath + [key], deinitStrategy: .setkey)
        encoder.push(key: key)
        return encoder
    }

    private func set(_ key: Key, _ encodeExpr: @autoclosure () throws -> Void) throws {
        encoder.codingPath = self.codingPath + [key]
        encoder.push(key: key)
        try encodeExpr()
        L.rawset(-3)
    }

    func encodeNil(forKey key: Key) throws {
        // Since a nil val in a Lua table means no key, this is a no-op
    }

    func encode(_ value: Bool, forKey key: Key) throws {
        try set(key, try encoder.encode(value))
    }

    func encode(_ value: Int, forKey key: Key) throws {
        try set(key, try encoder.encode(value))
    }

    func encode(_ value: Int8, forKey key: Key) throws {
        try set(key, try encoder.encode(value))
    }

    func encode(_ value: Int16, forKey key: Key) throws {
        try set(key, try encoder.encode(value))
    }

    func encode(_ value: Int32, forKey key: Key) throws {
        try set(key, try encoder.encode(value))
    }

    func encode(_ value: Int64, forKey key: Key) throws {
        try set(key, try encoder.encode(value))
    }

    func encode(_ value: UInt, forKey key: Key) throws {
        try set(key, try encoder.encode(value))
    }

    func encode(_ value: UInt8, forKey key: Key) throws {
        try set(key, try encoder.encode(value))
    }

    func encode(_ value: UInt16, forKey key: Key) throws {
        try set(key, try encoder.encode(value))
    }

    func encode(_ value: UInt32, forKey key: Key) throws {
        try set(key, try encoder.encode(value))
    }

    func encode(_ value: UInt64, forKey key: Key) throws {
        try set(key, try encoder.encode(value))
    }

    func encode(_ value: String, forKey key: Key) throws {
        try set(key, try encoder.encode(value))
    }

    func encode(_ value: Float, forKey key: Key) throws {
        try set(key, try encoder.encode(value))
    }

    func encode(_ value: Double, forKey key: Key) throws {
        try set(key, try encoder.encode(value))
    }

    func encode<T>(_ value: T, forKey key: Key) throws where T : Encodable {
        try set(key, try encoder.encode(value))
    }
}

internal class LuaUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    private let encoder: LuaEncoder
    private let L: LuaState

    let codingPath: [CodingKey]
    var currentCodingPath: [CodingKey] {
        return self.codingPath + [LuaKey(intValue: self.count)!]
    }

    var count: Int = 0

    init(encoder: LuaEncoder) {
        self.encoder = encoder
        L = encoder.L
        codingPath = encoder.codingPath
        L.newtable()
    }

    private func append(_ encodeExpr: @autoclosure () throws -> Void) throws {
        encoder.codingPath = currentCodingPath
        try encodeExpr()
        count = count + 1
        L.rawset(-2, key: count)
    }

    func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        let encoder = LuaEncoder(state: L, codingPath: self.currentCodingPath, deinitStrategy: .setkey)
        count = count + 1
        L.push(count)
        let container = KeyedEncodingContainer<NestedKey>(LuaKeyedContainer(encoder: encoder))
        return container
    }
    
    func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let encoder = LuaEncoder(state: L, codingPath: self.currentCodingPath, deinitStrategy: .setkey)
        count = count + 1
        L.push(count)
        let container = LuaUnkeyedEncodingContainer(encoder: encoder)
        return container
    }
    
    func superEncoder() -> any Encoder {
        let encoder = LuaEncoder(state: L, codingPath: self.codingPath + [LuaKey.super], deinitStrategy: .setkey)
        L.push(LuaKey.super.stringValue)
        return encoder
    }

    func encodeNil() throws {
        let ctx = EncodingError.Context(codingPath: self.currentCodingPath, debugDescription: "nil is not representable within arrays")
        throw EncodingError.invalidValue(LuaValue.nilValue, ctx)
    }

    func encode(_ value: Bool) throws {
        try append(try encoder.encode(value))
    }

    func encode(_ value: Int) throws {
        try append(try encoder.encode(value))
    }

    func encode(_ value: Int8) throws {
        try append(try encoder.encode(value))
    }

    func encode(_ value: Int16) throws {
        try append(try encoder.encode(value))
    }

    func encode(_ value: Int32) throws {
        try append(try encoder.encode(value))
    }

    func encode(_ value: Int64) throws {
        try append(try encoder.encode(value))
    }

    func encode(_ value: UInt) throws {
        try append(try encoder.encode(value))
    }

    func encode(_ value: UInt8) throws {
        try append(try encoder.encode(value))
    }

    func encode(_ value: UInt16) throws {
        try append(try encoder.encode(value))
    }

    func encode(_ value: UInt32) throws {
        try append(try encoder.encode(value))
    }

    func encode(_ value: UInt64) throws {
        try append(try encoder.encode(value))
    }

    func encode(_ value: Float) throws {
        try append(try encoder.encode(value))
    }

    func encode(_ value: Double) throws {
        try append(try encoder.encode(value))
    }

    func encode(_ value: String) throws {
        try append(try encoder.encode(value))
    }

    func encode<T>(_ value: T) throws where T : Encodable {
        // Why do we have to check and call encodeNil() ourselves?
        switch value {
        case let opt as Optional<Any>:
            if opt == nil {
                try encodeNil() // Will always throw
            }
        }

       try append(try encoder.encode(value))
    }
}
