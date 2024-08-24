// Copyright (c) 2023-2024 Tom Sutcliffe, Jason Morley
// See LICENSE file for license information.

import PackagePlugin
import Foundation

struct PluginError: Error, CustomStringConvertible {
    let description: String
}

func getModuleName(_ path: Path, dirsWithLuaFiles: Set<Path>) -> String {
    var parts: [String] = []
    var currentPath = path
    while !currentPath.string.isEmpty {
        let part = currentPath.lastComponent
        let parent = currentPath.removingLastComponent()
        if !dirsWithLuaFiles.contains(parent) {
            break
        } else {
            parts.insert(part, at: 0)
            currentPath = parent
            // And go round again
        }
    }
    parts[parts.count - 1] = Path(parts.last!).stem
    let moduleName = parts.joined(separator: ".")
    return moduleName
}

func makeCommands(inputs: [Path], workDir: Path, executable: Path) throws -> [Command] {
    // Work out module names
    var dirsWithLuaFiles: Set<Path> = []
    for input in inputs {
        let dirName = input.removingLastComponent()
        dirsWithLuaFiles.insert(dirName)
    }

    var moduleNameMap: [String: Path] = [:]
    for input in inputs {
        let moduleName = getModuleName(input, dirsWithLuaFiles: dirsWithLuaFiles)
        if let existing = moduleNameMap[moduleName] {
            throw PluginError(description: "Duplicate module name: \(existing) and \(input) both map to \(moduleName)")
        }
        moduleNameMap[moduleName] = input
    }
    let sortedModules: [String] = moduleNameMap.keys.sorted()

    var cmds: [Command] = []
    let outPrefix = workDir.appending("LuaSources").string
    var luaSourcesInputs: [Path] = []
    for moduleName in sortedModules {
        let input = moduleNameMap[moduleName]!
        let relPath = moduleName.replacingOccurrences(of: ".", with: "_")
        let output = Path("\(outPrefix)_\(relPath).swift")
        cmds.append(.buildCommand(displayName: "Compiling \(moduleName).lua", executable: executable, arguments: [
            "compile",
            moduleName,
            input,
            output
        ], inputFiles: [input], outputFiles: [output]))
        // Really the inputs to the LuaSources cmd should be the generated .swift files, but the swiftpm
        // dependency tracker really doesn't like that, so the next best thing is to make it dependent on the
        // inputs instead.
        luaSourcesInputs.append(input)
        // debugPrint("\(output) depends on \(input)")
    }

    let luaSourcesOutput = "\(outPrefix).swift"
    var generateArgs = ["sources", luaSourcesOutput] //+ sortedModules
    for moduleName in sortedModules {
        generateArgs.append(moduleName)
        generateArgs.append(moduleNameMap[moduleName]!.string)
    }
    cmds.append(.buildCommand(displayName: "Generating LuaSources.swift", executable: executable,
        arguments: generateArgs,
        inputFiles: luaSourcesInputs,
        outputFiles: [Path(luaSourcesOutput)]))

    debugPrint("\(luaSourcesOutput) depends on \(luaSourcesInputs)")

    return cmds
}

@main
struct EmbedLuaPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let target = target as? SourceModuleTarget else {
            return []
        }
        let inputFiles = target.sourceFiles(withSuffix: ".lua").map { $0.path }
        // debugPrint("inputs: inputFiles)")

        let exe = try context.tool(named: "embedlua").path
        return try makeCommands(inputs: inputFiles, workDir: context.pluginWorkDirectory, executable: exe)
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension EmbedLuaPlugin: XcodeBuildToolPlugin {
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

        let exe = try context.tool(named: "embedlua").path

        // Work around the fact that Xcode is a hot mess---in Catalyst builds, Xcode expands the "${CONFIGURATION}"
        // variable in our tool path incorrectly, giving us "Debug", instead of "Debug-maccatalyst". Unfortuantely, this
        // is compounded by the fact that we don't seem to have any way of detecting our build configuration here, so we
        // simply guess that if the 'embedlua' dependency isn't available, we're probably building for Catalyst.
        // Let's hope this is fixed in the future.
        let fixupExe = if FileManager.default.fileExists(atPath: exe.string) {
            exe
        } else {
            Path(exe.string.replacingOccurrences(of: "${CONFIGURATION}", with: "Debug-maccatalyst"))
        }

        let commands = try makeCommands(inputs: inputFiles, workDir: context.pluginWorkDirectory, executable: fixupExe)

        return commands
    }
}
#endif
