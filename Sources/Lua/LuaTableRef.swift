// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

#if !LUASWIFT_NO_FOUNDATION
import Foundation
#endif

/// Placeholder type used by ``Lua/Swift/UnsafeMutablePointer/toany(_:guessType:)`` when `guessType` is `false`.
public struct LuaTableRef {
    let L: LuaState
    let index: CInt

    public init(L: LuaState, index: CInt) {
        self.L = L
        self.index = L.absindex(index)
    }

    public func toArray() -> [Any]? {
        var result: [Any] = []
        for _ in L.ipairs(index) {
            if let value = L.toany(-1) {
                result.append(value)
            } else {
                print("Encountered value not representable as Any during array iteration")
                return nil
            }
        }
        return result
    }

    public func toDict() -> [AnyHashable: Any]? {
        var result: [AnyHashable: Any] = [:]
        for (kidx, vidx) in L.pairs(index) {
            if let k = L.toany(kidx),
               let kh = k as? AnyHashable,
               let v = L.toany(vidx) {
                result[kh] = v
            } else {
                print("Encountered value not representable as Any[Hashable] during dict iteration")
                return nil
            }
        }
        return result
    }

    func guessType() -> Any {
        var hasIntKeys = false
        var hasNonIntKeys = false
        for (k, _) in L.pairs(index) {
            let t = L.type(k)
            switch t {
            case .number:
                if L.toint(k) != nil {
                    hasIntKeys = true
                } else {
                    hasNonIntKeys = true
                }
            default:
                hasNonIntKeys = true
            }
        }
        if hasNonIntKeys {
            var result: [AnyHashable: Any] = [:]
            for (k, v) in L.pairs(index) {
                let key = L.toany(k, guessType: true)!
                let hashableKey: AnyHashable = (key as? AnyHashable) ?? (L.ref(index: k) as AnyHashable)
                result[hashableKey] = L.toany(v, guessType: true)!
            }
            return result
        } else if hasIntKeys {
            var result: [Any] = []
            for _ in L.ipairs(index) {
                result.append(L.toany(-1)!)
            }
            return result
        } else {
            // Empty table, assume array
            return Array<Any>()
        }
    }

    public func resolve<T>() -> T? {
        let opt: T? = nil
        let test = { (val: Any) in
            return (val as? T) != nil
        }
        if isArrayType(opt) {
            return doResolveArray(test: test) as? T
        } else {
            return doResolveDict(test: test) as? T
        }
    }

    func doResolveArray(test: (Any) -> Bool) -> Any? {
        var result = Array<Any>()
        var testArray = Array<Any>()
        func good(_ val: Any, keepOnSuccess: Bool) -> Bool {
            testArray.append(val)
            let success = test(testArray)
            // Oddly removeLast seems to be faster than removeAll(keepingCapacity: true)
            testArray.removeLast()
            if success && keepOnSuccess {
                result.append(val)
            }
            return success
        }

        var elementType: ValueType? = nil

        for _ in L.ipairs(index) {
            let value = L.toany(-1, guessType: false)! // toany cannot fail on a valid non-nil index
            if good(value, keepOnSuccess: true) {
                continue
            } else if let ref = value as? LuaStringRef {
                // First time we encounter a string, figure out what the right type to use is, and cache that, so we
                // don't have to test every element
                if elementType == nil {
                    elementType = ValueType(stringTest: { good($0, keepOnSuccess: false) })
                }

                switch elementType {
                case .string:
                    if let str = ref.toString() {
                        result.append(str)
                    } else {
                        return nil
                    }
                case .bytes:
                    result.append(ref.toData())
#if !LUASWIFT_NO_FOUNDATION
                case .data:
                    result.append(Data(ref.toData()))
#endif
                default:
                    return nil
                }
            } else if let ref = value as? LuaTableRef {
                if elementType == nil {
                    elementType = ValueType(tableTest: { good($0, keepOnSuccess: false) })
                }

                let resolvedVal: Any?
                switch elementType {
                case .array:
                    resolvedVal = ref.doResolveArray(test: { good($0, keepOnSuccess: false) })
                case .dict:
                    resolvedVal = ref.doResolveDict(test: { good($0, keepOnSuccess: false) })
                default:
                    return nil
                }
                if let resolvedVal {
                    result.append(resolvedVal)
                } else {
                    return nil
                }
            } else {
                // Nothing from toany has made T happy, give up
                return nil
            }
        }
        return result
    }

