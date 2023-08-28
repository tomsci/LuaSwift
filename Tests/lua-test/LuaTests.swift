// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

import XCTest
import Lua
import CLua

fileprivate func dummyFn(_ L: LuaState!) -> CInt {
    return 0
}

class DeinitChecker {
    let deinitPtr: UnsafeMutablePointer<Int>
    init(deinitPtr: UnsafeMutablePointer<Int>) {
        self.deinitPtr = deinitPtr
    }
    deinit {
        deinitPtr.pointee = deinitPtr.pointee + 1
    }
}

final class LuaTests: XCTestCase {

    var L: LuaState!

    override func setUpWithError() throws {
        L = LuaState(libraries: [])
    }

    override func tearDownWithError() throws {
        if let L {
            L.close()
        }
        L = nil
    }

    func testSafeLibraries() {
        L.openLibraries(.safe)
        let unsafeLibs = ["os", "io", "package", "debug"]
        for lib in unsafeLibs {
            let t = L.getglobal(lib)
            XCTAssertEqual(t, .nilType)
            L.pop()
        }
        XCTAssertEqual(L.gettop(), 0)
    }

    func test_pcall() throws {
        L.getglobal("type")
        L.push(123)
        try L.pcall(nargs: 1, nret: 1)
        XCTAssertEqual(L.gettop(), 1)
        XCTAssertEqual(L.tostring(-1), "number")
        L.pop()
    }

    func test_pcall_throw() throws {
        var expectedErr: LuaCallError? = nil
        do {
            L.getglobal("error")
            try L.pcall("Deliberate error", traceback: false)
        } catch let error as LuaCallError {
            expectedErr = error
        }
        // Put L out of scope here, to make sure err.description still works
        L.close()
        L = nil
    
        XCTAssertNotNil(expectedErr)
        XCTAssertEqual(expectedErr!.description, "Deliberate error")
    }

    func test_toint() {
        L.push(1234) // 1
        L.push(true) // 2
        L.push("hello") // 3
        L.push(123.456) // 4
        L.pushnil() // 5
        L.push(dummyFn) // 6
        XCTAssertEqual(L.toint(1), 1234)
        XCTAssertEqual(L.toint(2), nil)
        XCTAssertEqual(L.toint(3), nil)
        XCTAssertEqual(L.toint(4), nil)
        XCTAssertEqual(L.toint(5), nil)
        XCTAssertEqual(L.toint(6), nil)
    }

    func test_tonumber() {
        L.push(1234) // 1
        L.push(true) // 2
        L.push("hello") // 3
        L.push(123.456) // 4
        L.pushnil() // 5
        L.push(dummyFn) // 6
        XCTAssertEqual(L.tonumber(1), 1234)
        XCTAssertEqual(L.tonumber(2), nil)
        XCTAssertEqual(L.tonumber(3), nil)
        XCTAssertEqual(L.tonumber(4), 123.456)
        XCTAssertEqual(L.tonumber(5), nil)
        XCTAssertEqual(L.toint(6), nil)
    }

    func test_tobool() {
        L.push(1234) // 1
        L.push(true) // 2
        L.push(false) // 3
        L.pushnil() // 4
        L.push(dummyFn) // 5
        XCTAssertEqual(L.toboolean(1), true)
        XCTAssertEqual(L.toboolean(2), true)
        XCTAssertEqual(L.toboolean(3), false)
        XCTAssertEqual(L.toboolean(4), false)
        XCTAssertEqual(L.toboolean(5), true)
    }

    func test_tostring() {
        L.push("Hello")
        L.push("A ü†ƒ8 string")
        L.push(1234)

        XCTAssertEqual(L.tostring(1, convert: false), "Hello")
        XCTAssertEqual(L.tostring(2, convert: false), "A ü†ƒ8 string")
        XCTAssertEqual(L.tostring(3, convert: false), nil)
        XCTAssertEqual(L.tostring(3, convert: true), "1234")

        XCTAssertEqual(L.tostringUtf8(1, convert: false), "Hello")
        XCTAssertEqual(L.tostringUtf8(2, convert: false), "A ü†ƒ8 string")
        XCTAssertEqual(L.tostringUtf8(3, convert: false), nil)
        XCTAssertEqual(L.tostringUtf8(3, convert: true), "1234")

        L.push(utf8String: "A ü†ƒ8 string")
        XCTAssertTrue(L.rawequal(2, 4))
        L.pop()

#if !LUASWIFT_NO_FOUNDATION
        L.push(string: "A ü†ƒ8 string", encoding: .utf8)
        XCTAssertTrue(L.rawequal(2, 4))
        L.pop()

        L.push(string: "îsø", encoding: .isoLatin1)

        XCTAssertEqual(L.tostring(1, encoding: .utf8, convert: false), "Hello")
        XCTAssertEqual(L.tostring(2, encoding: .utf8, convert: false), "A ü†ƒ8 string")
        XCTAssertEqual(L.tostring(3, encoding: .utf8, convert: false), nil)
        XCTAssertEqual(L.tostring(3, encoding: .utf8, convert: true), "1234")
        XCTAssertEqual(L.tostring(4, convert: true), nil) // not valid in the default encoding (ie UTF-8)
        XCTAssertEqual(L.tostring(4, encoding: .isoLatin1, convert: false), "îsø")

        L.setDefaultStringEncoding(.stringEncoding(.isoLatin1))
        XCTAssertEqual(L.tostring(4), "îsø") // this should now succeed
#endif
    }

