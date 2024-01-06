// Copyright (c) 2023-2024 Tom Sutcliffe, Jason Morley
// See LICENSE file for license information.

import PackagePlugin

@main
struct EmbedLuaPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let target = target as? SourceModuleTarget else {
            return []
        }
        let inputFiles = target.sourceFiles(withSuffix: ".lua")
            .map { $0.path }
        // debugPrint("inputs: inputFiles)")
        let outputPath = context.pluginWorkDirectory.appending("LuaSources.swift")
        return [.buildCommand(displayName: "Generating \(outputPath.lastComponent) from Lua sources",
                              executable: try context.tool(named: "embedlua").path,
                              arguments: [outputPath] + inputFiles,
                              inputFiles: inputFiles,
                              outputFiles: [outputPath])]
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
        let outputPath: Path = context.pluginWorkDirectory.appending("LuaSources.swift")
        return [.buildCommand(displayName: "Generating \(outputPath.lastComponent) from Lua sources",
                              executable: try context.tool(named: "embedlua").path,
                              arguments: [outputPath] + inputFiles,
                              inputFiles: inputFiles,
                              outputFiles: [outputPath])]
    }
}
#endif
