// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

import CLua

#if !LUASWIFT_NO_FOUNDATION
import Foundation
#endif

struct LuaDecoder: Decoder, SingleValueDecodingContainer {
    private let L: LuaState
    private let index: CInt

    init(state: LuaState, index: CInt, codingPath: [CodingKey] = []) {
        self.L = state
        self.index = L.absindex(index)
        self.codingPath = codingPath
    }

    func push(key: CodingKey) {
        if let intVal = key.intValue {
            L.push(intVal)
        } else {
            L.push(key.stringValue)
        }
    }

    func checkType(_ swiftType: Any.Type, _ luaType: LuaType, index: CInt? = nil) throws {
        let actualType = L.type(index ?? self.index) ?? .nil // None shouldn't happen here, treat like nil
        if actualType != luaType {
            let description = "Expected to decode \(luaType) but found \(actualType) instead."
            throw DecodingError.typeMismatch(swiftType, DecodingError.Context(codingPath: self.codingPath, debugDescription: description))
        }
    }

    func checkValue<T, U>(_ swiftType: T.Type, value: U?) throws -> U {
        if let result = value {
            return result
        } else {
            let desc = "Failed to decode \(U.self) from Lua value"
            throw DecodingError.typeMismatch(swiftType, DecodingError.Context(codingPath: self.codingPath, debugDescription: desc))
        }
    }

    func nestedDecoderForIndex(_ index: CInt, codingPath: [CodingKey]) -> LuaDecoder {
        return LuaDecoder(state: L, index: index, codingPath: codingPath)
    }

