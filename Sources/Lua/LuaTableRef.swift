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
        var result = Dictionary<AnyHashable, Any>()
        var testDict = Dictionary<AnyHashable, Any>()
        func good(_ key: AnyHashable, _ val: Any, keepOnSuccess: Bool) -> Bool {
            testDict[key] = val
            let success = test(testDict)
            testDict.removeAll(keepingCapacity: true)
            if success && keepOnSuccess {
                result[key] = val
            }
            return success
        }

        for (k, v) in L.pairs(index) {
            let key = L.toany(k, guessType: false)!
            let hashableKey = key as? AnyHashable
            let val = L.toany(v, guessType: false)!
            if let hashableKey, good(hashableKey, val, keepOnSuccess: true) {
                // Carry on
                continue
            }

            let possibleKeys = makePossibleKeys(key)
            let possibleValues = makePossibles(val)
            var found = false
            for pkey in possibleKeys {
                for pval in possibleValues {
                    if good(pkey, pval.value, keepOnSuccess: false) {
                        // Since LuaTableRef/LuaStringRef do not implement Hashable, we can ignore the need to resolve
                        // pkey. And pval only needs checking against LuaTableRef.
                        let innerTest = { good(pkey, $0, keepOnSuccess: false) }
                        if pval.isArray {
                            if let array = pval.tableRef!.doResolveArray(test: innerTest) {
                                result[pkey] = array
                                found = true
                            }
                        } else if pval.isDict {
                            if let dict = pval.tableRef!.doResolveDict(test: innerTest) {
                                result[pkey] = dict
                                found = true
                            }
                        } else {
                            result[pkey] = pval.value
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

    private func makePossibleKeys(_ val: Any) -> [AnyHashable] {
        var result: [AnyHashable] = []
        if let ref = val as? LuaStringRef {
            if let str = ref.toString() {
                result.append(str)
            }
            let data = ref.toData()
            result.append(data)
#if !LUASWIFT_NO_FOUNDATION
            result.append(Data(data))
#endif
        }
        if let hashable = val as? AnyHashable {
            result.append(hashable)
        }
        return result
    }

    // This exists to avoid extra dynamic casts on value
    struct PossibleValue {
        let value: Any
        let tableRef: LuaTableRef?
        let isDict: Bool
        let isArray: Bool
    }

    private func makePossibles(_ val: Any) -> [PossibleValue] {
        var result: [PossibleValue] = []
        if let ref = val as? LuaStringRef {
            if let str = ref.toString() {
                result.append(PossibleValue(value: str, tableRef: nil, isDict: false, isArray: false))
            }
            let data = ref.toData()
            result.append(PossibleValue(value: data, tableRef: nil, isDict: false, isArray: false))
#if !LUASWIFT_NO_FOUNDATION
            result.append(PossibleValue(value: Data(data), tableRef: nil, isDict: false, isArray: false))
#endif
        } else if let tableRef = val as? LuaTableRef {
            // An array table can always be represented as a dictionary, but not vice versa, so put Dictionary first
            // so that an untyped top-level T (which will result in the first option being chosen) at least doesn't
            // lose information and behaves consistently.
            result.append(PossibleValue(value: emptyAnyDict, tableRef: tableRef, isDict: true, isArray: false))
            result.append(PossibleValue(value: emptyAnyArray, tableRef: tableRef, isDict: false, isArray: true))
        }
        if result.isEmpty {
            result.append(PossibleValue(value: val, tableRef: nil, isDict: false, isArray: false))
        }
        return result
    }
}

fileprivate let emptyAnyArray = Array<Any>()
fileprivate let emptyAnyDict = Dictionary<AnyHashable, Any>()
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
