// Copyright (c) 2023-2024 Tom Sutcliffe
// See LICENSE file for license information.

import Foundation
import Lua

// Easier to just duplicate these rather than figure out how to share logic between the plugin and the tool

func commonBase(path: String, prevBase: String?) -> String? {
    var candidate = prevBase ?? (path as NSString).deletingLastPathComponent
    while true {
        if candidate.count <= 1 {
            return nil
        } else if path.hasPrefix(candidate + "/") {
            return candidate
        } else {
            candidate = (candidate as NSString).deletingLastPathComponent
        }
    }
}

// String why do you suck so much JUST GIVE ME INTEGER BASED INDEXES
func substring(_ str: String, start: Int, len: Int? = nil) -> String {
    let startIdx = str.index(str.startIndex, offsetBy: start)
    let endIdx: String.Index
    if let len {
        endIdx = str.index(startIdx, offsetBy: len)
    } else {
        endIdx = str.endIndex
    }
    return String(str[startIdx ..< endIdx])
}

@main
struct EmbedLua {
    static func main() {
        // Parse cmdline
        if CommandLine.arguments.count < 2 {
            print("Syntax: embedlua <out_dir> [<input>...]")
            exit(1)
        }
        let outDir = CommandLine.arguments[1]
        let outPrefix = (outDir as NSString).appendingPathComponent("LuaSources")
        let output = outPrefix + ".swift"
        var inputs: [URL] = []
        for i in 2 ..< CommandLine.arguments.count {
            inputs.append(URL(fileURLWithPath: CommandLine.arguments[i], isDirectory: false))
        }

        // Work out common prefix of inputs
        var base: String? = nil
        for inputFile in inputs {
            base = commonBase(path: inputFile.path, prevBase: base)
            if base == nil {
                fatalError("No common base found between source files")
            }
        }
        guard let base else {
            fatalError() // Can't hit this unless there are no inputs, in which case we shouldn't even be called...
        }
        let basePrefix = base + "/"
        // debugPrint("Common base: \(basePrefix)")

        // Work out module names
        var dirsWithLuaFiles: Set<URL> = []
        for input in inputs {
            let dirName = input.deletingLastPathComponent()
            dirsWithLuaFiles.insert(dirName)
        }

        var moduleNameMap: [String: (displayPath: String, url: URL)] = [:]
        for url in inputs {
            let (moduleName, displayPath) = getModuleName(url, dirsWithLuaFiles: dirsWithLuaFiles)
            moduleNameMap[moduleName] = (displayPath: displayPath, url: url)
        }

        let sortedModules = moduleNameMap.keys.sorted()

        let L = LuaState(libraries: [.string, .io])
        defer {
            L.close()
        }

        // We can't have Regex until iOS 16, sigh, but we can just use Lua!
        try! L.load(string: """
            local str = ...
            return str:gsub("[^A-Za-z0-9_]", function(ch)
                return ch == "." and "_" or string.format("_%02X_", string.byte(ch))
            end)
            """)
        // Stack pos 1: getVariableName(moduleName)

        try! L.load(string: """
            local path = ...
            local f = io.open(path, "rb")
            if f then
                f:seek("set", 3)
                local data = f:read(20)
                f:close()
                return data
            else
                return nil
            end
            """)
        // Stack pos 2: getLastModified(generatedSwiftFile)

        var result = "let lua_sources: [String: [UInt8]] = ["
        var didError = false
        for moduleName in sortedModules {
            let (displayPath, url) = moduleNameMap[moduleName]!
            let relPath = substring(url.path, start: basePrefix.count).replacingOccurrences(of: "/", with: "_")
            let moduleOutputPath = "\(outPrefix)_\(relPath).swift"

            if url.lastPathComponent == "_.lua" {
                // We don't include these in lua_sources, providing the file is empty, but we still have to write
                // out a .swift file to satisfy the dependency tracking
                if (try? Data(contentsOf: url).count) == 0 {
                    let existingFile = try? Data(contentsOf: URL(fileURLWithPath:moduleOutputPath, isDirectory: false))
                    let existingFileEmpty = (existingFile == Data())
                    if !existingFileEmpty {
                        try! "".write(toFile: moduleOutputPath, atomically: true, encoding: .utf8)
                    }
                    continue
                }
            }

            L.push(index: 1) // getVariableName
            let variableName: String = "lua_source_" + (try! L.pcall(moduleName))!
            // debugPrint("\(url.path) -> \(variableName) in \(moduleOutputName)")

            result = result + "\n    \"\(moduleName)\": \(variableName),"

            guard let lastModified = getLastModified(url.path) else {
                fatalError("Could read last modified date from \(url.path)")
            }
            let lastModifiedString = ISO8601DateFormatter().string(from: lastModified)

            L.push(index: 2) // getLastModified
            let outFileLastModified: String? = try? L.pcall(moduleOutputPath)

            if outFileLastModified == lastModifiedString {
                // debugPrint("\(url.path) not modified")
                continue
            }

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
            L.pop()
            let perFileResult = """
                // \(lastModifiedString) from \(url.path)
                let \(variableName): [UInt8] = \(escape(data))
                """
            try! perFileResult.write(toFile: moduleOutputPath, atomically: true, encoding: .utf8)
        }

        if didError {
            exit(1)
        }

        if sortedModules.count == 0 {
            result.append(":]")
        } else {
            result.append("\n]")
        }

        try! result.write(toFile: output, atomically: true, encoding: .utf8)
    }

    static func escape(_ data: [UInt8]) -> String {
        var result = "[\n"
        // Each line of the generated format is 104 chars
        result.reserveCapacity(104 * ((data.count / 16) + 1) + 8)
        var i = 0
        while i != data.count {
            let n = min(16, data.count - i)
            result.append("    ")
            result.append(data[i..<i+n].map({ b in String(format: "0x%02X, ", b) }).joined())
            result.append("\n")
            i = i + n
        }
        result.append("]")
        return result
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

    static func getLastModified(_ path: String) -> Date? {
        guard let attribs = try? FileManager.default.attributesOfItem(atPath: path),
              let lastModified = attribs[.modificationDate] as? Date else {
            return nil
        }
        return lastModified
    }
}