    func test_ipairs() {
        let arr = [11, 22, 33, 44]
        L.push(arr) // Because Array<Int> conforms to Array<T: Pushable> which is itself Pushable
        var expected: lua_Integer = 0
        for i in L.ipairs(1) {
            expected = expected + 1
            XCTAssertEqual(i, expected)
            XCTAssertEqual(L.gettop(), 2)
            XCTAssertEqual(L.tointeger(2), expected * 11)
        }
        XCTAssertEqual(expected, 4)
        XCTAssertEqual(L.gettop(), 1)

        // Now check that a table with nils in is also handled correctly
        expected = 0
        L.pushnil()
        lua_rawseti(L, -2, 3) // arr[3] = nil
        for i in L.ipairs(1) {
            expected = expected + 1
            XCTAssertEqual(i, expected)
            XCTAssertEqual(L.gettop(), 2)
            XCTAssertEqual(L.tointeger(2), expected * 11)
        }
        XCTAssertEqual(expected, 2)
        XCTAssertEqual(L.gettop(), 1)
    }

    func test_LuaValue_ipairs_table() throws {
        let array = L.ref(any: [11, 22, 33, 44])
        var expected: lua_Integer = 0
        for (i, val) in try array.ipairs() {
            expected = expected + 1
            XCTAssertEqual(i, expected)
            XCTAssertEqual(L.gettop(), 0)
            XCTAssertEqual(val.tointeger(), expected * 11)
        }
        XCTAssertEqual(expected, 4)
        XCTAssertEqual(L.gettop(), 0)
    }

    func test_LuaValue_ipairs_mt() throws {
        // This errors on 5th index, thus appears to be an array of 4 items to ipairs
        try L.load(string: """
            local data = { 11, 22, 33, 44, 55, 66 }
            tbl = setmetatable({}, { __index = function(_, i)
                if i == 5 then
                    error("NOPE!")
                else
                    return data[i]
                end
            end})
            return tbl
            """)
        try L.pcall(nargs: 0, nret: 1)
        let array = L.popref()
        var expected: lua_Integer = 0
        for (i, val) in try array.ipairs() {
            expected = expected + 1
            XCTAssertEqual(i, expected)
            XCTAssertEqual(L.gettop(), 0)
            XCTAssertEqual(val.tointeger(), expected * 11)
        }
        XCTAssertEqual(expected, 4)
        XCTAssertEqual(L.gettop(), 0)
    }

    func test_LuaValue_ipairs_errors() throws {
        let bad_ipairs: (LuaValue) throws -> Void = { val in
            for _ in try val.ipairs() {
                XCTFail("Shouldn't get here!")
            }
        }
        XCTAssertThrowsError(try bad_ipairs(.nilValue(L)), "", { err in
            XCTAssertEqual(err as? LuaValueError, .nilValue)
        })
        XCTAssertThrowsError(try bad_ipairs(L.ref(any: 123)), "", { err in
            XCTAssertEqual(err as? LuaValueError, .notIndexable)
        })
    }

    func test_LuaValue_for_ipairs_errors() throws {
        let bad_ipairs: (LuaValue) throws -> Void = { val in
            try val.for_ipairs() { _, _ in
                XCTFail("Shouldn't get here!")
                return false
            }
        }
        XCTAssertThrowsError(try bad_ipairs(.nilValue(L)), "", { err in
            XCTAssertEqual(err as? LuaValueError, .nilValue)
        })
        XCTAssertThrowsError(try bad_ipairs(L.ref(any: 123)), "", { err in
            XCTAssertEqual(err as? LuaValueError, .notIndexable)
        })

        try L.load(string: "return setmetatable({}, { __index = function() error('DOOM!') end })")
        try L.pcall(nargs: 0, nret: 1)
        XCTAssertThrowsError(try bad_ipairs(L.popref()), "", { err in
            XCTAssertNotNil(err as? LuaCallError)
        })

    }

