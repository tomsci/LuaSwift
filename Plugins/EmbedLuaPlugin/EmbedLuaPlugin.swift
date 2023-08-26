// Copyright (c) 2023 Tom Sutcliffe, Jason Morley
// See LICENSE file for license information.

import PackagePlugin

@main
struct EmbedLuaPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let target = target as? SourceModuleTarget else {
            return []
        }
        // let inputPath = target.directory
        let inputFiles = target.sourceFiles(withSuffix: "lua")
            .map { $0.path }
        let outputPath = context.pluginWorkDirectory.appending("LuaSources.swift")
        return [.buildCommand(displayName: "Generating \(outputPath.lastComponent) from Lua sources",
                              executable: try context.tool(named: "embedlua").path,
                              arguments: [outputPath] + inputFiles,
                              inputFiles: inputFiles,
                              outputFiles: [outputPath])]
    }
}