    func doResolveDict(test: (Any) -> Bool) -> Any? {
        var testDict = Dictionary<AnyHashable, Any>()
        func good(_ key: AnyHashable, _ val: Any) -> Bool {
            testDict[key] = val
            let success = test(testDict)
            testDict.removeAll(keepingCapacity: true)
            return success
        }

        var result = Dictionary<AnyHashable, Any>()

        var ktype: ValueType? = nil
        var vtype: ValueType? = nil

        for (k, v) in L.pairs(index) {
            let key = L.toany(k, guessType: false)!
            let hashableKey = key as? AnyHashable
            let val = L.toany(v, guessType: false)!
            if let hashableKey, good(hashableKey, val) {
                result[hashableKey] = val
                // Carry on
                continue
            }

            let possibleKeys = makePossibleKeys(ktype, key)
            let possibleValues = makePossibles(vtype, val)
            var found = false
            for pkey in possibleKeys {
                for pval in possibleValues {
                    if good(pkey.testValue, pval.testValue) {
                        assert(ktype == nil || ktype == pkey.type)
                        ktype = pkey.type
                        assert(vtype == nil || vtype == pval.type)
                        vtype = pval.type
                        // Since LuaTableRef/LuaStringRef do not implement Hashable, we can ignore the need to resolve
                        // pkey. And pval only needs checking against LuaTableRef.
                        let innerTest = { good(pkey.testValue, $0) }
                        if pval.type == .array {
                            if let array = pval.tableRef!.doResolveArray(test: innerTest) {
                                result[pkey.actualValue()!] = array
                                found = true
                            }
                        } else if pval.type == .dict {
                            if let dict = pval.tableRef!.doResolveDict(test: innerTest) {
                                result[pkey.actualValue()!] = dict
                                found = true
                            }
                        } else {
                            result[pkey.actualValue()!] = pval.actualValue()
                            found = true
                        }

                        if found {
                            break
                        }
                    }
                }
                if found {
                    break
                }
            }

            if !found {
                // This key and value couldn't be resolved
                return nil
            }
        }
        return result
    }

    struct PossibleKey {
        let testValue: AnyHashable
        let tableRef: LuaTableRef?
        let stringRef: LuaStringRef?
        let type: ValueType

        init(actualValue: AnyHashable) {
            type = .other
            testValue = actualValue
            tableRef = nil
            stringRef = nil
        }

        init(tableRef: LuaTableRef, dict: Bool) {
            testValue = dict ? emptyAnyHashableDict : emptyAnyHashableArray
            self.tableRef = tableRef
            self.stringRef = nil
            type = dict ? .dict : .array
        }

        init(stringRef: LuaStringRef, type: ValueType) {
            self.type = type
            switch type {
            case .string: testValue = emptyString
            case .bytes: testValue = dummyBytes
#if !LUASWIFT_NO_FOUNDATION
            case .data: testValue = emptyData
#endif
            default:
                fatalError("Bad type \(type) to init(stringRef:type:)")
            }
            self.tableRef = nil
            self.stringRef = stringRef
        }

        func actualValue() -> AnyHashable? {
            switch type {
            case .string: return stringRef!.toString()
            case .bytes: return stringRef!.toData()
#if !LUASWIFT_NO_FOUNDATION
            case .data: return Data(stringRef!.toData())
#endif
            case .array: fatalError("Can't call actualValue on an array")
            case .dict: fatalError("Can't call actualValue on a dict")
            case .other: return testValue
            }
        }
    }

    private func makePossibleKeys(_ ktype: ValueType?, _ val: Any) -> [PossibleKey] {
        var result: [PossibleKey] = []
        if let ref = val as? LuaStringRef {
            if ktype == nil || ktype == .string {
                result.append(PossibleKey(stringRef: ref, type: .string))
            }
            if ktype == nil || ktype == .bytes {
                result.append(PossibleKey(stringRef: ref, type: .bytes))
            }
#if !LUASWIFT_NO_FOUNDATION
            if ktype == nil || ktype == .data {
                result.append(PossibleKey(stringRef: ref, type: .data))
            }
#endif
        }
        if result.isEmpty && (ktype == nil || ktype == .other) {
            if let hashable = val as? AnyHashable {
                result.append(PossibleKey(actualValue: hashable))
            }
        }
        return result
    }

