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

        var moduleNameMap: [String: (displayPath: String, url: URL)] = [:]
        for url in inputs {
            if url.lastPathComponent == "_.lua" {
                // We don't include these in lua_sources, providing the file is empty.
                if (try? Data(contentsOf: url).count) == 0 {
                    continue
                }
            }

            let (moduleName, displayPath) = getModuleName(url, dirsWithLuaFiles: dirsWithLuaFiles)
            moduleNameMap[moduleName] = (displayPath: displayPath, url: url)
        }

        let sortedModules = moduleNameMap.keys.sorted()

        let L = LuaState(libraries: [])
        defer {
            L.close()
        }
        var result = "let lua_sources: [String: [UInt8]] = ["
        var didError = false
        for moduleName in sortedModules {
            let (displayPath, url) = moduleNameMap[moduleName]!
            var loadError: String? = nil
            do {
                try L.load(file: url.path, displayPath: displayPath, mode: .text)
            } catch LuaLoadError.parseError(let str) {
                loadError = str
            } catch LuaLoadError.fileError(let str) {
                loadError = str
            } catch {
                // Shouldn't happen, but...
                loadError = "Unhandled error \(error)"
            }

            if let loadError {
                let errorString = rewriteError(error: loadError, displayPath: displayPath, url: url)
                fputs("\(errorString)\n", stderr)
                didError = true
                continue
            }

            let data = L.dump()!
            result.append("\n    // From \(url.path)")
            result.append("\n    \"\(moduleName)\": \(escape(data)),")
        }

        if didError {
            exit(1)
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

    static func rewriteError(error: String, displayPath: String, url: URL) -> String {
        // Lua uses
        //     DISPLAYNAME:LINENUM: ERRTEXT
        // And we need
        //     FILENAME:LINENUM:CHARPOS: error: ERRTEXT
        // in order for xcode to inline the error correctly.
        let parts = error.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        if parts.count == 3 && parts[0] == displayPath {
            return "\(url.path):\(parts[1]):1: error:\(parts[2])"
        } else {
            return error.replacingOccurrences(of: displayPath, with: url.path)
        }
    }
}
