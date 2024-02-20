// Copyright (c) 2023-2024 Tom Sutcliffe
// See LICENSE file for license information.

import Foundation
import Lua

@main
struct EmbedLua {
    static func main() {
        let args = CommandLine.arguments
        if args.count < 2 {
            exitWithSyntax()
        }
        let cmd = args[1]
        if cmd == "compile" {
            // compile <modulename> <inputfile> <outputfile>
            if args.count != 5 {
                exitWithSyntax()
            }
            let moduleName = args[2]
            let inputFile = args[3]
            let outputFile = args[4]
            compile(moduleName, inputFile, outputFile)
        } else if cmd == "sources" {
            // sources <outputfile> [<modulename> <sourcefile>]...
            // must have pairs of modulename+sourcefile, making overall arg count odd
            // sourcefile params only needed so we can check for empty _.lua modules.
            if args.count < 3 || args.count & 1 == 0 {
                exitWithSyntax()
            }
            let outputFile = args[2]
            var moduleNames: [String] = []
            var modulePaths: [String] = []
            for i in stride(from: 3, to: args.count, by: 2) {
                moduleNames.append(args[i])
                modulePaths.append(args[i + 1])
            }
            makeSources(moduleNames, modulePaths, outputFile)
        } else {
            exitWithSyntax()
        }
    }

    static func compile(_ moduleName: String, _ inputFile: String, _ outputFile: String) {
        if getFileSize(inputFile) == 0 {
            try! "".write(toFile: outputFile, atomically: true, encoding: .utf8)
            return
        }

        let L = LuaState(libraries: [.string])
        defer {
            L.close()
        }

        // We can't have Regex until iOS 16, sigh, but we can just use Lua!
        try! L.load(string: getVariableNameProg)
        // Stack pos 1: getVariableName(moduleName)

        let variableName: String = "lua_source_" + (try! L.pcall(moduleName))!
        let displayPath = moduleName.replacingOccurrences(of: ".", with: "/") + ".lua"

        var loadError: String? = nil
        do {
            try L.load(file: inputFile, displayPath: displayPath, mode: .text)
        } catch LuaLoadError.parseError(let str) {
            loadError = str
        } catch LuaLoadError.fileError(let str) {
            loadError = str
        } catch {
            // Shouldn't happen, but...
            loadError = "Unhandled error \(error)"
        }

        if let loadError {
            let errorString = rewriteError(error: loadError, displayPath: displayPath, realPath: inputFile)
            fputs("\(errorString)\n", stderr)
            exit(1)
        }

        let data = L.dump()!
        L.pop()
        let result = """
            // From \(inputFile)
            let \(variableName): [UInt8] = \(escape(data))
            """
        try! result.write(toFile: outputFile, atomically: true, encoding: .utf8)

    }

    static func makeSources(_ moduleNames: [String], _ modulePaths: [String], _ outputFile: String) {
        let L = LuaState(libraries: [.string])
        defer {
            L.close()
        }

        try! L.load(string: getVariableNameProg)
        // Stack pos 1: getVariableName(moduleName)

        var result = "let lua_sources: [String: [UInt8]] = ["
        var numResultModules = 0

        for (i, moduleName) in moduleNames.enumerated() {
            let modulePath = modulePaths[i]
            if modulePath.hasSuffix("/_.lua") && getFileSize(modulePath) == 0 {
                continue
            }

            L.push(index: 1) // getVariableName
            let variableName: String = "lua_source_" + (try! L.pcall(moduleName))!
            result = result + "\n    \"\(moduleName)\": \(variableName),"
            numResultModules = numResultModules + 1
        }

        if numResultModules == 0 {
            result.append(":]")
        } else {
            result.append("\n]")
        }

        try! result.write(toFile: outputFile, atomically: true, encoding: .utf8)
    }

    static func exitWithSyntax() -> Never {
        print("Syntax: embedlua compile <modulename> <inputfile> <outputfile>")
        print("            Compile a .lua file into a .swift data file")
        print("        embedlua sources <outputfile> [<modulename> <sourcefile>]...")
        print("            Create a LuaSources.swift from the given module names")
        exit(1)
    }

    static let getVariableNameProg = """
        local str = ...
        return str:gsub("[^A-Za-z0-9_]", function(ch)
            return ch == "." and "_" or string.format("_%02X_", string.byte(ch))
        end)
        """

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

    static func rewriteError(error: String, displayPath: String, realPath: String) -> String {
        // Lua uses
        //     DISPLAYNAME:LINENUM: ERRTEXT
        // And we need
        //     FILENAME:LINENUM:CHARPOS: error: ERRTEXT
        // in order for xcode to inline the error correctly.
        let parts = error.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        if parts.count == 3 && parts[0] == displayPath {
            return "\(realPath):\(parts[1]):1: error:\(parts[2])"
        } else {
            return error.replacingOccurrences(of: displayPath, with: realPath)
        }
    }

    static func getFileSize(_ path: String) -> UInt64? {
        guard let attribs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        guard let sz = attribs[.size] as? NSNumber else {
            return nil
        }
        return sz.uint64Value
    }
}