    // This exists to avoid extra dynamic casts on value
    struct PossibleValue {
        let testValue: Any
        let tableRef: LuaTableRef?
        let stringRef: LuaStringRef?
        let type: ValueType

        init(actualValue: Any) {
            type = .other
            testValue = actualValue
            tableRef = nil
            stringRef = nil
        }

        init(tableRef: LuaTableRef, dict: Bool) {
            testValue = dict ? emptyAnyDict : emptyAnyArray
            self.tableRef = tableRef
            self.stringRef = nil
            type = dict ? .dict : .array
        }

        init(stringRef: LuaStringRef, type: ValueType) {
            self.type = type
            switch type {
            case .string: testValue = emptyString
            case .bytes: testValue = dummyBytes
#if !LUASWIFT_NO_FOUNDATION
            case .data: testValue = emptyData
#endif
            default:
                fatalError("Bad type \(type) to init(stringRef:type:)")
            }
            self.tableRef = nil
            self.stringRef = stringRef
        }

        func actualValue() -> Any? {
            switch type {
            case .string: return stringRef!.toString()
            case .bytes: return stringRef!.toData()
#if !LUASWIFT_NO_FOUNDATION
            case .data: return Data(stringRef!.toData())
#endif
            case .array: fatalError("Can't call actualValue on an array")
            case .dict: fatalError("Can't call actualValue on a dict")
            case .other: return testValue
            }
        }
    }

    private func makePossibles(_ vtype: ValueType?, _ val: Any) -> [PossibleValue] {
        var result: [PossibleValue] = []
        if let ref = val as? LuaStringRef {
            if vtype == nil || vtype == .string {
                result.append(PossibleValue(stringRef: ref, type: .string))
            }
            if vtype == nil || vtype == .bytes {
                result.append(PossibleValue(stringRef: ref, type: .bytes))
            }
#if !LUASWIFT_NO_FOUNDATION
            if vtype == nil || vtype == .data {
                result.append(PossibleValue(stringRef: ref, type: .data))
            }
#endif
        } else if let tableRef = val as? LuaTableRef {
            // An array table can always be represented as a dictionary, but not vice versa, so put Dictionary first
            // so that an untyped top-level T (which will result in the first option being chosen) at least doesn't
            // lose information and behaves consistently.
            if vtype == nil || vtype == .dict {
                result.append(PossibleValue(tableRef: tableRef, dict: true))
            }
            if vtype == nil || vtype == .array {
                result.append(PossibleValue(tableRef: tableRef, dict: false))
            }
        }
        if result.isEmpty && (vtype == nil || vtype == .other) {
            result.append(PossibleValue(actualValue: val))
        }
        return result
    }
}

fileprivate let emptyAnyArray = Array<Any>()
fileprivate let emptyAnyDict = Dictionary<AnyHashable, Any>()
fileprivate let emptyAnyHashableArray = Array<AnyHashable>()
fileprivate let emptyAnyHashableDict = Dictionary<AnyHashable, AnyHashable>()
fileprivate let emptyString = ""
fileprivate let dummyBytes: [UInt8] = [0] // Not empty in case [] casts overly broadly
#if !LUASWIFT_NO_FOUNDATION
fileprivate let emptyData = Data()
#endif

enum ValueType {
    // string types
    case string
    case bytes // ie [UInt8]
#if !LUASWIFT_NO_FOUNDATION
    case data
#endif
    // table types
    case array
    case dict
    // as-is
    case other
}

extension ValueType {
    init?(stringTest test: (Any) -> Bool) {
        if test(emptyString) {
            self = .string
            return
        } else if test(dummyBytes) {
            self = .bytes
            return
        }
#if !LUASWIFT_NO_FOUNDATION
        if test(emptyData) {
            self = .data
            return
        }
#endif
        return nil
    }

    init?(tableTest test: (Any) -> Bool) {
        if test(emptyAnyArray) {
            self = .array
        } else if test(emptyAnyDict) {
            self = .dict
        } else {
            return nil
        }
    }
}

fileprivate func isArrayType<T>(_: T?) -> Bool {
    if let _ = emptyAnyArray as? T {
        return true
    } else {
        return false
    }
}
