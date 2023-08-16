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

import Foundation

public struct LuaStringRef {
    let L: LuaState!
    let index: CInt

    public init(L: LuaState!, index: CInt) {
        self.L = L
        self.index = L.absindex(index)
    }

    public func toString(encoding: ExtendedStringEncoding? = nil) -> String? {
        return L.tostring(index, encoding: encoding)
    }

    public func toData() -> Data {
        return L.todata(index)! // Definitely won't error (assuming index still valid) as type has already been checked
    }

    public func guessType() -> AnyHashable {
        if let str = L.tostring(index, convert: false) {
            // This will fail if the string isn't valid in the default encoding
            return str
        } else {
            return L.todata(index)!
        }
    }
}