    func test_pairs() {
        var dict = [
            "aaa": 111,
            "bbb": 222,
            "ccc": 333,
        ]
        L.push(dict)
        for (k, v) in L.pairs(1) {
            XCTAssertTrue(k > 1)
            XCTAssertTrue(v > 1)
            let key = L.tostring(k)
            let val = L.toint(v)
            XCTAssertNotNil(key)
            XCTAssertNotNil(val)
            let foundVal = dict.removeValue(forKey: key!)
            XCTAssertEqual(val, foundVal)
        }
        XCTAssertTrue(dict.isEmpty) // All entries should have been removed by the pairs loop
    }

    func test_for_ipairs() throws {
        let arr = [11, 22, 33, 44, 55, 66]
        L.push(arr)
        var expected_i: lua_Integer = 0
        try L.for_ipairs(-1) { i in
            expected_i = expected_i + 1
            XCTAssertEqual(i, expected_i)
            XCTAssertEqual(L.toint(-1), arr[Int(i-1)])
            return i <= 4 // Test we can bail early
        }
        XCTAssertEqual(expected_i, 5)

        // Check we're actually using non-raw accesses
        try L.load(string: """
            local data = { 11, 22, 33, 44 }
            tbl = setmetatable({}, { __index = data })
            return tbl
            """)
        try L.pcall(nargs: 0, nret: 1)
        expected_i = 1
        try L.for_ipairs(-1) { i in
            XCTAssertEqual(i, expected_i)
            expected_i = expected_i + 1
            XCTAssertEqual(L.toint(-1), arr[Int(i-1)])
            return true
        }

        // Check we can error from an indexing operation and not explode
        try L.load(string: """
            local data = { 11, 22, 33, 44 }
            tbl = setmetatable({}, {
                __index = function(_, idx)
                    if idx == 3 then
                        error("I'm an erroring __index")
                    else
                        return data[idx]
                    end
                end
            })
            return tbl
            """)
        try L.pcall(nargs: 0, nret: 1)
        var last_i: lua_Integer = 0
        let shouldError = {
            try self.L.for_ipairs(-1) { i in
                last_i = i
                return true
            }
        }
        XCTAssertThrowsError(try shouldError(), "", { err in
            XCTAssertNotNil(err as? LuaCallError)
        })
        XCTAssertEqual(last_i, 2)
    }

    func test_for_pairs_raw() throws {
        var dict = [
            "aaa": 111,
            "bbb": 222,
            "ccc": 333,
        ]
        L.push(dict)
        try L.for_pairs(1) { k, v in
            let key = L.tostring(k)!
            let val = L.toint(v)!
            let foundVal = dict.removeValue(forKey: key)
            XCTAssertEqual(val, foundVal)
            return true
        }
        XCTAssertTrue(dict.isEmpty) // All entries should have been removed by the pairs loop
    }

    func test_for_pairs_mt() throws {
        var dict = [
            "aaa": 111,
            "bbb": 222,
            "ccc": 333,
            "ddd": 444,
        ]

        // Check we're actually using non-raw accesses
        try L.load(string: """
            local dict = ...
            tbl = setmetatable({}, {
                __index = dict,
                __pairs = function(tbl)
                    return next, dict, nil
                end,
            })
            return tbl
            """)
        L.push(dict)
        try L.pcall(nargs: 1, nret: 1)

        try L.for_pairs(-1) { k, v in
            let key = L.tostring(k)
            let val = L.toint(v)
            XCTAssertNotNil(key)
            XCTAssertNotNil(val)
            let foundVal = dict.removeValue(forKey: key!)
            XCTAssertEqual(val, foundVal)
            return true
        }
        XCTAssertTrue(dict.isEmpty) // All entries should have been removed by the pairs loop
    }

    func test_LuaValue_pairs_raw() throws {
        var dict = [
            "aaa": 111,
            "bbb": 222,
            "ccc": 333,
        ]
        let dictValue = L.ref(any: dict)
        for (k, v) in try dictValue.pairs() {
            let key = k.tostring()
            let val = v.toint()
            XCTAssertNotNil(key)
            XCTAssertNotNil(val)
            let foundVal = dict.removeValue(forKey: key!)
            XCTAssertEqual(val, foundVal)
        }
        XCTAssertTrue(dict.isEmpty) // All entries should have been removed by the pairs loop
    }

