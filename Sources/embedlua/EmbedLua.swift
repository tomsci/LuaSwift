// Copyright (c) 2023-2024 Tom Sutcliffe
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
        var inputs: [URL] = []
        for i in 2 ..< CommandLine.arguments.count {
            inputs.append(URL(fileURLWithPath: CommandLine.arguments[i], isDirectory: false))
        }

        var dirsWithLuaFiles: Set<URL> = []
        for input in inputs {
            let dirName = input.deletingLastPathComponent()
            dirsWithLuaFiles.insert(dirName)
        }

        let L = LuaState(libraries: [])
        defer {
            L.close()
        }
        var result = "let lua_sources: [String: [UInt8]] = ["
        for url in inputs {
            let (moduleName, displayPath) = getModuleName(url, dirsWithLuaFiles: dirsWithLuaFiles)

            if url.lastPathComponent == "_.lua" {
                // We don't include these in lua_sources, providing the file is empty.
                if (try? Data(contentsOf: url).count) == 0 {
                    continue
                }
            }

            do {
                try L.load(file: url.path, displayPath: displayPath, mode: .text)
            } catch LuaLoadError.parseError(let str) {
                fputs("\(str)\n", stderr)
                exit(1)
            } catch LuaLoadError.fileError(let str) {
                fputs("Error: " + str + "\n", stderr)
                exit(1)
            } catch {
                fatalError("Unhandled error \(error)")
            }

            let data = L.dump()!
            result.append("\n    // From \(url.path)")
            result.append("\n    \"\(moduleName)\": \(escape(data)),")

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

    static func getModuleName(_ url: URL, dirsWithLuaFiles: Set<URL>) -> (moduleName: String, displayPath: String) {
        var parts: [String] = []
        var currentPath = url
        while !currentPath.path.isEmpty {
            let part = currentPath.lastPathComponent
            let parent = currentPath.deletingLastPathComponent()
            if !dirsWithLuaFiles.contains(parent) {
                break
            } else {
                parts.insert(part, at: 0)
                currentPath = parent
                // And go round again
            }
        }
        let displayPath = parts.joined(separator: "/")
        parts[parts.count - 1] = removeExtension(parts.last!)
        let moduleName = parts.joined(separator: ".")
        return (moduleName: moduleName, displayPath: displayPath)
    }

    static func removeExtension(_ path: String) -> String {
        // Can't believe it's easier to write this myself than it is to use frameworks - URL is too clunky and too
        // determined to resolve the path against the actual filesystem
        let parts = path.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count <= 1 || path.starts(with: ".") {
            return path
        } else {
            return parts[0 ..< parts.count - 1].joined(separator: ".")
        }
    }
}
