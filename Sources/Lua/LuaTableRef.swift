// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

#if !LUASWIFT_NO_FOUNDATION
import Foundation
#endif

/// Placeholder type used by ``Lua/Swift/UnsafeMutablePointer/toany(_:guessType:)`` when `guessType` is `false`.
public struct LuaTableRef : LuaTemporaryRef {
    let L: LuaState
    let index: CInt

    public init(L: LuaState, index: CInt) {
        self.L = L
        self.index = L.absindex(index)
    }

    public func ref() -> LuaValue {
        L.push(index: index)
        return L.popref()
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
        let test = { (val: Any) -> Bool in
            return (val as? T) != nil
        }
        if isArrayType(opt) {
            return doResolveArray(test: test) as? T
        } else {
            return doResolveDict(test: test) as? T
        }
    }

    func doResolveArray(test: (Any) -> Bool) -> Any? {
        var testArray = Array<Any>()
        func good(_ val: Any) -> Bool {
            testArray.append(val)
            let success = test(testArray)
            // Oddly removeLast seems to be faster than removeAll(keepingCapacity: true)
            testArray.removeLast()
            return success
        }

        let acceptsAny: Bool
        var elementType: TypeConstraint?
        // The logic here is that since opaqueValue is of a type the caller cannot know about, and OpaqueType
        // implements no other protocols (even AnyClass), therefore if this succeeds it must be because the array
        // element type was Any.
        if good(opaqueValue) {
            elementType = .anyhashable
            acceptsAny = true
        } else if good(opaqueHashable) {
            elementType = .anyhashable
            acceptsAny = false
        } else if good(LuaValue.nilValue) { // Be sure to check this _after_ acceptsAny and anyhashable
            elementType = .luavalue
            acceptsAny = false
        } else {
            elementType = nil
            acceptsAny = false
        }

        var result = Array<Any>()
        for _ in L.ipairs(index) {
            if elementType == .luavalue {
                result.append(L.ref(index: -1))
                continue
            }

            let value = L.toany(-1, guessType: false)! // toany cannot fail on a valid non-nil index

            // Check we're not about to stuff a LuaStringRef or LuaTableRef into an Any
            // (Have to do this before the good(value) check)
            if acceptsAny, let tempRef = value as? LuaTemporaryRef {
                result.append(tempRef.ref())
                continue
            }

            if good(value) {
                result.append(value)
                continue
            } else if let ref = value as? LuaStringRef {
                if elementType == nil {
                    elementType = TypeConstraint(stringTest: { good($0) })
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
                case .luavalue:
                    fatalError("Should not reach here") // Handled above
                case .anyhashable:
                    result.append(ref.ref())
                case .dict, .array, .direct: // None of these are applicable for TypeConstraint(stringTest:)
                    return nil
                case .none: // TypeConstraint(stringTest:) failed to find any compatible type
                    return nil
                }
            } else if let ref = value as? LuaTableRef {
                if elementType == nil {
                    elementType = TypeConstraint(tableTest: { good($0) })
                }

                let resolvedVal: Any?
                switch elementType {
                case .array:
                    resolvedVal = ref.doResolveArray(test: { good($0) })
                case .dict:
                    resolvedVal = ref.doResolveDict(test: { good($0) })
                case .luavalue:
                    fatalError("Should not reach here") // Handled above
                case .anyhashable:
                    resolvedVal = ref.ref()
                case .string, .bytes, .direct: // None of these are applicable for TypeConstraint(tableTest:)
                    return nil
#if !LUASWIFT_NO_FOUNDATION
                case .data: // ditto
                    return nil
#endif
                case .none: // TypeConstraint(tableTest:) failed to find any compatible type
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
        var ktype: TypeConstraint? = nil
        var vtype: TypeConstraint? = nil

        for (k, v) in L.pairs(index) {
            let key = L.toany(k, guessType: false)!
            let val = L.toany(v, guessType: false)!
            let possibleKeys = PossibleValue.makePossibles(ktype, k, key)
            let possibleValues = PossibleValue.makePossibles(vtype, v, val)
            var found = false
            for pkey in possibleKeys {
                for pval in possibleValues {
                    if let pkeyTestValue = pkey.testValue as? AnyHashable, good(pkeyTestValue, pval.testValue) {
                        assert(ktype == nil || ktype == pkey.type)
                        ktype = pkey.type
                        assert(vtype == nil || vtype == pval.type)
                        vtype = pval.type

                        guard let actualKey = pkey.actualValue(L, k, key) as? AnyHashable else {
                            return nil
                        }
                        // Since LuaTableRef/LuaStringRef do not implement Hashable, we can ignore the need to resolve
                        // pkey. And pval only needs checking against LuaTableRef.
                        let innerTest = { good(pkeyTestValue, $0) }
                        if pval.type == .array {
                            if let array = pval.tableRef!.doResolveArray(test: innerTest) {
                                result[actualKey] = array
                                found = true
                            }
                        } else if pval.type == .dict {
                            if let dict = pval.tableRef!.doResolveDict(test: innerTest) {
                                result[actualKey] = dict
                                found = true
                            }
                        } else if let actualValue = pval.actualValue(L, v, val) {
                            result[actualKey] = actualValue
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

    struct PossibleValue {
        let type: TypeConstraint
        let stringRef: LuaStringRef? // Valid for .string .bytes .data
        let tableRef: LuaTableRef? // Valid for .array .dict
        let testValue: Any

        // Valid for .array and .dict, also in the case of .anyhashable used as an indicator that the value is a known
        // LuaTemporaryRef (avoiding the need for an additional dynamic cast).
        let ref: LuaTemporaryRef?

        init(type: TypeConstraint,
             stringRef: LuaStringRef? = nil,
             tableRef: LuaTableRef? = nil,
             testValue: Any? = nil) { // Only for type == .direct
            self.type = type
            self.stringRef = stringRef
            self.tableRef = tableRef
            self.ref = stringRef ?? tableRef
            switch type {
            case .dict: self.testValue = emptyAnyDict
            case .array: self.testValue = emptyAnyArray
            case .string: self.testValue = emptyString
            case .bytes: self.testValue = dummyBytes
#if !LUASWIFT_NO_FOUNDATION
            case .data: self.testValue = emptyData
#endif
            case .direct: self.testValue = testValue!
            case .luavalue: self.testValue = LuaValue.nilValue
            case .anyhashable: self.testValue = opaqueHashable
            }
        }

        func actualValue(_ L: LuaState, _ index: CInt, _ anyVal: Any) -> Any? {
            switch type {
            case .string: return stringRef!.toString()
            case .bytes: return stringRef!.toData()
#if !LUASWIFT_NO_FOUNDATION
            case .data: return Data(stringRef!.toData())
#endif
            case .array: fatalError("Can't call actualValue on an array")
            case .dict: fatalError("Can't call actualValue on a dict")
            case .direct: return anyVal
            case .luavalue: return L.ref(index: index)
            case .anyhashable:
                if let ref {
                    return ref.ref()
                } else if let anyHashable = anyVal as? AnyHashable {
                    return anyHashable
                } else {
                    // If the value is not Hashable and the type constraint is AnyHashable, then tovalue is documented
                    // to return a LuaValue. We could define this situation to return nil instead, both have merits
                    // but this makes casting to Dictionary slightly more useful, given that Lua dicts can use keys
                    // which Swift Dictionaries cannot.
                    return L.ref(index: index)
                }
            }
        }

        static func makePossibles(_ type: TypeConstraint?, _ index: CInt, _ val: Any) -> [PossibleValue] {
            var result: [PossibleValue] = []
            if let ref = val as? LuaStringRef {
                if type == nil || type == .anyhashable {
                    result.append(PossibleValue(type: .anyhashable, stringRef: ref))
                }
                if type == nil || type == .string {
                    result.append(PossibleValue(type: .string, stringRef: ref))
                }
                if type == nil || type == .bytes {
                    result.append(PossibleValue(type: .bytes, stringRef: ref))
                }
    #if !LUASWIFT_NO_FOUNDATION
                if type == nil || type == .data {
                    result.append(PossibleValue(type: .data, stringRef: ref))
                }
    #endif
                if type == nil || type == .luavalue {
                    result.append(PossibleValue(type: .luavalue)) // No need to cache the cast like with anyhashable
                }
            } else if let tableRef = val as? LuaTableRef {
                if type == nil || type == .anyhashable {
                    result.append(PossibleValue(type: .anyhashable, tableRef: tableRef))
                }
                // An array table can always be represented as a dictionary, but not vice versa, so put Dictionary first
                // so that an untyped top-level T (which will result in the first option being chosen) at least doesn't
                // lose information and behaves consistently.
                if type == nil || type == .dict {
                    result.append(PossibleValue(type: .dict, tableRef: tableRef))
                }
                if type == nil || type == .array {
                    result.append(PossibleValue(type: .array, tableRef: tableRef))
                }
                if type == nil || type == .luavalue {
                    result.append(PossibleValue(type: .luavalue)) // No need to cache the cast like with anyhashable
                }
            } else {
                if type == nil || type == .anyhashable {
                    result.append(PossibleValue(type: .anyhashable))
                }
                if type == nil || type == .direct {
                    result.append(PossibleValue(type: .direct, testValue: val))
                }
                if type == nil || type == .luavalue {
                    result.append(PossibleValue(type: .luavalue)) // No need to cache the cast like with anyhashable
                }
            }
            return result
        }
    }
}

fileprivate struct OpaqueType {}
fileprivate let opaqueValue = OpaqueType()

fileprivate struct OpaqueHashableType : Hashable {}
fileprivate let opaqueHashable = OpaqueHashableType()

fileprivate let emptyAnyArray = Array<Any>()
fileprivate let emptyAnyDict = Dictionary<AnyHashable, Any>()
fileprivate let emptyAnyHashableArray = Array<AnyHashable>()
fileprivate let emptyAnyHashableDict = Dictionary<AnyHashable, AnyHashable>()
fileprivate let emptyString = ""
fileprivate let dummyBytes: [UInt8] = [0] // Not empty in case [] casts overly broadly
#if !LUASWIFT_NO_FOUNDATION
fileprivate let emptyData = Data()
#endif

enum TypeConstraint {
    // string types
    case string // String
    case bytes // [UInt8]
#if !LUASWIFT_NO_FOUNDATION
    case data // Data
#endif
    // table types
    case array // Array
    case dict // Dictionary
    // others
    case direct // A concrete type
    case anyhashable // AnyHashable (or Any, in some contexts)
    case luavalue
}

extension TypeConstraint {
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