    func test_LuaValue_pairs_mt() throws {
        var dict = [
            "aaa": 111,
            "bbb": 222,
            "ccc": 333,
            "ddd": 444,
        ]

        // Check we're actually using non-raw accesses
        try L.load(string: """
            local dict = ...
            tbl = setmetatable({}, {
                __index = dict,
                __pairs = function(tbl)
                    return next, dict, nil
                end,
            })
            return tbl
            """)
        L.push(dict)
        try L.pcall(nargs: 1, nret: 1)
        let dictValue = L.popref()
        
        for (k, v) in try dictValue.pairs() {
            let key = k.tostring()
            let val = v.toint()
            XCTAssertNotNil(key)
            XCTAssertNotNil(val)
            let foundVal = dict.removeValue(forKey: key!)
            XCTAssertEqual(val, foundVal)
        }
        XCTAssertTrue(dict.isEmpty) // All entries should have been removed by the pairs loop
    }

    func test_LuaValue_for_pairs_mt() throws {
        var dict = [
            "aaa": 111,
            "bbb": 222,
            "ccc": 333,
            "ddd": 444,
        ]

        // Check we're actually using non-raw accesses
        try L.load(string: """
            local dict = ...
            return setmetatable({}, {
                __pairs = function()
                    return next, dict, nil
                end,
            })
            """)
        L.push(dict)
        try L.pcall(nargs: 1, nret: 1)
        let dictValue = L.popref()

        for (k, v) in try dictValue.pairs() {
            let key = k.tostring()
            let val = v.toint()
            XCTAssertNotNil(key)
            XCTAssertNotNil(val)
            let foundVal = dict.removeValue(forKey: key!)
            XCTAssertEqual(val, foundVal)
        }
        XCTAssertTrue(dict.isEmpty) // All entries should have been removed by the pairs loop

    }

    func test_pushuserdata() {
        struct Foo : Equatable {
            let intval: Int
            let strval: String
        }
        L.registerMetatable(for: Foo.self, functions: [:])
        let val = Foo(intval: 123, strval: "abc")
        L.push(userdata: val)
        XCTAssertEqual(L.type(1), .userdata)

        // Check push(any:) handles it as a userdata too
        L.push(any: val)
        XCTAssertEqual(L.type(2), .userdata)
        L.pop()

        // Test toany
        let anyval = L.toany(1, guessType: false)
        XCTAssertEqual(anyval as? Foo, val)

        // Test the magic that tovalue does on top of toany
        let valFromLua: Foo? = L.tovalue(1)
        XCTAssertEqual(valFromLua, val)

        L.pop()
    }

    // Tests that objects deinit correctly when pushed with toany and GC'd by Lua
    func test_pushuserdata_instance() {
        var deinited = 0
        var val: DeinitChecker? = DeinitChecker(deinitPtr: &deinited)
        XCTAssertEqual(deinited, 0)

        L.registerMetatable(for: DeinitChecker.self, functions: [:])
        L.push(userdata: val!)
        L.push(any: val!)
        var userdataFromPushUserdata: DeinitChecker? = L.touserdata(1)
        var userdataFromPushAny: DeinitChecker? = L.touserdata(2)
        XCTAssertIdentical(userdataFromPushUserdata, userdataFromPushAny)
        XCTAssertIdentical(userdataFromPushUserdata, val)
        L.pop() // We only need one ref Lua-side
        userdataFromPushAny = nil
        userdataFromPushUserdata = nil
        val = nil
        // Should not have destructed at this point, as reference still held by Lua
        L.collectgarbage()
        XCTAssertEqual(deinited, 0)
        L.pop()
        L.collectgarbage() // val should now destruct
        XCTAssertEqual(deinited, 1)
    }

    func test_registerMetatable() throws {
        class SomeClass {
            var member: String? = nil
        }
        L.registerMetatable(for: SomeClass.self, functions: [
            "__call": { (L: LuaState!) -> CInt in
                guard let obj: SomeClass = L.touserdata(1) else {
                    fatalError("Shouldn't happen")
                }
                obj.member = L.tostring(2)
                return 0
            }
        ])
        let val = SomeClass()
        L.push(userdata: val)
        try L.pcall("A string arg")
        XCTAssertEqual(val.member, "A string arg")
    }

