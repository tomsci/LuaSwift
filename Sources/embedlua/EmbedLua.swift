// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

import Foundation
import Lua

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
                try L.load(file: input, displayPath:url.lastPathComponent, mode: .text)
            } catch LuaLoadError.parseError(let str) {
                fputs(str + "\n", stderr)
                exit(1)
            } catch LuaLoadError.fileError(let str) {
                fputs("Error: " + str + "\n", stderr)
                exit(1)
            } catch {
                fatalError("Unhandled error \(error)")
            }

            let data = L.dump()!
            result.append("\n    // From \(input)")
            result.append("\n    \"\(baseName)\": \(escape(data)),")

        }
        if inputs.count == 0 {
            result.append(":]")
        } else {
            result.append("\n]")
        }

        try! result.write(toFile: output, atomically: true, encoding: .utf8)
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
