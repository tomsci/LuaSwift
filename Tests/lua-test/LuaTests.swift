// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

import XCTest
import Lua
import CLua

fileprivate func dummyFn(_ L: LuaState!) -> CInt {
    return 0
}

class DeinitChecker {
    let deinitFn: () -> Void
    init(_ fn: @escaping () -> Void) {
        self.deinitFn = fn
    }
    deinit {
        deinitFn()
    }
}

class ClosableDeinitChecker : DeinitChecker, Closable {
    let closeFn: () -> Void
    init(deinitFn: @escaping () -> Void, closeFn: @escaping () -> Void) {
        self.closeFn = closeFn
        super.init(deinitFn)
    }
    func close() {
        closeFn()
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

    func test_constants() {
        // Since we redefine a bunch of enums to work around limitations of the bridge we really should check they have
        // the same values
        XCTAssertEqual(LuaType.nil.rawValue, LUA_TNIL)
        XCTAssertEqual(LuaType.boolean.rawValue, LUA_TBOOLEAN)
        XCTAssertEqual(LuaType.lightuserdata.rawValue, LUA_TLIGHTUSERDATA)
        XCTAssertEqual(LuaType.number.rawValue, LUA_TNUMBER)
        XCTAssertEqual(LuaType.string.rawValue, LUA_TSTRING)
        XCTAssertEqual(LuaType.table.rawValue, LUA_TTABLE)
        XCTAssertEqual(LuaType.function.rawValue, LUA_TFUNCTION)
        XCTAssertEqual(LuaType.userdata.rawValue, LUA_TUSERDATA)
        XCTAssertEqual(LuaType.thread.rawValue, LUA_TTHREAD)

        XCTAssertEqual(LuaState.GcWhat.stop.rawValue, LUA_GCSTOP)
        XCTAssertEqual(LuaState.GcWhat.restart.rawValue, LUA_GCRESTART)
        XCTAssertEqual(LuaState.GcWhat.collect.rawValue, LUA_GCCOLLECT)
        XCTAssertEqual(LuaState.GcMode.incremental.rawValue, LUASWIFT_GCINC)
        XCTAssertEqual(LuaState.GcMode.generational.rawValue, LUASWIFT_GCGEN)

        for t in LuaType.allCases {
            XCTAssertEqual(t.tostring(), String(cString: lua_typename(L, t.rawValue)))
        }
        XCTAssertEqual(LuaType.tostring(nil), String(cString: lua_typename(L, LUA_TNONE)))

        XCTAssertEqual(LuaState.ComparisonOp.eq.rawValue, LUA_OPEQ)
        XCTAssertEqual(LuaState.ComparisonOp.lt.rawValue, LUA_OPLT)
        XCTAssertEqual(LuaState.ComparisonOp.le.rawValue, LUA_OPLE)
    }

    func testSafeLibraries() {
        L.openLibraries(.safe)
        let unsafeLibs = ["os", "io", "package", "debug"]
        for lib in unsafeLibs {
            let t = L.getglobal(lib)
            XCTAssertEqual(t, .nil)
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
        L.push(function: dummyFn) // 6
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
        L.push(function: dummyFn) // 6
        let val: Double? = L.tonumber(1)
        XCTAssertEqual(val, 1234)
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
        L.push(function: dummyFn) // 5
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

    func test_push_toindex() {
        L.push(333)
        L.push(111, toindex: 1)
        L.push(222, toindex: -2)
        XCTAssertEqual(L.toint(1), 111)
        XCTAssertEqual(L.toint(2), 222)
        XCTAssertEqual(L.toint(3), 333)
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
        XCTAssertThrowsError(try bad_ipairs(LuaValue()), "", { err in
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
        XCTAssertThrowsError(try bad_ipairs(LuaValue()), "", { err in
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

    func test_LuaValue_pairs_errors() throws {
        let bad_pairs: (LuaValue) throws -> Void = { val in
            for (_, _) in try val.pairs() {
                XCTFail("Shouldn't get here!")
            }
        }
        XCTAssertThrowsError(try bad_pairs(LuaValue()), "", { err in
            XCTAssertEqual(err as? LuaValueError, .nilValue)
        })
        XCTAssertThrowsError(try bad_pairs(L.ref(any: 123)), "", { err in
            XCTAssertEqual(err as? LuaValueError, .notIterable)
        })
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

    func test_LuaValue_metatable() {
        XCTAssertNil(LuaValue().metatable)

        let t = LuaValue.newtable(L)
        XCTAssertNil(t.metatable)

        let mt = LuaValue.newtable(L)
        try! mt.set("foo", "bar")
        mt["__index"] = mt

        XCTAssertEqual(t["foo"].tostring(), nil)
        t.metatable = mt
        XCTAssertEqual(t["foo"].tostring(), "bar")
        XCTAssertEqual(t.metatable?.type, .table)
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
        var val: DeinitChecker? = DeinitChecker { deinited += 1 }
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

    func test_pushuserdata_close() throws {
        try XCTSkipIf(!LUA_VERSION.is54orLater())

        var deinited = 0
        var val: DeinitChecker? = DeinitChecker { deinited += 1 }
        XCTAssertEqual(deinited, 0)

        L.registerMetatable(for: DeinitChecker.self, functions: [:])
        XCTAssertEqual(L.gettop(), 0)

        // Avoid calling lua_toclose, to make this test still compile with Lua 5.3
        try! L.load(string: """
            val = ...
            local arg <close> = val
            """)
        L.push(userdata: val!)
        val = nil
        XCTAssertEqual(deinited, 0)
        do {
            let valUserdata: DeinitChecker? = L.touserdata(-1)
            XCTAssertNotNil(valUserdata)
        }
        try! L.pcall(nargs: 1, nret: 0)
        XCTAssertEqual(deinited, 1)
        XCTAssertEqual(L.getglobal("val"), .userdata)
        do {
            // After being closed, touserdata should no longer return it
            let valUserdata: DeinitChecker? = L.touserdata(-1)
            XCTAssertNil(valUserdata)
        }
        L.pop()

        L.setglobal(name: "val", value: .nilValue)
        L.collectgarbage()
        XCTAssertEqual(deinited, 1)
    }

    func test_pushuserdata_Closeable_close() throws {
        try XCTSkipIf(!LUA_VERSION.is54orLater())

        var deinited = 0
        var closed = 0
        var val: DeinitChecker? = ClosableDeinitChecker(deinitFn: { deinited += 1 }, closeFn: { closed += 1 })
        XCTAssertEqual(deinited, 0)
        XCTAssertEqual(closed, 0)

        L.registerMetatable(for: ClosableDeinitChecker.self, functions: [:])
        XCTAssertEqual(L.gettop(), 0)

        // Avoid calling lua_toclose, to make this test still compile with Lua 5.3
        try! L.load(string: """
            val = ...
            local arg <close> = val
            """)
        L.push(userdata: val!)
        val = nil
        XCTAssertEqual(deinited, 0)
        XCTAssertEqual(closed, 0)
        do {
            let valUserdata: DeinitChecker? = L.touserdata(-1)
            XCTAssertNotNil(valUserdata)
        }
        try! L.pcall(nargs: 1, nret: 0)
        XCTAssertEqual(deinited, 0)
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(L.getglobal("val"), .userdata)
        do {
            // Since the type implements Closable, touserdata _should_ still return it
            let valUserdata: DeinitChecker? = L.touserdata(-1)
            XCTAssertNotNil(valUserdata)
        }
        L.pop()

        L.setglobal(name: "val", value: .nilValue)
        L.collectgarbage()
        XCTAssertEqual(deinited, 1)
        XCTAssertEqual(closed, 1)
    }

    func test_registerMetatable() throws {
        class SomeClass {
            var member: String? = nil
        }
        XCTAssertFalse(L.isMetatableRegistered(for: SomeClass.self))
        L.registerMetatable(for: SomeClass.self, functions: [
            "__call": .function { (L: LuaState!) -> CInt in
                guard let obj: SomeClass = L.touserdata(1) else {
                    fatalError("Shouldn't happen")
                }
                obj.member = L.tostring(2)
                return 0
            }
        ])
        XCTAssertTrue(L.isMetatableRegistered(for: SomeClass.self))
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
        XCTAssertFalse(L.isMetatableRegistered(for: Foo.self))
        L.registerMetatable(for: Foo.self, functions: ["__call": .function { (L: LuaState!) -> CInt in
            let f: Foo? = L.touserdata(1)
            // Above would have failed if we get called with an innerfoo
            XCTAssertNotNil(f)
            f!.str = L.tostring(2)
            return 0
        }])
        XCTAssertTrue(L.isMetatableRegistered(for: Foo.self))
        L.push(userdata: f)

        if true {
            // A different Foo ("inner Foo")
            class Foo {
                var str: String?
            }
            XCTAssertFalse(L.isMetatableRegistered(for: Foo.self))
            L.registerMetatable(for: Foo.self, functions: ["__call": .function { (L: LuaState!) -> CInt in
                let f: Foo? = L.touserdata(1)
                // Above would have failed if we get called with an outerfoo
                XCTAssertNotNil(f)
                f!.str = L.tostring(2)
                return 0
            }])
            XCTAssertTrue(L.isMetatableRegistered(for: Foo.self))
            let g = Foo()
            L.push(userdata: g)

            try L.pcall("innerfoo") // pops g
            try L.pcall("outerfoo") // pops f

            XCTAssertEqual(g.str, "innerfoo")
            XCTAssertEqual(f.str, "outerfoo")
        }
    }

    func testClosureMetafields() throws {
        struct Foo {}
        var barCalled = false
        L.registerMetatable(for: Foo.self, functions: [
            "bar": .closure { L in
                barCalled = true
                return 0
            }
        ])
        try L.load(string: "foo = ...; foo.bar()")
        L.push(any: Foo())
        try L.pcall(nargs: 1, nret: 0)
        XCTAssertTrue(barCalled)
    }

    func test_pushany() {
        L.push(any: 1234)
        XCTAssertEqual(L.toany(1) as? lua_Integer, 1234)
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

        struct Foo : Equatable {
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
        XCTAssertEqual(arr, fooArray)
        L.pop()
    }

    func test_pushany_table() { // This doubles as test_tovalue_table()
        let stringArray = ["abc", "def"]
        L.push(any: stringArray)
        let stringArrayResult: [String]? = L.tovalue(1)
        XCTAssertEqual(stringArrayResult, stringArray)
        L.pop()

        // Make sure non-lua_Integer arrays work...
        let intArray: [Int] = [11, 22, 33]
        L.push(any: intArray)
        let intArrayResult: [Int]? = L.tovalue(1)
        XCTAssertEqual(intArrayResult, intArray)
        L.pop()

        let smolIntArray: [UInt8] = [11, 22, 33]
        L.push(any: smolIntArray)
        let smolIntArrayResult: [UInt8]? = L.tovalue(1)
        XCTAssertEqual(smolIntArrayResult, smolIntArray)
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

        let intIntDict: [Int16: Int16] = [ 1: 11, 2: 22, 3: 33 ]
        L.push(any: intIntDict)
        let intIntDictResult: [Int16: Int16]? = L.tovalue(1)
        XCTAssertEqual(intIntDictResult, intIntDict)
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
        L.pop()

        let uint8Array: [ [UInt8] ] = [ [0x61, 0x62, 0x63], [0x64, 0x65, 0x66] ] // Same as stringArray above
        L.push(any: uint8Array)
        let uint8ArrayResult: [ [UInt8] ]? = L.tovalue(1)
        XCTAssertEqual(uint8ArrayResult, uint8Array)
        let uint8ArrayAsStringResult: [String]? = L.tovalue(1)
        XCTAssertEqual(uint8ArrayAsStringResult, stringArray)
#if !LUASWIFT_NO_FOUNDATION
        let dataArray = uint8Array.map({ Data($0) })
        let uint8ArrayAsDataResult: [Data]? = L.tovalue(1)
        XCTAssertEqual(uint8ArrayAsDataResult, dataArray)
#endif
        L.pop()

        L.push(any: stringArray)
        let stringAsUint8ArrayResult: [ [UInt8] ]? = L.tovalue(1)
        XCTAssertEqual(stringAsUint8ArrayResult, uint8Array)
#if !LUASWIFT_NO_FOUNDATION
        let stringAsDataArrayResult: [Data]? = L.tovalue(1)
        XCTAssertEqual(stringAsDataArrayResult, dataArray)
#endif
        L.pop()

#if !LUASWIFT_NO_FOUNDATION
        L.push(any: stringDict)
        let stringDictAsDataDict: [Data: Data]? = L.tovalue(1)
        var dataDict: [Data: Data] = [:]
        for (k, v) in stringDict {
            dataDict[k.data(using: .utf8)!] = v.data(using: .utf8)!
        }
        XCTAssertEqual(stringDictAsDataDict, dataDict)
#endif
    }

    func test_push_closure() throws {
        var called = false
        L.push(closure: {
            called = true
        })
        try L.pcall()
        XCTAssertTrue(called)

        // Check the trailing closure syntax works too
        called = false
        L.push() { () -> Int? in
            called = true
            return 123
        }
        let iresult: Int? = try L.pcall()
        XCTAssertTrue(called)
        XCTAssertEqual(iresult, 123)

        called = false
        L.push() { (L: LuaState) -> CInt in
            called = true
            L.push("result")
            return 1
        }
        let sresult: String? = try L.pcall()
        XCTAssertTrue(called)
        XCTAssertEqual(sresult, "result")

        L.push(closure: {
            return "Void->String closure"
        })
        XCTAssertEqual(try L.pcall(), "Void->String closure")

        L.push() {
            return "Void->String trailing closure"
        }
        XCTAssertEqual(try L.pcall(), "Void->String trailing closure")

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
                           "bad argument #1 to '?' (Expected String, got number)")
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
        // The way we've set up the typing, Any? isn't actually set up as a type, so shut up the warnings here
        L.registerMetatable(for: Optional<Any>.self, functions: [:])

        L.push(any: voidAnyClosure)
        try L.pcall()
        XCTAssertTrue(called)
    }

    func test_extension_4arg_closure() throws {
        // Test that more argument overloads of push(closure:) can be implemented if required by code not in the Lua
        // package.
        func push<Arg1, Arg2, Arg3, Arg4>(closure: @escaping (Arg1?, Arg2?, Arg3?, Arg4?) throws -> Any?) {
            L.push(LuaClosureWrapper({ L in
                let arg1: Arg1? = try L.checkClosureArgument(index: 1)
                let arg2: Arg2? = try L.checkClosureArgument(index: 2)
                let arg3: Arg3? = try L.checkClosureArgument(index: 3)
                let arg4: Arg4? = try L.checkClosureArgument(index: 4)
                L.push(any: try closure(arg1, arg2, arg3, arg4))
                return 1
            }))
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
        let _ = lua_newuserdata(L, MemoryLayout<Any>.size)
        let bad: Any? = L.touserdata(-1)
        XCTAssertNil(bad)
    }

    func test_ref() {
        var ref: LuaValue! = L.ref(any: "hello")
        XCTAssertEqual(ref.type, .string)
        XCTAssertEqual(ref.toboolean(), true)
        XCTAssertEqual(ref.tostring(), "hello")
        XCTAssertEqual(L.gettop(), 0)

        ref = LuaValue()
        XCTAssertEqual(ref.type, .nil)

        ref = L.ref(any: nil)
        XCTAssertEqual(ref.type, .nil)

        // Check it can correctly keep hold of a ref to a Swift object
        var deinited = 0
        var obj: DeinitChecker? = DeinitChecker { deinited += 1 }
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
        XCTAssertNil(ref!.internal_get_L())
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
            "__index": .function { L in
                return 1 // Ie just return whatever the key name was
            }
        ])
        let ref = L.ref(any: IndexableValue())
        XCTAssertEqual(try ref.get("woop").tostring(), "woop")

        // Now make ref the __index of another userdata
        // This didn't work with the original implementation of checkIndexable()

        lua_newuserdata(L, 4) // will become udref
        lua_newtable(L) // udref's metatable
        L.rawset(-1, key: "__index", value: ref)
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
        XCTAssertEqual(L.type(1), .nil)
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

    func test_tovalue_data() {
        L.push("abc")
        let byteArray: [UInt8]? = L.tovalue(1)
        XCTAssertEqual(byteArray, [0x61, 0x62, 0x63])

        let str: String? = L.tovalue(1)
        XCTAssertEqual(str, "abc")

#if !LUASWIFT_NO_FOUNDATION
        let data: Data? = L.tovalue(1)
        XCTAssertEqual(data, Data([0x61, 0x62, 0x63]))
#endif
    }

    func test_tovalue_number() {
        L.push(3.0) // 1: A double but integer representable
        L.push(Double.pi) // 2: A double

        let intVal: Int? = L.tovalue(1)
        XCTAssertEqual(intVal, 3)

        // This is a test for tovalue(_:type:) really
        XCTAssertEqual(Int8(L.tovalue(1, type: Int.self)!), 3)

        let integerVal: lua_Integer? = L.tovalue(1)
        XCTAssertEqual(integerVal, 3)

        let int64Val: Int64? = L.tovalue(1)
        XCTAssertEqual(int64Val, 3)

        // Because lua_tointeger() succeeded on the value, toany will return it as a lua_Integer, thus checking we can
        // retrieve it as a Double is not a given.
        let doubleVal: Double? = L.tovalue(1)
        XCTAssertEqual(doubleVal, 3.0)

        // Downcasting to a smaller integer type IS now expected to work, because while `Int as? Int8` is not something
        // Swift lets you do, `Int as? AnyHashable as? Int8` _does_, and toany casts all integers to AnyHashable before
        // returning them
        let smolInt: Int8? = L.tovalue(1)
        XCTAssertEqual(smolInt, 3)

        // We should not allow truncation of something not representable as an integer
        let nope: Int? = L.tovalue(2)
        XCTAssertNil(nope)

        // Check there is no loss of precision in round-tripping an irrational float
        XCTAssertEqual(L.tovalue(2), Double.pi)
    }

    func test_math_pi() {
        // Given these are defined in completely different unrelated places, I'm slightly surprised their definitions
        // agree exactly.
        L.openLibraries([.math])
        let mathpi: Double = L.globals["math"]["pi"].tovalue()!
        XCTAssertEqual(mathpi, Double.pi)
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

    // There are 2 basic Any pathways to worry about, which are tovalue<Any> and tovalue<AnyHashable>.
    // Then there are LuaTableRef.doResolveArray and LuaTableRef.doResolveDict which necessarily don't use tovalue,
    // meaning Array<Any>, Array<AnyHashable>, Dictionary<AnyHashable, Any> and Dictionary<AnyHashable, AnyHashable>
    // all need testing too. And for each of *those*, we need to test with string, table and something-that's-neither
    // datatypes.

    func test_tovalue_any_int() {
        L.push(123)
        let anyVal: Any? = L.tovalue(-1)
        XCTAssertNotNil(anyVal as? Int)
        let anyHashable: AnyHashable? = L.tovalue(-1)
        XCTAssertNotNil(anyHashable as? Int)
    }

    func test_tovalue_any_string() {
        L.push("abc")
        let anyVal: Any? = L.tovalue(-1)
        XCTAssertEqual((anyVal as? LuaValue)?.tovalue(), "abc")
        let anyHashable: AnyHashable? = L.tovalue(-1)
        XCTAssertEqual((anyHashable as? LuaValue)?.tovalue(), "abc")
    }

    func test_tovalue_any_stringarray() {
        L.push(["abc"])
        let anyArray: Array<Any> = L.tovalue(1)!
        XCTAssertEqual((anyArray[0] as? LuaValue)?.tovalue(), "abc")
        let anyHashableArray: Array<AnyHashable> = L.tovalue(1)!
        XCTAssertEqual((anyHashableArray[0] as? LuaValue)?.tovalue(), "abc")
    }

    func test_tovalue_luavaluearray() {
        L.newtable()
        L.rawset(-1, key: 1, value: 123)
        L.rawset(-1, key: 2, value: "abc")
        let array: Array<LuaValue> = L.tovalue(1)!
        XCTAssertEqual(array[0].tovalue(), 123)
        XCTAssertEqual(array[1].tovalue(), "abc")
    }

    func test_tovalue_any_stringdict() {
        L.push(["abc": "def"])
        let anyDict: Dictionary<AnyHashable, Any> = L.tovalue(1)!
        let (k, v) = anyDict.first!
        XCTAssertEqual((k as? LuaValue)?.tovalue(), "abc")
        XCTAssertEqual((v as? LuaValue)?.tovalue(), "def")
    }

    func test_tovalue_any_stringintdict() {
        L.push(["abc": 123])
        let anyDict: Dictionary<AnyHashable, Any> = L.tovalue(1)!
        let (k, v) = anyDict.first!
        XCTAssertEqual((k as? LuaValue)?.tovalue(), "abc")
        XCTAssertEqual(v as? Int, 123)
    }

    func test_tovalue_stringanydict() {
        L.newtable()
        L.rawset(-1, key: "abc", value: "def")
        L.rawset(-1, key: "123", value: 456)
        let anyDict: Dictionary<String, Any> = L.tovalue(1)!
        XCTAssertEqual((anyDict["abc"] as? LuaValue)?.tovalue(), "def")
        XCTAssertEqual(anyDict["123"] as? Int, 456)
    }

    func test_tovalue_luavalue() {
        L.push("abc")
        L.push(123)
        L.push([123])
        L.push(["abc": 123])

        XCTAssertEqual(L.tovalue(1, type: LuaValue.self)?.tostring(), "abc")
    }

    func test_tovalue_fndict() {
        L.newtable()
        let fn: lua_CFunction = L.globals["print"].tovalue()!
        L.push(fn)
        L.push(true)
        L.rawset(-3)
        // We now have a table of [lua_CFunction : Bool] except that lua_CFunction isn't Hashable

        let anyanydict = L.tovalue(1, type: [AnyHashable: Any].self)!
        XCTAssertNotNil((anyanydict.keys.first as? LuaValue)?.tovalue(type: lua_CFunction.self))
    }

// #if !LUASWIFT_NO_FOUNDATION
//     func test_tovalue_table_perf_int_array() {
//         L.newtable()
//         // Add an extra zero to this (for 1000000) to make the test more obvious
//         for i in 1 ..< 1000000 {
//             L.rawset(-1, key: i, value: i)
//         }
//         measure {
//             let _: [Int] = L.tovalue(-1)!
//         }
//     }

//     func test_tovalue_table_perf_data_array() {
//         L.newtable()
//         // Add an extra zero to this (for 1000000) to make the test more obvious
//         for i in 1 ..< 1000000 {
//             L.rawset(-1, key: i, value: "abc")
//         }
//         measure {
//             let _: [Data] = L.tovalue(-1)!
//         }
//     }

//     func test_tovalue_table_perf_int_dict() {
//         L.newtable()
//         // Add an extra zero to this (for 1000000) to make the test more obvious
//         for i in 1 ..< 1000000 {
//             L.rawset(-1, key: i, value: i)
//         }
//         measure {
//             let _: Dictionary<Int, Int> = L.tovalue(-1)!
//         }
//     }

//     func test_tovalue_table_perf_data_dict() {
//         L.newtable()
//         // Add an extra zero to this (for 1000000) to make the test more obvious
//         for i in 1 ..< 1000000 {
//             L.rawset(-1, key: "\(i)", value: "abc")
//         }
//         measure {
//             let _: Dictionary<Data, Data> = L.tovalue(-1)!
//         }
//     }

// #endif

    func test_load_file() {
        XCTAssertThrowsError(try L.load(file: "nopemcnopeface"), "", { err in
            XCTAssertEqual(err as? LuaLoadError, .fileError("cannot open nopemcnopeface: No such file or directory"))
        })
        XCTAssertEqual(L.gettop(), 0)
    }

    func test_load() throws {
        try L.dostring("return 'hello world'")
        XCTAssertEqual(L.tostring(-1), "hello world")

        let asArray: [UInt8] = "return 'hello world'".map { $0.asciiValue! }
        try L.load(data: asArray, name: "Hello", mode: .text)
        try L.pcall(nargs: 0, nret: 1)
        XCTAssertEqual(L.tostring(-1), "hello world")

        XCTAssertThrowsError(try L.load(string: "woop woop"), "", { err in
            let expected = #"[string "woop woop"]:1: syntax error near 'woop'"#
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
            -- print("Hello from module land!")
            return "hello"
            """.map { $0.asciiValue! }
        // To be extra awkward, we call addModules before opening package (which sets up the package loaders) to
        // make sure that our approach works with that
        L.setModules(["test": mod], mode: .text)
        L.openLibraries([.package])
        let ret = try L.globals["require"]("test")
        XCTAssertEqual(ret.tostring(), "hello")
    }

    func test_lua_sources() throws {
        XCTAssertNotNil(lua_sources["testmodule1"])
        L.openLibraries([.package])
        L.setModules(lua_sources)
        try L.load(string: "return require('testmodule1')")
        try L.pcall(nargs: 0, nret: 1)
        XCTAssertEqual(L.tostring(-1, key: "hello"), "world")
        L.rawget(-1, key: "foo")
        let info = L.getTopFunctionInfo()
        // Check we're not leaking build machine info into the function debug info
        XCTAssertEqual(info.source, "@testmodule1.lua")
        XCTAssertEqual(info.short_src, "testmodule1.lua")
    }

    func test_lua_sources_requiref() throws {
        let lua_sources = [
            "test": """
                -- print("Hello from module land!")
                return "hello"
                """.map { $0.asciiValue! }
        ]
        try L.requiref(name: "test") {
            try L.load(data: lua_sources["test"]!, name: "test", mode: .text)
        }
        XCTAssertEqual(L.gettop(), 0)
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
            "__len": .closure { L in
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
        let top = L.gettop()
        XCTAssertEqual(try L.len(3), 999) // len of 3 is different to rawlen thanks to metatable
        XCTAssertEqual(L.gettop(), top)
        XCTAssertEqual(L.absindex(-3), 3)
        XCTAssertEqual(try L.len(-3), 999) // -3 is 3 here
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

        XCTAssertEqual(L.todecodable(1, type: Int.self), 1234)
        XCTAssertEqual(L.todecodable(1, type: Int16.self), 1234)
        XCTAssertEqual(L.todecodable(1, type: Bool.self), nil)
        XCTAssertEqual(L.todecodable(2, type: Bool.self), true)
        XCTAssertEqual(L.todecodable(2, type: Int.self), nil)
        XCTAssertEqual(L.todecodable(3, type: String.self), "hello")
        XCTAssertEqual(L.todecodable(4, type: Double.self), 123.456)
        XCTAssertEqual(L.todecodable(5, type: Bool.self), nil)
        XCTAssertEqual(L.todecodable(6, type: Dictionary<String, Int>.self), ["hello": 123, "world": 456])
        XCTAssertEqual(L.todecodable(7, type: Foo.self), Foo(bar: "sheep", baz: 321, bat: [true, false]))
    }

    func test_get_set() throws {
        L.push([11, 22, 33, 44, 55])
        // Do all accesses here with negative indexes to make sure they are handled right.

        L.push(2)
        XCTAssertEqual(L.rawget(-2), .number)
        XCTAssertEqual(L.gettop(), 2)
        XCTAssertEqual(L.toint(-1), 22)
        L.pop()
        XCTAssertEqual(L.gettop(), 1)

        L.rawget(-1, key: 3)
        XCTAssertEqual(L.toint(-1), 33)
        L.pop()
        XCTAssertEqual(L.gettop(), 1)

        L.push(2)
        try L.get(-2)
        XCTAssertEqual(L.toint(-1), 22)
        L.pop()
        XCTAssertEqual(L.gettop(), 1)

        try L.get(-1, key: 3)
        XCTAssertEqual(L.toint(-1), 33)
        L.pop()
        XCTAssertEqual(L.gettop(), 1)

        L.push(6)
        L.push(66)
        L.rawset(-3)
        XCTAssertEqual(L.gettop(), 1)
        XCTAssertEqual(L.rawlen(-1), 6)
        XCTAssertEqual(L.rawget(-1, key: 6, { L.toint($0) } ), 66)
        XCTAssertEqual(L.gettop(), 1)

        L.push(666)
        L.rawset(-2, key: 6)
        XCTAssertEqual(L.rawget(-1, key: 6, { L.toint($0) } ), 666)
        XCTAssertEqual(L.gettop(), 1)

        L.rawset(-1, key: 6, value: 6666)
        XCTAssertEqual(L.gettop(), 1)
        XCTAssertEqual(L.rawget(-1, key: 6, { L.toint($0) } ), 6666)
        XCTAssertEqual(L.gettop(), 1)

        L.push(1)
        L.push(111)
        try L.set(-3)
        XCTAssertEqual(L.rawget(-1, key: 1, { L.toint($0) } ), 111)
        XCTAssertEqual(L.gettop(), 1)

        L.push(222)
        try L.set(-2, key: 2)
        XCTAssertEqual(L.rawget(-1, key: 2, { L.toint($0) } ), 222)
        XCTAssertEqual(L.gettop(), 1)

        try L.set(-1, key: 3, value: 333)
        XCTAssertEqual(L.rawget(-1, key: 3, { L.toint($0) } ), 333)
        XCTAssertEqual(L.gettop(), 1)
    }

    // Just checking the readme example code compiles
    func test_readme_bridge() throws {
        class Foo {
            let baz: String
            init(baz: String) {
                self.baz = baz
            }
            func bar() {
                print("Foo.bar() called, baz=\(baz)")
            }
        }

        let L = LuaState(libraries: [])
        L.registerMetatable(for: Foo.self, functions: [
            "bar": .closure { L in
                // Recover the `Foo` instance from the first argument to the function
                guard let foo: Foo = L.tovalue(1) else {
                    throw L.error("Bad argument #1 to bar()")
                }
                // Call the function
                foo.bar()
                // Tell Lua that this function returns zero results
                return 0
            }
        ])
    }

    func test_getinfo() throws {
        XCTAssertEqual(Set<LuaDebug.WhatInfo>.allHook, Set(LuaDebug.WhatInfo.allCases))

        var info: LuaDebug! = nil
        var whereStr: String! = nil
        try L.load(string: """
            fn = ...
            function moo(arg, arg2, arg3)
                fn()
            end
            moo()
            """, name: "=test")
        L.push(index: 1)
        L.push(closure: {
            let L = self.L!
            info = L.getStackInfo(level: 1)
            whereStr = L.getWhere(level: 1)
            return 0
        })
        try L.pcall(nargs:1, nret: 0)
        XCTAssertEqual(info.name, "moo")
        XCTAssertEqual(info.namewhat, .global)
        XCTAssertEqual(info.what, .lua)
        XCTAssertEqual(info.currentline, 3)
        XCTAssertEqual(info.linedefined, 2)
        XCTAssertEqual(info.lastlinedefined, 4)
        XCTAssertEqual(info.nups, 1)
        XCTAssertEqual(info.nparams, 3)
        XCTAssertEqual(info.isvararg, false)
        XCTAssertEqual(info.function?.type, .function)
        XCTAssertEqual(info.validlines, [3, 4])
        XCTAssertEqual(info.short_src, "test")
        XCTAssertEqual(whereStr, info.short_src! + ":3: ")

        // This is getting info for the fn returned by load(file:)
        let fninfo = L.getTopFunctionInfo()
        XCTAssertEqual(fninfo.what, .main)
        XCTAssertNil(fninfo.name) // a main fn won't have a name
        XCTAssertEqual(fninfo.namewhat, .other)
        XCTAssertNil(fninfo.currentline)
    }

    func test_isinteger() {
        L.push(123)
        L.push(123.0)
        L.pushnil()
        L.push(true)

        XCTAssertTrue(L.isinteger(1))
        XCTAssertFalse(L.isinteger(2))
        XCTAssertFalse(L.isinteger(3))
        XCTAssertFalse(L.isinteger(4))
    }

#if !LUASWIFT_NO_FOUNDATION
    func test_push_NSNumber() {
        let n: NSNumber = 1234
        let nd: NSNumber = 1234.0
        L.push(n) // 1 - using NSNumber's Pushable
        L.push(any: n) // 2 - NSNumber as Any

        var i: Double = 1234.5678
        let ni: NSNumber = 1234.5678
        let cfn: CFNumber = CFNumberCreate(nil, .doubleType, &i)
        // CF bridging is _weird_: I cannot write L.push(cfn) ie CFNumber does not directly conform to Pushable, but
        // the conversion to Pushable will always succeed, presumably because NSNumber is Pushable?
        let cfn_pushable = cfn as? Pushable
        XCTAssertNotNil(cfn_pushable)
        L.push(cfn as NSNumber) // 3 - CFNumber as NSNumber (Pushable)
        L.push(cfn_pushable!) // 4 - CFNumber as Pushable
        L.push(any: cfn) // 5 - CFNumber as Any
        L.push(nd) // 6 - integer-representable NSNumber from a double
        L.push(ni) // 7 - non-integer-representable NSNumber

        XCTAssertTrue(L.isinteger(1))
        XCTAssertTrue(L.isinteger(6)) // NSNumber does not track the original type, ie that nd was a Double
        XCTAssertFalse(L.isinteger(7))

        XCTAssertEqual(L.toint(1), 1234)
        XCTAssertEqual(L.toint(2), 1234)
        XCTAssertEqual(L.tonumber(3), 1234.5678)
        XCTAssertEqual(L.tonumber(4), 1234.5678)
        XCTAssertEqual(L.tonumber(5), 1234.5678)
    }

    func test_push_NSString() {
        let ns = "hello" as NSString // This ends up as NSTaggedPointerString
        // print(type(of: ns))
        L.push(any: ns) // 1

        let s = CFStringCreateWithCString(nil, "hello", UInt32(CFStringEncodings.dosLatin1.rawValue))! // CFStringRef
        // print(type(of: s))
        L.push(any: s) // 2

        let ns2 = String(repeating: "hello", count: 100) as NSString // __StringStorage
        // print(type(of: ns2))
        L.push(any: ns2) // 3

        XCTAssertEqual(L.tostring(1), "hello")
        XCTAssertEqual(L.tostring(2), "hello")
        XCTAssertEqual(L.tostring(3), ns2 as String)
    }

#endif

    func test_LuaClosure_upvalues() throws {
        var called = false
        L.push({ L in
            called = true
            return 0
        })
        XCTAssertEqual(called, false)
        try L.pcall()
        XCTAssertEqual(called, true)

        L.push(1234) // upvalue
        L.push({ L in
            let idx = LuaClosureWrapper.upvalueIndex(1)
            L.push(index: idx)
            return 1
        }, numUpvalues: 1)
        let ret: Int? = try L.pcall()
        XCTAssertEqual(ret, 1234)
    }

    func test_compare() throws {
        L.push(123)
        L.push(123)
        L.push(124)
        L.push("123")
        XCTAssertTrue(L.rawequal(1, 2))
        XCTAssertFalse(L.rawequal(2, 3))
        XCTAssertFalse(L.rawequal(2, 4))

        XCTAssertTrue(try L.equal(1, 2))
        XCTAssertFalse(try L.equal(1, 3))
        XCTAssertFalse(try L.equal(1, 4))

        XCTAssertFalse(try L.compare(1, 2, .lt))
        XCTAssertTrue(try L.compare(1, 2, .le))
        XCTAssertTrue(try L.compare(1, 3, .lt))

        let one = L.ref(any: 1)
        let otherone = L.ref(any: 1)
        let two = L.ref(any: 2)
        XCTAssertTrue(one.rawequal(otherone))
        XCTAssertFalse(one.rawequal(two))
        XCTAssertTrue(try one.equal(otherone))
        XCTAssertFalse(try one.equal(two))
        XCTAssertTrue(try one.compare(two, .lt)) // ie one < two
        XCTAssertFalse(try two.compare(one, .lt)) // ie two < one
    }

    func test_gc() {
        if LUA_VERSION.is54orLater() {
            var ret = L.collectorSetGenerational()
            XCTAssertEqual(ret, .incremental)
            ret = L.collectorSetIncremental(stepmul: 100)
            XCTAssertEqual(ret, .generational)
        } else {
            let ret = L.collectorSetIncremental(stepmul: 100)
            XCTAssertEqual(ret, .incremental)
        }
        XCTAssertEqual(L.collectorRunning(), true)
        L.collectgarbage(.stop)
        XCTAssertEqual(L.collectorRunning(), false)
        L.collectgarbage(.restart)
        XCTAssertEqual(L.collectorRunning(), true)

        let count = L.collectorCount()
        XCTAssertEqual(count, L.collectorCount()) // Check it's stable
        L.push("hello world")
        XCTAssertGreaterThan(L.collectorCount(), count)
    }

    func test_dump() {
        try! L.load(string: """
            return "called"
            """)
        let data = L.dump(strip: false)!
        L.settop(0)
        try! L.load(data: data, name: "undumped", mode: .binary)
        try! L.pcall(nargs: 0, nret: 1)
        XCTAssertEqual(L.tostring(-1), "called")
    }

    func test_upvalues() throws {
        try L.load(string: """
            local foo, bar = 123, 456
            function baz()
                return foo or bar
            end
            """)

        try L.pcall(nargs: 0, nret: 0)
        L.getglobal("baz")

        let n = L.findUpvalue(index: -1, name: "foo")
        XCTAssertEqual(n, 1)
        XCTAssertEqual(L.findUpvalue(index: -1, name: "bar"), 2)
        XCTAssertEqual(L.findUpvalue(index: -1, name: "nope"), nil)
        XCTAssertEqual(L.getUpvalues(index: -1).keys.sorted(), ["bar", "foo"])
        XCTAssertNil(L.getUpvalue(index: -1, n: 3))
        XCTAssertEqual(L.getUpvalue(index: -1, n: 1)?.value.toint(), 123)

        let updated = L.setUpvalue(index: -1, n: n!, value: "abc") // modify foo
        XCTAssertTrue(updated)
        let ret: String? = try L.pcall()
        XCTAssertEqual(ret, "abc")

        L.getglobal("baz")
        L.setUpvalue(index: -1, n: n!, value: .nilValue)
        let barRet: Int? = try L.pcall()
        XCTAssertEqual(barRet, 456)
    }

    func test_getLocals() throws {
        try L.load(string: """
            local foo, bar = 123, 456
            function bat(hello, world, ...)
            end
            function callNativeFn()
                local bb = bar
                local aa = foo
                nativeFn(aa, bb)
            end
            """)
        try L.pcall(nargs: 0, nret: 0)

        var localNames: [String] = []
        let closure = LuaClosureWrapper { L in
            let ret = L.withStackFrameFor(level: 1) { (frame: LuaStackFrame!) in
                XCTAssertEqual(frame.locals["aa"].toint(), 123)
                localNames = frame.localNames().map({ $0.name })
                XCTAssertEqual(localNames.sorted(), frame.locals.toDict().keys.sorted())
                return "woop"
            }
            XCTAssertEqual(ret, "woop") // Check we're returning the closure's result
            L.withStackFrameFor(level: 5) { frame in
                XCTAssertNil(frame)
            }
            return 0
        }
        L.setglobal(name: "nativeFn", value: closure)
        try L.globals["callNativeFn"].pcall()
        XCTAssertEqual(localNames, ["bb", "aa"])

        // Test getTopFunctionArguments, getTopFunctionInfo
        L.getglobal("bat")
        let args = L.getTopFunctionArguments()
        XCTAssertEqual(args, ["hello", "world"])
        let info = L.getTopFunctionInfo(what: [.paraminfo])
        XCTAssertEqual(info.isvararg, true)
        XCTAssertEqual(info.nparams, 2)

        try L.load(data: L.dump(strip: true)!, name: "=bat_stripped", mode: .binary)
        let strippedArgs = L.getTopFunctionArguments()
        let strippedInfo = L.getTopFunctionInfo(what: [.paraminfo])
        XCTAssertEqual(strippedInfo.isvararg, true)
        XCTAssertEqual(strippedInfo.nparams, 2)
        XCTAssertEqual(strippedArgs, []) // lua_getlocal() returns nothing for stripped function arguments.
    }

    func test_checkOption() throws {
        enum Foo : String {
            case foo
            case bar
            case baz
        }
        L.push("foo")
        let arg1: Foo = try! L.checkOption(1)
        XCTAssertEqual(arg1, .foo)
        let arg2: Foo = try! L.checkOption(2, default: .bar)
        XCTAssertEqual(arg2, .bar)

        L.push(123)
        XCTAssertThrowsError(try L.checkOption(2, default: Foo.foo), "", { err in
            XCTAssertEqual(err.localizedDescription, "bad argument #2 (Expected type convertible to String, got number)")
        })

        L.settop(0)
        L.setglobal(name: "nativeFn", value: LuaClosureWrapper { L in
            let _: Foo = try L.checkOption(1)
            return 0
        })
        try! L.load(string: "nativeFn('nope')")
        XCTAssertThrowsError(try L.pcall(traceback: false), "", { err in
            XCTAssertEqual(err.localizedDescription, "bad argument #1 to 'nativeFn' (invalid option 'nope' for Foo)")
        })
    }
}