    func testClasses() throws {
        // "outer Foo"
        class Foo {
            var str: String?
        }
        let f = Foo()
        L.registerMetatable(for: Foo.self, functions: ["__call": { (L: LuaState!) -> CInt in
            let f: Foo? = L.touserdata(1)
            // Above would have failed if we get called with an innerfoo
            XCTAssertNotNil(f)
            f!.str = L.tostring(2)
            return 0
        }])
        L.push(userdata: f)

        if true {
            // A different Foo ("inner Foo")
            class Foo {
                var str: String?
            }
            L.registerMetatable(for: Foo.self, functions: ["__call": { (L: LuaState!) -> CInt in
                let f: Foo? = L.touserdata(1)
                // Above would have failed if we get called with an outerfoo
                XCTAssertNotNil(f)
                f!.str = L.tostring(2)
                return 0
            }])
            let g = Foo()
            L.push(userdata: g)

            try L.pcall("innerfoo") // pops g
            try L.pcall("outerfoo") // pops f

            XCTAssertEqual(g.str, "innerfoo")
            XCTAssertEqual(f.str, "outerfoo")
        }
    }

    func test_pushany() {
        L.push(any: 1234)
        XCTAssertEqual(L.toany(1) as? Int, 1234)
        L.pop()

        L.push(any: "string")
        XCTAssertNil(L.toany(1, guessType: false) as? String)
        XCTAssertNotNil(L.toany(1, guessType: true) as? String)
        XCTAssertNotNil(L.toany(1, guessType: false) as? LuaStringRef)
        L.pop()

        // This is directly pushable (because Int is)
        let intArray = [11, 22, 33]
        L.push(any: intArray)
        XCTAssertEqual(L.type(1), .table)
        L.pop()

        struct Foo {
            let val: String
        }
        L.registerMetatable(for: Foo.self, functions: [:])
        let fooArray = [Foo(val: "a"), Foo(val: "b")]
        L.push(any: fooArray)
        XCTAssertEqual(L.type(1), .table)
        let guessAnyArray = L.toany(1, guessType: true) as? Array<Any>
        XCTAssertNotNil(guessAnyArray)
        XCTAssertEqual((guessAnyArray?[0] as? Foo)?.val, "a")
        let typedArray = guessAnyArray as? Array<Foo>
        XCTAssertNotNil(typedArray)

        let arr: [Foo]? = L.tovalue(1)
        XCTAssertNotNil(arr)
        L.pop()
    }

    func test_pushany_table() {
        let stringArray = ["abc", "def"]
        L.push(any: stringArray)
        let stringArrayResult: [String]? = L.tovalue(1)
        XCTAssertEqual(stringArrayResult, stringArray)
        L.pop()

        let stringArrayArray = [["abc", "def"], ["123"]]
        L.push(any: stringArrayArray)
        let stringArrayArrayResult: [[String]]? = L.tovalue(1)
        XCTAssertEqual(stringArrayArrayResult, stringArrayArray)
        L.pop()

        let intBoolDict = [ 1: true, 2: false, 3: true ]
        L.push(any: intBoolDict)
        let intBoolDictResult: [Int: Bool]? = L.tovalue(1)
        XCTAssertEqual(intBoolDictResult, intBoolDict)
        L.pop()

        let stringDict = ["abc": "ABC", "def": "DEF"]
        L.push(any: stringDict)
        let stringDictResult: [String: String]? = L.tovalue(1)
        XCTAssertEqual(stringDictResult, stringDict)
        L.pop()

        let arrayDictDict = [["abc": [1: "1", 2: "2"], "def": [5: "5", 6: "6"]]]
        L.push(any: arrayDictDict)
        let arrayDictDictResult: [[String : [Int : String]]]? = L.tovalue(1)
        XCTAssertEqual(arrayDictDictResult, arrayDictDict)
        L.pop()

        let intDict = [11: [], 22: ["22a", "22b"], 33: ["3333"]]
        L.push(any: intDict)
        let intDictResult: [Int: [String]]? = L.tovalue(1)
        XCTAssertEqual(intDictResult, intDict)
    }

    func test_push_closure() throws {
        var called = false
        L.push(closure: {
            called = true
        })
        try L.pcall()
        XCTAssertTrue(called)

        L.push(closure: {
            return "Void->String closure"
        })
        XCTAssertEqual(try L.pcall(), "Void->String closure")

        let c = { (val: String?) -> String in
            let v = val ?? "no"
            return "\(v) result"
        }
        L.push(closure: c)
        let result: String? = try L.pcall("call")
        XCTAssertEqual(result, "call result")

        L.push(closure: c)
        XCTAssertThrowsError(try L.pcall(1234, traceback: false), "", { err in
            XCTAssertEqual((err as? LuaCallError)?.errorString,
                           "Type of argument 1 (number) does not match type required by Swift closure (String)")
        })

    }

