// Copyright (c) 2023 Tom Sutcliffe
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import CLua
import Foundation

/// Protocol adopted by all fundamental Swift types that can unambiguously be converted to basic Lua types.
public protocol Pushable {
    func push(state L: LuaState!)
}

extension Bool: Pushable {
    public func push(state L: LuaState!) {
        lua_pushboolean(L, self ? 1 : 0)
    }
}

extension Int: Pushable {
    public func push(state L: LuaState!) {
        lua_pushinteger(L, lua_Integer(self))
    }
}

extension CInt: Pushable {
    public func push(state L: LuaState!) {
        lua_pushinteger(L, lua_Integer(self))
    }
}

extension Int64: Pushable {
    public func push(state L: LuaState!) {
        lua_pushinteger(L, self)
    }
}

extension UInt64: Pushable {
    public func push(state L: LuaState!) {
        if self < 0x8000000000000000 {
            lua_pushinteger(L, lua_Integer(self))
        } else {
            lua_pushnumber(L, Double(self))
        }
    }
}

extension Double: Pushable {
    public func push(state L: LuaState!) {
        lua_pushnumber(L, self)
    }
}

extension Data: Pushable {
    public func push(state L: LuaState!) {
        self.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Void in
            let chars = buf.bindMemory(to: CChar.self)
            lua_pushlstring(L, chars.baseAddress, chars.count)
        }
    }
}

extension String: Pushable {
    public func push(state L: LuaState!) {
        L.push(string: self, encoding: L.getDefaultStringEncoding())
    }
}

extension Array: Pushable where Element: Pushable {
    public func push(state L: LuaState!) {
        lua_createtable(L, CInt(self.count), 0)
        for (i, val) in self.enumerated() {
            val.push(state: L)
            lua_rawseti(L, -2, lua_Integer(i + 1))
        }
    }
}

extension Dictionary: Pushable where Key: Pushable, Value: Pushable {
    public func push(state L: LuaState!) {
        lua_createtable(L, 0, CInt(self.count))
        for (k, v) in self {
            L.push(k)
            L.push(v)
            lua_settable(L, -3)
        }
    }
}
