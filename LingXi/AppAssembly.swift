import Foundation

@MainActor
final class AppAssembly {
    struct Result {
        let panelManager: PanelManager
        let pluginManager: PluginManager
    }

    static func assemble(settings: AppSettings) async -> Result {
        let database = await DatabaseManager(databasePath: DatabaseManager.defaultDatabasePath())

        let appModule = ApplicationModule()
        let fileSearchModule = FileSearchModule()
        let bookmarkModule = BookmarkModule()
        let systemSettingsModule = SystemSettingsModule()

        let router = SearchRouter(defaultProvider: appModule.defaultProvider, maxResults: settings.maxSearchResults)

        let clipboardStore = ClipboardStore(
            database: database,
            capacity: settings.clipboardHistoryCapacity,
            imageDirectory: ClipboardStore.defaultImageDirectory
        )

        let snippetStore = SnippetStore()
        let snippetModule = SnippetModule(store: snippetStore)
        let leaderKeyManager = LeaderKeyManager()

        let pluginManager = PluginManager(router: router)

        let clipboardModule = ClipboardModule(store: clipboardStore, pluginManager: pluginManager)
        let commandModule = CommandModule(pluginManager: pluginManager)

        let modules: [SearchProviderModule] = [
            appModule,
            fileSearchModule,
            bookmarkModule,
            systemSettingsModule,
            clipboardModule,
            snippetModule,
            commandModule
        ]

        for module in modules {
            module.register(router: router, settings: settings)
        }

        await pluginManager.loadAll()
        for module in modules {
            if let aware = module as? PluginAwareModule {
                await aware.afterPluginsLoaded()
            }
        }

        let viewModel = await SearchViewModel(router: router, database: database)

        let panelManager = PanelManager(
            settings: settings,
            router: router,
            viewModel: viewModel,
            pluginService: pluginManager,
            snippetModule: snippetModule,
            leaderKeyManager: leaderKeyManager,
            modules: modules
        )

        for module in modules {
            module.bindEvents(to: viewModel, context: panelManager)
        }

        return Result(panelManager: panelManager, pluginManager: pluginManager)
    }
}