    func test_push_any_closure() throws {
        var called = false
        let voidVoidClosure = {
            called = true
        }
        L.push(any: voidVoidClosure)
        try L.pcall()
        XCTAssertTrue(called)

        called = false
        let voidAnyClosure = { () throws -> Any? in
            called = true
            return nil
        }
        L.push(any: voidAnyClosure)
        try L.pcall()
        XCTAssertTrue(called)
    }

    func test_extension_4arg_closure() throws {
        // Test that more argument overloads of push(closure:) can be implemented if required by code not in the Lua
        // package.
        func push<Arg1, Arg2, Arg3, Arg4>(closure: @escaping (Arg1?, Arg2?, Arg3?, Arg4?) throws -> Any?) {
            L.push(closureWrapper: { L in
                let arg1: Arg1? = try L.checkClosureArgument(index: 1)
                let arg2: Arg2? = try L.checkClosureArgument(index: 2)
                let arg3: Arg3? = try L.checkClosureArgument(index: 3)
                let arg4: Arg4? = try L.checkClosureArgument(index: 4)
                L.push(any: try closure(arg1, arg2, arg3, arg4))
            })
        }
        var gotArg4: String? = nil
        push(closure: { (arg1: Bool?, arg2: Int?, arg3: String?, arg4: String?) in
            gotArg4 = arg4
        })
        try L.pcall(true, 0, nil, "woop")
        XCTAssertEqual(gotArg4, "woop")
    }

    func testNonHashableTableKeys() {
        struct NonHashable {
            let nope = true
        }
        L.registerMetatable(for: NonHashable.self, functions: [:])
        lua_newtable(L)
        L.push(userdata: NonHashable())
        L.push(true)
        lua_settable(L, -3)
        let tbl = L.toany(1, guessType: true) as? [LuaValue: Bool]
        XCTAssertNotNil(tbl)
    }

    func testAnyHashable() {
        // Just to make sure casting to AnyHashable behaves as expected
        let x: Any = 1
        XCTAssertNotNil(x as? AnyHashable)
        struct NonHashable {}
        let y: Any = NonHashable()
        XCTAssertNil(y as? AnyHashable)
    }

    func testForeignUserdata() {
        // Tests that a userdata not set via pushuserdata (and thus, doesn't necessarily contain an `Any`) does not
        // crash or return anything if you attempt to access it via touserdata().
        let _ = lua_newuserdatauv(L, MemoryLayout<Any>.size, 0)
        let bad: Any? = L.touserdata(-1)
        XCTAssertNil(bad)
    }

    func test_ref() {
        var ref: LuaValue! = L.ref(any: "hello")
        XCTAssertEqual(ref.type, .string)
        XCTAssertEqual(ref.toboolean(), true)
        XCTAssertEqual(ref.tostring(), "hello")
        XCTAssertEqual(L.gettop(), 0)

        ref = .nilValue(L)
        XCTAssertEqual(ref.type, .nilType)

        ref = L.ref(any: nil)
        XCTAssertEqual(ref.type, .nilType)

        // Check it can correctly keep hold of a ref to a Swift object
        var deinited = 0
        var obj: DeinitChecker? = DeinitChecker(deinitPtr: &deinited)
        L.registerMetatable(for: DeinitChecker.self, functions: [:])
        ref = L.ref(any: obj!)

        XCTAssertIdentical(ref.toany() as? AnyObject, obj)

        XCTAssertNotNil(ref)
        obj = nil
        XCTAssertEqual(deinited, 0) // reference from userdata on stack
        L.settop(0)
        L.collectgarbage()
        XCTAssertEqual(deinited, 0) // reference from ref
        ref = nil
        L.collectgarbage()
        XCTAssertEqual(deinited, 1) // no more references
    }

    func test_ref_scoping() {
        var ref: LuaValue? = L.ref(any: "hello")
        XCTAssertEqual(ref!.type, .string) // shut up compiler complaining about unused ref
        L.close()
        // The act of nilling this will cause a crash if the close didn't nil ref.L
        ref = nil

        L = nil // make sure teardown doesn't try to close it again
    }

