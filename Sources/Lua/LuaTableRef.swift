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

    internal func guessType() -> Any {
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

    internal func asAnyDictionary<ValueType>() -> [AnyHashable: ValueType]? {
        var result: [AnyHashable: ValueType] = [:]
        for (k, v) in L.pairs(index) {
            let key: AnyHashable? = L.tovalue(k)
            let value: ValueType? = L.tovalue(v)
            // This could still fail if there are keys that can't be hashed, return nil in that case
            if let key, let value {
                result[key] = value
            } else {
                return nil
            }
        }
        return result
    }

    public func resolve<T>() -> T? {
        let opt: T? = nil
        if isArrayType(opt) {
            if let arr: Array<Any> = doResolveArray(test: { $0 is T }) {
                return arr as? T
            } else {
                return nil
            }
        } else {
            if let dict: Dictionary<AnyHashable, Any> = doResolveDict(test: { $0 is T }) {
                return dict as? T
            } else {
                return nil
            }
        }
    }

    private func doResolveArray<ElementType>(test: (Array<ElementType>) -> Bool) -> Array<ElementType>? {
        var testArray = Array<ElementType>()
        func good(_ val: Any) -> Bool {
            guard let valAsElementType = val as? ElementType else {
                return false
            }
            testArray.append(valAsElementType)
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

            // Put this case at the start so as to optimise away a couple of casts to LuaStringRef and LuaTableRef
            // providing we know it's safe to do so, ie when acceptsAny is false so we can be sure this won't result in
            // eg stuffing a LuaStringRef into the result.
            if !acceptsAny && good(value) {
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
                    fatalError() // Handled above
                case .anyhashable:
                    result.append(ref.guessType()) // as per tovalue() docs
                case .dict, .array, .hashableDict, .hashableArray, .direct: // None of these are applicable for TypeConstraint(stringTest:)
                    fatalError()
                case .none: // TypeConstraint(stringTest:) failed to find any compatible type
                    return nil
                }
            } else if let ref = value as? LuaTableRef {
                if elementType == nil {
                    elementType = TypeConstraint(tableTest: { good($0) })
                }

                let resolvedVal: ElementType?
                switch elementType {
                case .array, .hashableArray:
                    if let arr: Array<ElementType> = ref.doResolveArray(test: { good($0) }) {
                        resolvedVal = arr as? ElementType // Can't ever fail otherwise good() wasn't doing its job
                    } else {
                        resolvedVal = nil
                    }
                case .dict, .hashableDict:
                    if let dict: Dictionary<AnyHashable, ElementType> = ref.doResolveDict(test: { good($0) }) {
                        resolvedVal = dict as? ElementType
                    } else {
                        resolvedVal = nil
                    }
                case .luavalue:
                    fatalError() // Handled above
                case .anyhashable:
                    if let anyDict: [AnyHashable: ElementType] = ref.asAnyDictionary() {
                        resolvedVal = anyDict as? ElementType
                    } else {
                        resolvedVal = nil
                    }
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
            } else if acceptsAny {
                result.append(value)
            } else {
                // Nothing from toany has made T happy, give up
                return nil
            }
        }
        return result as? Array<ElementType>
    }

    private func doResolveDict<ValueType>(test: (Dictionary<AnyHashable, ValueType>) -> Bool) -> Dictionary<AnyHashable, ValueType>? {
        var testDict = Dictionary<AnyHashable, ValueType>()
        func good(_ key: AnyHashable, _ val: Any) -> Bool {
            guard let valAsValueType = val as? ValueType else {
                return false
            }
            testDict[key] = valAsValueType
            let success = test(testDict)
            testDict.removeAll(keepingCapacity: true)
            return success
        }

        var result = Dictionary<AnyHashable, ValueType>()
        var ktype: TypeConstraint? = nil
        var vtype: TypeConstraint? = nil

        for (k, v) in L.pairs(index) {
            let key = L.toany(k, guessType: false)!
            let val = L.toany(v, guessType: false)!
            let possibleKeys = PossibleValue.makePossibles(constraint: ktype, value: key, hashableTables: true)
            let valueMustBeHashable = ValueType.self == AnyHashable.self
            let possibleValues = PossibleValue.makePossibles(constraint: vtype, value: val, hashableTables: valueMustBeHashable)
            var found = false
            for pkey in possibleKeys {
                for pval in possibleValues {
                    if let pkeyTestValue = pkey.testValue as? AnyHashable, good(pkeyTestValue, pval.testValue) {
                        assert(ktype == nil || ktype == pkey.type)
                        ktype = pkey.type
                        assert(vtype == nil || vtype == pval.type)
                        vtype = pval.type

                        let actualKey: AnyHashable?
                        switch pkey.type {
                        case .hashableDict:
                            let goodHashableKey: (Dictionary<AnyHashable, AnyHashable>) -> Bool = {
                                return good($0, pval.testValue)
                            }
                            actualKey = pkey.tableRef!.doResolveDict(test: goodHashableKey)
                        case .hashableArray:
                            let goodHashableKey: (Array<AnyHashable>) -> Bool = {
                                return good($0, pval.testValue)
                            }
                            actualKey = pkey.tableRef!.doResolveArray(test: goodHashableKey)
                        default:
                            actualKey = pkey.actualValue(L, k, key) as? AnyHashable
                        }

                        guard let actualKey else {
                            return nil
                        }
                        // Since LuaTableRef/LuaStringRef do not implement Hashable, we can ignore the need to resolve
                        // pkey. And pval only needs checking against LuaTableRef.
                        switch pval.type {
                        case .array, .hashableArray:
                            if let array: Array<ValueType> = pval.tableRef!.doResolveArray(test: { good(pkeyTestValue, $0) }) {
                                result[actualKey] = array as? ValueType
                                found = true
                            }
                        case .dict, .hashableDict:
                            if let dict: Dictionary<AnyHashable, ValueType> = pval.tableRef!.doResolveDict(test: { good(pkeyTestValue, $0) }) {
                                result[actualKey] = dict as? ValueType
                                found = true
                            }
                        default:
                            if let actualValue = pval.actualValue(L, v, val) {
                                result[actualKey] = actualValue as? ValueType
                                found = true
                            }
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

    private struct PossibleValue {
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
            case .hashableDict: self.testValue = emptyAnyHashableDict
            case .hashableArray: self.testValue = emptyAnyHashableArray
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
            case .array, .hashableArray: fatalError("Can't call actualValue on an array")
            case .dict, .hashableDict: fatalError("Can't call actualValue on a dict")
            case .direct: return anyVal
            case .luavalue: return L.ref(index: index)
            case .anyhashable:
                if let stringRef {
                    return stringRef.guessType()
                } else if let tableRef {
                    if let dict: Dictionary<AnyHashable, AnyHashable> = tableRef.asAnyDictionary() {
                        return dict
                    } else {
                        return nil
                    }
                } else if let anyHashable = anyVal as? AnyHashable {
                    return anyHashable
                } else {
                    // If the value is not Hashable and the type constraint is AnyHashable, then tovalue is documented
                    // to fail the conversion.
                    return nil
                }
            }
        }

        static func makePossibles(constraint type: TypeConstraint?, value: Any, hashableTables: Bool) -> [PossibleValue] {
            var result: [PossibleValue] = []
            if let ref = value as? LuaStringRef {
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
            } else if let tableRef = value as? LuaTableRef {
                if type == nil || type == .anyhashable {
                    result.append(PossibleValue(type: .anyhashable, tableRef: tableRef))
                }
                // An array table can always be represented as a dictionary, but not vice versa, so put Dictionary first
                // so that an untyped top-level T (which will result in the first option being chosen) at least doesn't
                // lose information and behaves consistently.
                if (!hashableTables && type == nil) || type == .dict {
                    result.append(PossibleValue(type: .dict, tableRef: tableRef))
                }
                if (hashableTables && type == nil) || type == .hashableDict {
                    result.append(PossibleValue(type: .hashableDict, tableRef: tableRef))
                }
                if (!hashableTables && type == nil) || type == .array {
                    result.append(PossibleValue(type: .array, tableRef: tableRef))
                }
                if (hashableTables && type == nil) || type == .hashableArray {
                    result.append(PossibleValue(type: .hashableArray, tableRef: tableRef))
                }
                if type == nil || type == .luavalue {
                    result.append(PossibleValue(type: .luavalue)) // No need to cache the cast like with anyhashable
                }
            } else {
                if type == nil || type == .anyhashable {
                    result.append(PossibleValue(type: .anyhashable))
                }
                if type == nil || type == .direct {
                    result.append(PossibleValue(type: .direct, testValue: value))
                }
                if type == nil || type == .luavalue {
                    result.append(PossibleValue(type: .luavalue)) // No need to cache the cast like with anyhashable
                }
            }
            return result
        }
    }
}

internal struct OpaqueType {}
internal let opaqueValue = OpaqueType()

internal struct OpaqueHashableType : Hashable {}
internal let opaqueHashable = OpaqueHashableType()

fileprivate let emptyAnyArray = Array<Any>()
fileprivate let emptyAnyDict = Dictionary<AnyHashable, Any>()
fileprivate let emptyAnyHashableArray = Array<AnyHashable>()
fileprivate let emptyAnyHashableDict = Dictionary<AnyHashable, AnyHashable>()
internal let emptyString = ""
internal let dummyBytes: [UInt8] = [0] // Not empty in case [] casts overly broadly
#if !LUASWIFT_NO_FOUNDATION
internal let emptyData = Data()
#endif

enum TypeConstraint {
    // string types
    case string // String
    case bytes // [UInt8]
#if !LUASWIFT_NO_FOUNDATION
    case data // Data
#endif
    // table types
    case array // Array<Any>
    case dict // Dictionary<AnyHashable, Any>
    case hashableArray // Array<AnyHashable>
    case hashableDict // Dictionary<AnyHashable, AnyHashable>
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
        } else if test(emptyAnyHashableArray) {
            self = .hashableArray
        } else if test(emptyAnyHashableDict) {
            self = .hashableDict
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

extension Dictionary where Key == AnyHashable, Value == Any {

    /// Convert a dictionary returned by `tovalue<Any>()` to an array, if possible.
    ///
    /// ``Lua/Swift/UnsafeMutablePointer/tovalue(_:)`` can return Lua tables as a `Dictionary<AnyHashable, Any>` if `T`
    /// was `Any` (and then the value was subsequently cast back to `Dictionary<AnyHashable, Any>`). If such a
    /// Dictionary contains only integer keys starting from 1 with no gaps (or is empty), this function will convert it
    /// to an `Array<Any>` (converting the indexes from 1-based to zero-based in the process). Any other keys present
    /// in the Dictionary will result in `nil` being returned.
    ///
    /// This function is also defined on `Dictionary<AnyHashable, AnyHashable>`, see ``luaTableToArray()-3ngmn``.
    public func luaTableToArray() -> [Any]? {
        var intKeys: [Int] = []
        for (k, _) in self {
            if let intKey = k as? Int, intKey > 0 {
                intKeys.append(intKey)
            } else {
                // Non integer key found, doom
                return nil
            }
        }

        // Now check all those integer keys are a sequence and build the result
        intKeys.sort()
        var result: [Any] = []
        var i = 1
        while i <= intKeys.count {
            if intKeys[i-1] == i {
                result.append(self[i]!)
                i = i + 1
            } else {
                // Gap in the indexes, not a sequence
                return nil
            }
        }

        return result
    }
}

extension Dictionary where Key == AnyHashable, Value == AnyHashable {

    /// Convert a dictionary returned by `tovalue<AnyHashable>()` to an array, if possible.
    ///
    /// ``Lua/Swift/UnsafeMutablePointer/tovalue(_:)`` can return Lua tables as a `Dictionary<AnyHashable, AnyHashable>`
    /// if `T` was `AnyHashable` (and then the value was subsequently cast back to `Dictionary<AnyHashable,
    /// AnyHashable>`). If such a Dictionary contains only integer keys starting from 1 with no gaps (or is empty),
    /// this function will convert it to an `Array<AnyHashable>` (converting the indexes from 1-based to zero-based in
    /// the process). Any other keys present in the Dictionary will result in `nil` being returned.
    ///
    /// This function is also defined on `Dictionary<AnyHashable, Any>`, see ``luaTableToArray()-7jqqs``.
    public func luaTableToArray() -> [AnyHashable]? {
        var intKeys: [Int] = []
        for (k, _) in self {
            if let intKey = k as? Int, intKey > 0 {
                intKeys.append(intKey)
            } else {
                // Non integer key found, doom
                return nil
            }
        }

        // Now check all those integer keys are a sequence and build the result
        intKeys.sort()
        var result: [AnyHashable] = []
        var i = 1
        while i <= intKeys.count {
            if intKeys[i-1] == i {
                result.append(self[i]!)
                i = i + 1
            } else {
                // Gap in the indexes, not a sequence
                return nil
            }
        }

        return result
    }
}
