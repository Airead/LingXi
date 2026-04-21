# LingXi Architecture

## Overview

LingXi is a modular macOS search launcher built around a composition root pattern. All service wiring is centralized in `AppAssembly`, making the entry point (`LingXiApp`) purely declarative.

## Composition Root

```
LingXiApp
└── AppAssembly.assemble()
    ├── PluginManager          (global service, PluginService protocol)
    ├── DatabaseManager
    ├── SearchRouter
    ├── SearchViewModel
    ├── PanelManager           (panel lifecycle, implements PanelContext)
    └── modules: [SearchProviderModule]
        ├── ApplicationModule
        ├── FileSearchModule
        ├── BookmarkModule
        ├── SystemSettingsModule
        ├── ClipboardModule
        ├── SnippetModule
        └── CommandModule
```

## Adding a New Search Provider

To add a new provider without touching `PanelManager`:

1. Create a new type conforming to `SearchProviderModule`.
2. Implement `register(router:settings:)` to add the provider to `SearchRouter`.
3. Implement `applySettings(_:router:)` if the provider has configurable prefixes or enable/disable toggles.
4. Implement `bindEvents(to:context:)` if the provider needs to respond to user actions (e.g. paste, delete).
5. Implement `PluginAwareModule` if the provider depends on plugin loading.
6. Append the new module to the array in `AppAssembly.assemble()`.

No changes to `PanelManager` or `LingXiApp` are required.

## Key Protocols

### SearchProviderModule

The core protocol for all search modules. Each module encapsulates a single provider or a group of related providers, along with their settings, event bindings, and lifecycle.

### PanelContext

Exposes panel operations to modules. Implemented by `PanelManager` so modules can:
- Access the previously active application (`previousApp`).
- Paste content and return focus (`pasteAndActivate`).
- Hide the panel (`hidePanel`).

### PluginAwareModule

Optional protocol for modules that need to react after all Lua plugins have been loaded (e.g. registering plugin commands).

### PluginService

Abstraction over `PluginManager` for event dispatch. Used by `ClipboardModule` to notify plugins of clipboard changes without depending on the concrete `PluginManager` type.