    func test_ref_get() throws {
        let strType = try L.globals["type"].pcall("foo").tostring()
        XCTAssertEqual(strType, "string")

        let nilType = try L.globals.get("type").pcall(nil).tostring()
        XCTAssertEqual(nilType, "nil")

        let arrayRef = L.ref(any: [11,22,33,44])
        XCTAssertEqual(arrayRef[1].toint(), 11)
        XCTAssertEqual(arrayRef[4].toint(), 44)
        XCTAssertEqual(try arrayRef.len, 4)
    }

    func test_ref_get_complexMetatable() throws {
        struct IndexableValue {}
        L.registerMetatable(for: IndexableValue.self, functions: [
            "__index": { L in
                return 1 // Ie just return whatever the key name was
            }
        ])
        let ref = L.ref(any: IndexableValue())
        XCTAssertEqual(try ref.get("woop").tostring(), "woop")

        // Now make ref the __index of another userdata
        // This didn't work with the original implementation of checkIndexable()

        lua_newuserdatauv(L, 4, 0) // will become udref
        lua_newtable(L) // udref's metatable
        L.setfield("__index", ref)
        lua_setmetatable(L, -2) // pops metatable
        // udref is now a userdata with an __index metafield that points to ref
        let udref = L.ref(index: -1)
        XCTAssertEqual(try udref.get("woop").tostring(), "woop")
    }

    func test_ref_chaining() throws {
        L.openLibraries([.string])
        let result = try L.globals.get("type").pcall(L.globals["print"]).pcall(member: "sub", 1, 4).tostring()
        XCTAssertEqual(result, "func")
    }

    func test_ref_errors() throws {
        L.openLibraries([.string])

        XCTAssertThrowsError(try L.globals["nope"](), "", { err in
            XCTAssertEqual(err as? LuaValueError, .nilValue)
        })

        XCTAssertThrowsError(try L.globals["string"](), "", { err in
            XCTAssertEqual(err as? LuaValueError, .notCallable)
        })

        XCTAssertThrowsError(try L.globals["type"].get("nope"), "", { err in
            XCTAssertEqual(err as? LuaValueError, .notIndexable)
        })

        XCTAssertThrowsError(try L.globals.pcall(member: "nonexistentfn"), "", { err in
            XCTAssertEqual(err as? LuaValueError, .nilValue)
        })

        XCTAssertThrowsError(try L.globals["type"].pcall(member: "nonexistentfn"), "", { err in
            XCTAssertEqual(err as? LuaValueError, .notIndexable)
        })
    }

    func test_ref_set() throws {
        L.globals["foo"] = L.ref(any: 123)
        XCTAssertEqual(L.globals["foo"].toint(), 123)
    }

    func test_nil() throws {
        XCTAssertEqual(L.type(1), nil)
        L.pushnil()
        XCTAssertEqual(L.type(1), .nilType)
        L.pop()
        XCTAssertEqual(L.type(1), nil)

        L.getglobal("select")
        let sel1: Bool? = try L.pcall(1, false, nil, "str")
        XCTAssertEqual(sel1, false)
        L.getglobal("select")
        let sel2: Any? = try L.pcall(2, false, nil, "str")
        XCTAssertNil(sel2)
        L.getglobal("select")
        let sel3: String? = try L.pcall(3, false, nil, "str")
        XCTAssertEqual(sel3, "str")
    }

    func test_tovalue_anynil() {

        L.push(true)
        let anyTrue: Any? = L.tovalue(1)
        XCTAssertEqual(anyTrue as? Bool?, true)
        L.pop()

        L.pushnil()
        let anyNil: Any? = L.tovalue(1)
        XCTAssertNil(anyNil)
    }

    func test_load_file() {
        XCTAssertThrowsError(try L.load(file: "nopemcnopeface"), "", { err in
            XCTAssertEqual(err as? LuaLoadError, .fileNotFound)
        })
    }

    func test_load() throws {
        try L.load(string: "return 'hello world'")
        try L.pcall(nargs: 0, nret: 1)
        XCTAssertEqual(L.tostring(-1), "hello world")

        let asArray: [UInt8] = "return 'hello world'".map { $0.asciiValue! }
        try L.load(data: asArray, name: "Hello")
        try L.pcall(nargs: 0, nret: 1)
        XCTAssertEqual(L.tostring(-1), "hello world")

        XCTAssertThrowsError(try L.load(string: "woop woop"), "", { err in
            let expected = #"[string "?"]:1: syntax error near 'woop'"#
            XCTAssertEqual((err as? LuaLoadError), .parseError(expected))
            XCTAssertEqual((err as CustomStringConvertible).description, "LuaLoadError.parseError(\(expected))")
            XCTAssertEqual(err.localizedDescription, "LuaLoadError.parseError(\(expected))")
        })

        XCTAssertThrowsError(try L.load(string: "woop woop", name: "@nope.lua"), "", { err in
            let expected = "nope.lua:1: syntax error near 'woop'"
            XCTAssertEqual((err as? LuaLoadError), .parseError(expected))
        })
    }

