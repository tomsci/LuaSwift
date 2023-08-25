//
//  EmbedLua.swift
//  
//
//  Created by Tom Sutcliffe on 24/08/2023.
//

import Foundation

import Lua
import CLua

@main
struct EmbedLua {
    static func main() {
        if CommandLine.arguments.count < 2 {
            print("Syntax: embedlua <output> [<input>...]")
            exit(1)
        }
        let output = CommandLine.arguments[1]
        var inputs: [String] = []
        for i in 2 ..< CommandLine.arguments.count {
            inputs.append(CommandLine.arguments[i])
        }

        let L = LuaState(libraries: [])
        defer {
            L.close()
        }
        var result = "let lua_sources: [String: [UInt8]] = ["
        for input in inputs {
            let url = URL(fileURLWithPath: input)
            let baseName = url.deletingPathExtension().lastPathComponent

            do {
                try L.load(file: input, mode: .text)
            } catch LuaLoadError.parseError(let str) {
                fputs(str + "\n", stderr)
                exit(1)
            } catch LuaLoadError.fileNotFound {
                fputs("Error: file not found: \(input)\n", stderr)
                exit(1)
            } catch {
                fatalError("Unhandled error \(error)")
            }
            var data: [UInt8] = []
            withUnsafeMutablePointer(to: &data) { dataPtr -> Void in
                lua_dump(L, writer, dataPtr, 0)
            }

            result.append("\n    // From \(input)")
            result.append("\n    \"\(baseName)\": \(escape(data)),")

        }
        result.append("\n]")

        try! result.write(toFile: output, atomically: true, encoding: .utf8)
    }

    static let writer: lua_Writer = { (L: LuaState!, p: UnsafeRawPointer!, sz: Int, ud: UnsafeMutableRawPointer!) -> CInt in
        let data = ud.bindMemory(to: [UInt8].self, capacity: 1)
        let buf = UnsafeRawBufferPointer(start: p, count: sz)
        data.pointee.append(contentsOf: buf)
        return 0
    }

    static func escape(_ data: [UInt8]) -> String {
        var result = ["["]
        var i = 0
        while i != data.count {
            let n = min(16, data.count - i)
            result.append("        " + data[i..<i+n].map({ b in String(format: "0x%02X, ", b) }).joined())
            i = i + n
        }
        result.append("    ]")
        return result.joined(separator: "\n")
    }
}