    // Decoder
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey : Any] = [:]

    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> where Key : CodingKey {
        try checkType([String: Any].self, .table)
        return KeyedDecodingContainer(KeyedContainer(decoder: self))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        try checkType([Any].self, .table)
        return UnkeyedContainer(decoder: self)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        return self
    }

    // SingleValueDecodingContainer

    func decodeNil() -> Bool {
        return L.type(index) == .nil
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        try checkType(type, .boolean)
        return L.toboolean(index)
    }

    func decode(_ type: String.Type) throws -> String {
        try checkType(type, .string)
        guard let result = L.tostring(index) else {
            let desc = "Failed to decode string value"
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: desc))
        }
        return result
    }

    func decode(_ type: Double.Type) throws -> Double {
        try checkType(type, .number)
        return L.tonumber(index)!
    }

    func decode(_ type: Float.Type) throws -> Float {
        try checkType(type, .number)
        return Float(L.tonumber(index)!)
    }

    func decode(_ type: Int.Type) throws -> Int {
        try checkType(type, .number)
        return try checkValue(type, value: L.toint(index))
    }

    func decodeIntegerValue<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let intValue = try self.decode(Int.self)
        if let result = T(exactly: intValue) {
            return result
        } else {
            let desc = "Lua integer value out of range for \(T.self)"
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: desc))
        }
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        return try decodeIntegerValue(type)
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        return try decodeIntegerValue(type)
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        return try decodeIntegerValue(type)
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        return try decodeIntegerValue(type)
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        return try decodeIntegerValue(type)
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        return try decodeIntegerValue(type)
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        return try decodeIntegerValue(type)
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        return try decodeIntegerValue(type)
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        try checkType(type, .number)
        if let result = L.toint(index) {
            // Good, it fits within a signed lua_Integer
            return UInt64(result)
        }
        // See if it's a double representable as a UInt64 (which covers everything up to about 2^53)
        if let dblVal = L.tonumber(index), let result = UInt64(exactly: dblVal) {
            return result
        }
        return try checkValue(type, value: nil) // Will always error
    }

    func decode<T>(_ type: T.Type) throws -> T where T : Decodable {
#if !LUASWIFT_NO_FOUNDATION
        if type == Data.self {
            try checkType(type, .string)
            return Data(L.todata(index)!) as! T
        }
#endif
        return try T(from: self)
    }

    private struct _LuaKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = "\(intValue)"
            self.intValue = intValue
        }
    }

    struct KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let decoder: LuaDecoder
        var codingPath: [CodingKey]
        var allKeys: [Key] {
            let L = decoder.L
            var result: [Key] = []
            for (k, _) in L.pairs(decoder.index) {
                let t = L.type(k)!
                if t == .string {
                    if let str = L.tostring(k) {
                        result.append(Key(stringValue: str)!)
                    }
                } else if t == .number {
                    if let int = L.toint(k) {
                        result.append(Key(intValue: int)!)
                    }
                }
            }
            return result
        }

        init(decoder: LuaDecoder) {
            self.decoder = decoder
            self.codingPath = decoder.codingPath
        }

        func decoderForKey<LocalKey: CodingKey>(_ key: LocalKey) throws -> LuaDecoder {
            decoder.push(key: key)
            try decoder.L.get(decoder.index)
            var newPath = self.codingPath
            newPath.append(key)
            return decoder.nestedDecoderForIndex(-1, codingPath: newPath)
        }

        func get<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
            let L = decoder.L
            let top = lua_gettop(L)
            defer {
                lua_settop(L, top)
            }
            let dec = try decoderForKey(key)
            return try dec.decode(type)
        }

        func contains(_ key: Key) -> Bool {
            decoder.push(key: key)
            let t = try? decoder.L.get(decoder.index)
            if let t {
                decoder.L.pop() // the result
                return t != .nil
            } else {
                // if it errored, safe to say it doesn't exist...
                return false
            }
        }

        func decodeNil(forKey key: Key) throws -> Bool {
            // Since we don't have an explicit nil value, I suppose this is right...?
            return !contains(key)
        }

        func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
            return try get(type, forKey: key)
        }

        func decode(_ type: String.Type, forKey key: Key) throws -> String {
            return try get(type, forKey: key)
        }

        func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
            return try get(type, forKey: key)
        }

        func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
            return try get(type, forKey: key)
        }

        func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
            return try get(type, forKey: key)
        }

        func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
            return try get(type, forKey: key)
        }

        func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
            return try get(type, forKey: key)
        }

        func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
            return try get(type, forKey: key)
        }

        func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
            return try get(type, forKey: key)
        }

        func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
            return try get(type, forKey: key)
        }

        func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
            return try get(type, forKey: key)
        }

        func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
            return try get(type, forKey: key)
        }

        func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
            return try get(type, forKey: key)
        }

        func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
            return try get(type, forKey: key)
        }

        func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T : Decodable {
            return try get(type, forKey: key)
        }

        func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> where NestedKey : CodingKey {
            return try decoderForKey(key).container(keyedBy: type)
        }

        func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
            return try decoderForKey(key).unkeyedContainer()
        }

        func superDecoder() throws -> Decoder {
            fatalError()
        }

        func superDecoder(forKey key: Key) throws -> Decoder {
            fatalError()
        }
    }

    struct UnkeyedContainer: UnkeyedDecodingContainer {
        private let decoder: LuaDecoder
        private var idx: lua_Integer = 1

        var codingPath: [CodingKey]
        private(set) var count: Int? = nil // We never know how big we are (without doing an O(N) linear search)
        private(set) var isAtEnd = false
        var currentIndex: Int {
            return Int(idx) - 1
        }

        init(decoder: LuaDecoder) {
            self.decoder = decoder
            self.codingPath = decoder.codingPath
            self.isAtEnd = lua_rawgeti(decoder.L, decoder.index, 1) == LUA_TNIL
            decoder.L.pop()
        }

        mutating func decoderForNext() throws -> LuaDecoder {
            lua_rawgeti(decoder.L, decoder.index, idx)
            var newPath = self.codingPath
            newPath.append(_LuaKey(intValue: currentIndex)!)
            idx = idx + 1
            isAtEnd = lua_rawgeti(decoder.L, decoder.index, idx) == LUA_TNIL
            decoder.L.pop()
            return decoder.nestedDecoderForIndex(-1, codingPath: newPath)
        }

        mutating func getNext<T: Decodable>(_ type: T.Type) throws -> T {
            let L = decoder.L
            let top = L.gettop()
            defer {
                L.settop(top)
            }
            let dec = try decoderForNext()
            let result = try dec.decode(type)
            L.pop() // dec's stack value
            return result
        }

        mutating func decodeNil() throws -> Bool {
            // Lua tables being considered as arrays can't contain nil by definition,
            // so I don't think this can ever be hit?
            fatalError()
        }
        
        mutating func decode(_ type: Bool.Type) throws -> Bool {
            return try getNext(type)
        }

        mutating func decode(_ type: String.Type) throws -> String {
            return try getNext(type)
        }

        mutating func decode(_ type: Double.Type) throws -> Double {
            return try getNext(type)
        }

        mutating func decode(_ type: Float.Type) throws -> Float {
            return try getNext(type)
        }

        mutating func decode(_ type: Int.Type) throws -> Int {
            return try getNext(type)
        }

        mutating func decode(_ type: Int8.Type) throws -> Int8 {
            return try getNext(type)
        }

        mutating func decode(_ type: Int16.Type) throws -> Int16 {
            return try getNext(type)
        }

        mutating func decode(_ type: Int32.Type) throws -> Int32 {
            return try getNext(type)
        }

        mutating func decode(_ type: Int64.Type) throws -> Int64 {
            return try getNext(type)
        }

        mutating func decode(_ type: UInt.Type) throws -> UInt {
            return try getNext(type)
        }

        mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
            return try getNext(type)
        }

        mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
            return try getNext(type)
        }

        mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
            return try getNext(type)
        }

        mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
            return try getNext(type)
        }

        mutating func decode<T>(_ type: T.Type) throws -> T where T : Decodable {
            return try getNext(type)
        }

        mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> where NestedKey : CodingKey {
            let dec = try decoderForNext()
            let container = try dec.container(keyedBy: type)
            return container
        }

        mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
            let dec = try decoderForNext()
            let container = try dec.unkeyedContainer()
            return container
        }

        mutating func superDecoder() throws -> Decoder {
            fatalError()
        }

    }
}

//#endif