    func test_setModules() throws {
        let mod = """
            print("Hello from module land!")
            return "hello"
            """.map { $0.asciiValue! }
        // To be extra awkward, we call addModules before opening package (which sets up the package loaders) to
        // make sure that our approach works with that
        L.setModules(["test": mod], mode: .text)
        L.openLibraries([.package])
        let ret = try L.globals["require"]("test")
        XCTAssertEqual(ret.tostring(), "hello")
    }

    func test_lua_sources_requiref() throws {
        let lua_sources = [
            "test": """
                print("Hello from module land!")
                return "hello"
                """.map { $0.asciiValue! }
        ]
        try L.requiref(name: "test") {
            try L.load(data: lua_sources["test"]!, name: "test", mode: .text)
        }
        XCTAssertEqual(L.globals["test"].tostring(), "hello")
    }

    func test_len() throws {
        L.push(1234) // 1
        L.push("woop") // 2
        L.push([11, 22, 33, 44, 55]) // 3
        lua_newtable(L)
        L.setfuncs([
            "__len": { (L: LuaState!) -> CInt in
                L.push(999)
                return 1
            },
        ])
        lua_setmetatable(L, -2)

        class Foo {}
        L.registerMetatable(for: Foo.self, functions: [
            "__len": { (L: LuaState!) -> CInt in
                L.push(42)
                return 1
            },
        ])
        L.push(userdata: Foo()) // 4
        L.pushnil() // 5

        XCTAssertNil(L.rawlen(1))
        XCTAssertEqual(L.rawlen(2), 4)
        XCTAssertEqual(L.rawlen(3), 5)
        XCTAssertEqual(L.rawlen(4), lua_Integer(MemoryLayout<Any>.size))
        XCTAssertEqual(L.rawlen(5), nil)

        XCTAssertNil(try L.len(1))
        XCTAssertEqual(try L.len(2), 4)
        XCTAssertEqual(try L.len(3), 999) // len of 3 is different to rawlen thanks to metatable
        XCTAssertEqual(try L.len(4), 42)
        XCTAssertEqual(try L.len(5), nil)

        XCTAssertThrowsError(try L.ref(index: 1).len, "", { err in
            XCTAssertEqual(err as? LuaValueError, .noLength)
        })
        XCTAssertEqual(try L.ref(index: 2).len, 4)
        XCTAssertEqual(try L.ref(index: 3).len, 999)
        XCTAssertEqual(try L.ref(index: 4).len, 42)
        XCTAssertThrowsError(try L.ref(index: 5).len, "", { err in
            XCTAssertEqual(err as? LuaValueError, .nilValue)
        })
    }

    func test_todecodable() throws {
        L.push(1234) // 1
        L.push(true) // 2
        L.push("hello") // 3
        L.push(123.456) // 4
        L.pushnil() // 5
        L.push(["hello": 123, "world": 456]) // 6
        L.push(any: ["bar": "sheep", "baz": 321, "bat": [true, false]] as [String : Any]) // 7

        struct Foo: Equatable, Codable {
            let bar: String
            let baz: Int
            let bat: [Bool]
        }

        XCTAssertEqual(L.todecodable(1, Int.self), 1234)
        XCTAssertEqual(L.todecodable(1, Int16.self), 1234)
        XCTAssertEqual(L.todecodable(1, Bool.self), nil)
        XCTAssertEqual(L.todecodable(2, Bool.self), true)
        XCTAssertEqual(L.todecodable(2, Int.self), nil)
        XCTAssertEqual(L.todecodable(3, String.self), "hello")
        XCTAssertEqual(L.todecodable(4, Double.self), 123.456)
        XCTAssertEqual(L.todecodable(5, Bool.self), nil)
        XCTAssertEqual(L.todecodable(6, Dictionary<String, Int>.self), ["hello": 123, "world": 456])
        XCTAssertEqual(L.todecodable(7, Foo.self), Foo(bar: "sheep", baz: 321, bat: [true, false]))
    }
}
