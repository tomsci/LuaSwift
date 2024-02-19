// Copyright (c) 2023-2024 Tom Sutcliffe, Jason Morley
// See LICENSE file for license information.

import PackagePlugin
import Foundation

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

func makeCommand(inputs: [Path], workDir: Path) -> (outputs: [Path], args: [String])? {
    var base: String? = nil
    for inputFile in inputs {
        base = commonBase(path: inputFile.string, prevBase: base)
        if base == nil {
            fatalError("No common base found between source files")
        }
    }
    guard let base else {
        // Only way to hit this is if there are no Lua files, in which case no commands needed
        return nil
    }
    let basePrefix = base + "/"
    // debugPrint("Common base: \(basePrefix)")

    var outputs: [Path] = [
        workDir.appending("LuaSources.swift")
    ]
    var args: [String] = [
        workDir.string
    ]
    let outPrefix = workDir.appending("LuaSources").string
    for inputFile in inputs {
        let relPath = substring(inputFile.string, start: basePrefix.count).replacingOccurrences(of: "/", with: "_")
        let output = "\(outPrefix)_\(relPath).swift"
        // debugPrint("Output: \(output)")
        outputs.append(Path(output))
        args.append(inputFile.string)
    }

    return (outputs: outputs, args: args)
}

@main
struct EmbedLuaPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let target = target as? SourceModuleTarget else {
            return []
        }
        let inputFiles = target.sourceFiles(withSuffix: ".lua").map { $0.path }
        // debugPrint("inputs: inputFiles)")

        guard let cmd = makeCommand(inputs: inputFiles, workDir: context.pluginWorkDirectory) else {
            return []
        }

        return [.buildCommand(displayName: "Compiling Lua sources",
                              executable: try context.tool(named: "embedlua").path,
                              arguments: cmd.args,
                              inputFiles: inputFiles,
                              outputFiles: cmd.outputs)]
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension EmbedLuaPlugin: XcodeBuildToolPlugin {
    /// This entry point is called when operating on an Xcode project.
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        // debugPrint(target)
        let inputFiles = target.inputFiles.compactMap { file in
            if file.path.extension == "lua" {
                return file.path
            } else {
                return nil
            }
        }
        // debugPrint(inputFiles)

        guard let cmd = makeCommand(inputs: inputFiles, workDir: context.pluginWorkDirectory) else {
            return []
        }

        return [.buildCommand(displayName: "Compiling Lua sources",
                              executable: try context.tool(named: "embedlua").path,
                              arguments: cmd.args,
                              inputFiles: inputFiles,
                              outputFiles: cmd.outputs)]
    }
}
#endif
