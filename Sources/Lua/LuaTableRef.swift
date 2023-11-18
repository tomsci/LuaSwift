// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

/// Placeholder type used by ``Lua/Swift/UnsafeMutablePointer/toany(_:guessType:)`` when `guessType` is `false`.
public struct LuaTableRef {
    let L: LuaState!
    let index: CInt

    public init(L: LuaState!, index: CInt) {
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
        return doResolve(as: isArrayType(opt) ? .array : .dict, test: test) as? T
    }

    enum TableType {
        case array
        case dict
    }

    func doResolve(as tableType: TableType, test: (Any) -> Bool) -> Any? {
        switch tableType {
        case .array:
            return doResolveArray(test: test)
        case .dict:
            return doResolveDict(test: test)
        }
    }

    func doResolveArray(test: (Any) -> Bool) -> Any? {
        var result = Array<Any>()
        var testArray = Array<Any>()
        func good(_ val: Any, keepOnSuccess: Bool = false) -> Bool {
            testArray.append(val)
            let success = test(testArray)
            // Oddly removeLast seems to be faster than removeAll(keepingCapacity: true)
            testArray.removeLast()
            if success && keepOnSuccess {
                result.append(val)
            }
            return success
        }
        for _ in L.ipairs(index) {
            let value = L.toany(-1, guessType: false)! // toany cannot fail on a valid non-nil index
            if good(value, keepOnSuccess: true) {
                continue
            } else if let ref = value as? LuaStringRef {
                if let str = ref.toString() {
                    if good(str, keepOnSuccess: true) {
                        continue
                    }
                }
                // Otherwise try as data
                if !good(ref.toData(), keepOnSuccess: true) {
                    // Nothing works
                    return nil
                }
            } else if let ref = value as? LuaTableRef {
                let tableType: TableType
                if good(Array<Any>()) {
                    tableType = .array
                } else if good(Dictionary<AnyHashable, Any>()) {
                    tableType = .dict
                } else {
                    // T isn't happy with either an array or a table here, give up
                    return nil
                }
                if let val = ref.doResolve(as: tableType, test: { good($0) }) {
                    result.append(val)
                    assert(test(result)) // Shouldn't ever fail, but...
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
            let key = L.toany(k, guessType: false) as? AnyHashable
            let val = L.toany(v, guessType: false)!
            if let key, good(key, val, keepOnSuccess: true) {
                // Carry on
                continue
            }

            let possibleKeys = makePossibleKeys(L.toany(k, guessType: false)!)
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
            result.append(ref.toData())
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
            result.append(PossibleValue(value: ref.toData(), tableRef: nil, isDict: false, isArray: false))
        } else if let tableRef = val as? LuaTableRef {
            // An array table can always be represented as a dictionary, but not vice versa, so put Dictionary first
            // so that an untyped top-level T (which will result in the first option being chosen) at least doesn't
            // lose information and behaves consistently.
            result.append(PossibleValue(value: emptyAnyDict, tableRef: tableRef, isDict: true, isArray: false))
            result.append(PossibleValue(value: emptyAnyArray, tableRef: tableRef, isDict: false, isArray: true))
        }
        result.append(PossibleValue(value: val, tableRef: nil, isDict: false, isArray: false))
        return result
    }
}

fileprivate let emptyAnyArray = Array<Any>()
fileprivate let emptyAnyDict = Dictionary<AnyHashable, Any>()

fileprivate func isArrayType<T>(_: T?) -> Bool {
    if let _ = emptyAnyArray as? T {
        return true
    } else {
        return false
    }
}
