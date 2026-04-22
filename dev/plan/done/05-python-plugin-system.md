# Python 插件系统（F13）— 详细计划

## 概述

为 LingXi 添加 Python 插件支持，允许插件注册搜索源、命令、快捷键，以及通过 WebView 进行交互。Python 代码在主进程内执行（PythonKit + CPython），继承 LingXi 的应用权限。

## 技术选型

| 组件 | 技术 | 说明 |
|------|------|------|
| Python 版本管理 | uv | 用户手动触发安装，由 uv 管理 Python 运行时 |
| Python 嵌入 | PythonKit + CPython C API | dlopen libpython，进程内执行 |
| 桥接层 | `_lingxi_bridge` C 扩展 | 极薄，只暴露 `call` / `call_async` 两个函数 |
| SDK | `lingxi` 纯 Python 包 | 装饰器、类型、async 封装，全部用 Python 编写 |
| 通信协议 | JSON | Swift ↔ Python 之间统一用 JSON 字符串序列化 |
| WebView | WKWebView | 插件可打开交互面板，通过 `postMessage` 双向通信 |

## 架构

```
插件代码 (main.py)
    │  import lingxi
    ▼
lingxi SDK (纯 Python 包)
    │  装饰器、类型定义、async 封装
    │  import _lingxi_bridge
    ▼
_lingxi_bridge (C 扩展，极小)
    │  call(method, json_args) -> json_result        # 同步
    │  call_async(method, json_args, callback)       # 异步
    ▼
Swift PluginBridge
    │  解析 method + JSON，分发到对应 Manager
    ▼
LingXi 核心能力 (SearchRouter / HotKeyManager / PanelManager / ...)
```

### 线程模型

```
Main Thread        │ UI 渲染、SwiftUI、WebView 操作
Swift Task Pool    │ Swift async/await 执行
Python Thread      │ asyncio event loop（长驻）
                   │ - 所有插件协程在此线程调度
                   │ - GIL 在此线程持有
                   │ - 等待 Swift 结果时协程挂起，event loop 调度其他任务
```

### 目录结构

```
App Bundle
  └── Contents/Resources/
        └── (不打包 uv，由用户触发安装)

~/.lingxi/
  ├── bin/uv                              # uv 二进制（用户触发安装）
  ├── python/                             # uv 管理的 Python 运行时
  │     └── cpython-3.12.x-macos/
  │           ├── bin/python3
  │           └── lib/libpython3.12.dylib
  ├── sdk/                                # lingxi Python SDK
  │     └── lingxi/
  │           ├── __init__.py
  │           ├── _bridge.py
  │           ├── decorators.py
  │           ├── models.py
  │           ├── async_support.py
  │           └── webview.py
  └── plugins/                            # 用户插件目录
        └── my-plugin/
              ├── plugin.json
              ├── pyproject.toml
              ├── main.py
              └── webview/
                    ├── index.html
                    └── app.js
```

### 插件元信息 (plugin.json)

```json
{
  "id": "my-plugin",
  "name": "My Plugin",
  "version": "1.0.0",
  "description": "A sample plugin",
  "author": "Author Name",
  "entrypoint": "main.py",
  "min_lingxi_version": "1.0.0"
}
```

---

## 阶段 P1：环境管理

目标：实现 uv 和 Python 运行时的安装管理，提供设置界面入口。

### Step 1.1：Python 环境管理器

**改动：**
- 新建 `LingXi/Plugin/PythonEnvironment.swift`
- 实现 `PythonEnvironment` 类，管理 uv 和 Python 的安装状态
- 核心方法：
  - `var isUVInstalled: Bool` — 检测 `~/.lingxi/bin/uv` 是否存在
  - `var isPythonInstalled: Bool` — 检测 uv 管理的 Python 是否已安装
  - `var pythonPath: String?` — 返回 Python 可执行文件路径
  - `var libPythonPath: String?` — 返回 `libpython3.x.dylib` 路径
  - `func installUV() async throws` — 从 GitHub Releases 下载 uv 二进制到 `~/.lingxi/bin/uv`
  - `func installPython() async throws` — 执行 `~/.lingxi/bin/uv python install 3.12`
  - `func installStatus() -> EnvironmentStatus` — 返回当前安装状态枚举

**验证：**
- [ ] 首次运行时 `isUVInstalled` 和 `isPythonInstalled` 均为 false
- [ ] 调用 `installUV()` 后 uv 二进制出现在 `~/.lingxi/bin/uv`
- [ ] 调用 `installPython()` 后能定位到 `libpython3.12.dylib`
- [ ] 重复安装不报错（幂等）

---

### Step 1.2：设置界面 — Python 环境

**改动：**
- 在 Settings 中新增 "插件" 页签
- 显示 Python 环境状态：未安装 / 安装中 / 已安装
- 未安装时显示 "安装 Python 环境" 按钮，点击后执行 Step 1.1 的安装流程
- 已安装时显示 Python 版本号、路径信息
- 安装过程中显示进度/日志输出

**验证：**
- [ ] 设置界面能正确显示当前安装状态
- [ ] 点击安装按钮后能看到进度，安装完成后状态更新
- [ ] 已安装状态下不再显示安装按钮

---

## 阶段 P2：CPython 加载与 C 桥接

目标：在 Swift 进程内加载 CPython，实现最小化的 `_lingxi_bridge` C 扩展。

### Step 2.1：CPython 运行时加载

**改动：**
- 新建 `LingXi/Plugin/PythonRuntime.swift`
- 使用 `dlopen` 加载 `libpython3.12.dylib`
- 初始化 CPython 解释器：`Py_Initialize()`
- 配置 `PYTHONHOME`（指向 uv 安装的 Python 目录）
- 配置 `sys.path`（添加 SDK 路径和插件路径）
- 在专用线程上启动 asyncio event loop
- 提供关闭方法：`Py_FinalizeEx()`

**注意事项：**
- `Py_Initialize` 必须在 `dlopen` 之后、任何 Python 调用之前执行
- `PYTHONHOME` 必须在 `Py_Initialize` 之前通过 `Py_SetPythonHome` 设置
- PythonKit 的 `PythonLibrary.useLibrary(at:)` 可以指定 dylib 路径

**验证：**
- [ ] 能成功加载 libpython 并初始化解释器
- [ ] `Python.import("sys").version` 返回正确版本号
- [ ] `sys.path` 包含 SDK 目录
- [ ] 应用退出时能正常 finalize

---

### Step 2.2：_lingxi_bridge C 扩展

**改动：**
- 新建 `LingXi/Plugin/LingXiBridge.swift`（使用 CPython C API）
- 创建 Python 模块 `_lingxi_bridge`，注册到 `sys.modules`
- 模块只暴露两个函数：

```
call(method: str, args: str) -> str
    同步调用。args 和返回值都是 JSON 字符串。
    内部：Python → 释放 GIL → Swift 执行 → 获取 GIL → 返回结果

call_async(method: str, args: str, callback: callable) -> None
    异步调用。callback 签名：callback(result_json: str, error: str | None)
    内部：Python 调用后立即返回 → Swift 在 Task 中执行 →
          完成后通过 loop.call_soon_threadsafe 回调
```

- 新建 `LingXi/Plugin/PluginBridge.swift`（Swift 侧的方法分发器）
- `PluginBridge.dispatch(method:args:) async throws -> String`
- 根据 method 名称分发到不同的 handler

**实现要点：**
- `call` 中必须在等待 Swift 结果时释放 GIL（`Py_BEGIN_ALLOW_THREADS` / `Py_END_ALLOW_THREADS`），否则阻塞 event loop
- `call_async` 中 callback 必须通过 `asyncio.loop.call_soon_threadsafe()` 调度，确保在 event loop 线程执行
- 所有 C API 调用需要正确管理引用计数（`Py_INCREF` / `Py_DECREF`）

**验证：**
- [ ] Python 中 `import _lingxi_bridge` 成功
- [ ] `_lingxi_bridge.call("ping", "{}")` 返回 `'{"pong": true}'`
- [ ] `_lingxi_bridge.call_async("ping", "{}", callback)` 正确触发 callback
- [ ] 同步调用不阻塞 asyncio event loop（可用并发测试验证）

---

## 阶段 P3：lingxi Python SDK

目标：实现纯 Python 的 lingxi SDK 包，提供插件开发 API。

### Step 3.1：SDK 核心 — 桥接封装与类型定义

**改动：**
- 新建 `~/.lingxi/sdk/lingxi/` 目录（首次启动时由 App 释放）
- 也可将 SDK 源码放在 App Bundle Resources 中，启动时复制到 `~/.lingxi/sdk/`

文件列表：

**`lingxi/_bridge.py`** — 封装 `_lingxi_bridge` 的底层调用
```python
import json
import _lingxi_bridge

def call(method: str, **kwargs) -> any:
    result_json = _lingxi_bridge.call(method, json.dumps(kwargs))
    return json.loads(result_json)

async def call_async(method: str, **kwargs) -> any:
    import asyncio
    loop = asyncio.get_running_loop()
    future = loop.create_future()

    def on_complete(result_json, error):
        if error:
            loop.call_soon_threadsafe(future.set_exception, RuntimeError(error))
        else:
            loop.call_soon_threadsafe(future.set_result, json.loads(result_json))

    _lingxi_bridge.call_async(method, json.dumps(kwargs), on_complete)
    return await future
```

**`lingxi/models.py`** — 数据类型定义
```python
from dataclasses import dataclass, field, asdict
from typing import Optional

@dataclass
class Action:
    type: str       # "open", "url", "copy", "callback"
    target: str = ""

    @staticmethod
    def open(path: str) -> "Action":
        return Action(type="open", target=path)

    @staticmethod
    def url(url: str) -> "Action":
        return Action(type="url", target=url)

    @staticmethod
    def copy(text: str) -> "Action":
        return Action(type="copy", target=text)

@dataclass
class SearchResult:
    title: str
    subtitle: str = ""
    icon: str = ""              # 文件路径、URL 或系统图标名
    action: Optional[Action] = None
    modifier_actions: dict[str, Action] = field(default_factory=dict)

    def to_dict(self) -> dict:
        return asdict(self)
```

**`lingxi/__init__.py`** — 公共 API 导出
```python
from lingxi.models import SearchResult, Action
from lingxi.decorators import source, command, hotkey
from lingxi import _bridge

# 同步 API
def notify(title: str, body: str = ""):
    _bridge.call("notify", title=title, body=body)

def get_clipboard() -> str:
    return _bridge.call("get_clipboard")

def set_clipboard(text: str):
    _bridge.call("set_clipboard", text=text)

def get_selection() -> str:
    return _bridge.call("get_selection")

def open_url(url: str):
    _bridge.call("open_url", url=url)

# 异步 API
async def search_apps(query: str) -> list[dict]:
    return await _bridge.call_async("search_apps", query=query)

async def search_files(query: str) -> list[dict]:
    return await _bridge.call_async("search_files", query=query)
```

**验证：**
- [ ] 插件中 `import lingxi` 成功
- [ ] `lingxi.notify("test")` 能触发 macOS 通知
- [ ] `lingxi.get_clipboard()` 返回剪贴板内容
- [ ] `await lingxi.search_apps("Safari")` 返回结果列表

---

### Step 3.2：SDK 装饰器 — 注册机制

**改动：**

**`lingxi/decorators.py`** — 装饰器实现
```python
import asyncio
import inspect
from lingxi import _bridge

# 全局注册表，Swift 侧加载插件后读取
_registry = {
    "sources": [],
    "commands": [],
    "hotkeys": [],
}

def source(prefix: str, name: str = "", icon: str = ""):
    """注册搜索源"""
    def decorator(func):
        is_async = asyncio.iscoroutinefunction(func)
        _registry["sources"].append({
            "prefix": prefix,
            "name": name or func.__name__,
            "icon": icon,
            "callback": func,
            "is_async": is_async,
        })
        # 通知 Swift 侧注册
        _bridge.call("register_source", prefix=prefix, name=name or func.__name__, icon=icon)
        return func
    return decorator

def command(name: str, prefix: str = ""):
    """注册命令"""
    def decorator(func):
        _registry["commands"].append({
            "name": name,
            "prefix": prefix,
            "callback": func,
            "is_async": asyncio.iscoroutinefunction(func),
        })
        _bridge.call("register_command", name=name, prefix=prefix)
        return func
    return decorator

def hotkey(shortcut: str):
    """注册快捷键"""
    def decorator(func):
        _registry["hotkeys"].append({
            "shortcut": shortcut,
            "callback": func,
        })
        _bridge.call("register_hotkey", shortcut=shortcut)
        return func
    return decorator
```

**Swift 侧对应 handler：**
- `register_source` → `SearchRouter.register(prefix:id:provider:)` ，provider 为 `PythonPluginProvider`
- `register_command` → 新建 `CommandManager` 管理命令注册和触发
- `register_hotkey` → `HotKeyManager` 注册新快捷键

**验证：**
- [ ] 插件用 `@lingxi.source(prefix="gh")` 注册后，在搜索框输入 `gh xxx` 能触发该插件
- [ ] 插件用 `@lingxi.command(name="test")` 注册后，命令列表中出现该命令
- [ ] 插件用 `@lingxi.hotkey("cmd+shift+g")` 注册后，按快捷键触发回调

---

### Step 3.3：SDK 异步支持

**改动：**

**`lingxi/async_support.py`** — asyncio 桥接工具
```python
import asyncio
from typing import Callable, Any

_loop: asyncio.AbstractEventLoop | None = None
_thread = None

def get_event_loop() -> asyncio.AbstractEventLoop:
    return _loop

def run_plugin_func(func: Callable, *args) -> Any:
    """
    运行插件函数，自动判断同步/异步。
    由 Swift 侧通过 C API 调用。
    """
    if asyncio.iscoroutinefunction(func):
        future = asyncio.run_coroutine_threadsafe(func(*args), _loop)
        return future  # Swift 侧等待 future.result()
    else:
        return func(*args)

def init_event_loop():
    """
    在专用线程上启动 asyncio event loop。
    由 PythonRuntime.swift 在初始化时调用。
    """
    import threading
    global _loop, _thread

    def _run():
        global _loop
        _loop = asyncio.new_event_loop()
        asyncio.set_event_loop(_loop)
        _loop.run_forever()

    _thread = threading.Thread(target=_run, daemon=True)
    _thread.start()

    # 等待 loop 就绪
    import time
    while _loop is None:
        time.sleep(0.01)

def shutdown_event_loop():
    if _loop:
        _loop.call_soon_threadsafe(_loop.stop)
```

**验证：**
- [ ] event loop 在专用线程启动，不阻塞主线程
- [ ] async 插件函数通过 `run_coroutine_threadsafe` 正确执行
- [ ] 多个 async 插件函数可以并发执行（GIL 在 await 时释放）
- [ ] 应用退出时 event loop 正常关闭

---

## 阶段 P4：插件加载与生命周期

目标：实现插件的发现、加载、卸载和错误隔离。

### Step 4.1：PluginManager

**改动：**
- 新建 `LingXi/Plugin/PluginManager.swift`
- 核心职责：
  - 扫描 `~/.lingxi/plugins/` 目录，发现所有含 `plugin.json` 的子目录
  - 解析 `plugin.json`，构建插件描述对象 `PluginDescriptor`
  - 按顺序加载插件：设置 `sys.path` → `import main` → 触发装饰器注册
  - 维护已加载插件列表，支持启用/禁用/重新加载

```swift
struct PluginDescriptor {
    let id: String
    let name: String
    let version: String
    let entrypoint: String
    let directoryURL: URL
}

class PluginManager {
    func discoverPlugins() -> [PluginDescriptor]
    func loadPlugin(_ descriptor: PluginDescriptor) throws
    func unloadPlugin(id: String)
    func reloadPlugin(id: String) throws
    func loadAllPlugins()
}
```

**加载流程：**
1. 将插件目录加入 `sys.path`
2. 如有 `pyproject.toml`，先执行 `uv pip install` 安装依赖（首次或依赖变更时）
3. 在 Python 线程上执行 `importlib.import_module("main")`
4. 模块顶层的 `@lingxi.source` / `@lingxi.command` / `@lingxi.hotkey` 装饰器自动触发注册
5. 捕获所有异常，记录日志，不影响其他插件加载

**验证：**
- [ ] 放置一个示例插件到 `~/.lingxi/plugins/`，启动后自动发现并加载
- [ ] 插件加载失败（语法错误等）不影响其他插件和主程序
- [ ] 禁用插件后其注册的搜索源/命令/快捷键全部移除
- [ ] 重新加载插件后注册信息更新

---

### Step 4.2：插件依赖安装

**改动：**
- 在 `PluginManager.loadPlugin` 中，检测插件目录下是否有 `pyproject.toml`
- 如果有，调用 `uv pip install --project <plugin_dir>` 安装依赖
- 每个插件使用独立的虚拟环境：`~/.lingxi/plugins/<plugin-id>/.venv/`
- 安装结果缓存：记录 `pyproject.toml` 的 hash，未变更时跳过安装

**验证：**
- [ ] 插件声明了第三方依赖（如 requests），首次加载时自动安装
- [ ] 第二次加载同一插件时跳过安装（hash 未变）
- [ ] 修改 `pyproject.toml` 后重新加载触发重新安装
- [ ] 不同插件的依赖互相隔离

---

### Step 4.3：设置界面 — 插件管理

**改动：**
- 在设置的"插件"页签中，已安装 Python 环境后显示插件列表
- 每个插件显示：名称、版本、描述、状态（已启用/已禁用/加载失败）
- 操作：启用/禁用开关、重新加载按钮
- 底部按钮：打开插件目录（在 Finder 中显示 `~/.lingxi/plugins/`）

**验证：**
- [ ] 插件列表正确显示所有已发现的插件
- [ ] 开关能正确启用/禁用插件
- [ ] 加载失败的插件显示错误信息
- [ ] "打开插件目录"按钮正确跳转

---

## 阶段 P5：搜索源集成

目标：Python 插件注册的搜索源能完整集成到 LingXi 搜索流程。

### Step 5.1：PythonPluginProvider

**改动：**
- 新建 `LingXi/Plugin/PythonPluginProvider.swift`
- 实现 `SearchProvider` 协议
- `search(query:)` 方法在 Python 线程上调用插件的搜索函数
- 支持同步和异步两种插件搜索函数
- 将 Python 返回的 dict list 转换为 `[SearchResult]`

```swift
final class PythonPluginProvider: SearchProvider, @unchecked Sendable {
    let pluginId: String
    let callback: PythonObject  // Python 侧的搜索函数引用
    let isAsync: Bool
    var debounceMilliseconds: Int
    var timeoutMilliseconds: Int = 5000

    func search(query: String) async -> [SearchResult] {
        // 1. 在 Python 线程调用 callback(query)
        // 2. 如果 isAsync，通过 run_coroutine_threadsafe 执行
        // 3. 解析返回的 JSON → [SearchResult]
        // 4. 超时保护
    }
}
```

**结果映射：**
- Python `SearchResult.to_dict()` → JSON → Swift `SearchResult`
- `action.type` 映射：
  - `"open"` → `NSWorkspace.shared.open(URL(fileURLWithPath:))`
  - `"url"` → `NSWorkspace.shared.open(URL(string:)!)`
  - `"copy"` → `NSPasteboard.general.setString(...)`
  - `"callback"` → 回调到 Python 函数

**验证：**
- [ ] Python 搜索源注册后，输入对应前缀能触发搜索
- [ ] 同步搜索函数正常工作
- [ ] 异步搜索函数正常工作
- [ ] 搜索结果的图标、标题、副标题正确显示
- [ ] 执行搜索结果的动作（打开、复制等）正常工作
- [ ] 搜索超时不阻塞 UI

---

## 阶段 P6：命令与快捷键集成

目标：Python 插件注册的命令和快捷键能正常触发。

### Step 6.1：CommandManager

**改动：**
- 新建 `LingXi/Plugin/CommandManager.swift`
- 管理命令的注册和触发
- 命令可通过搜索框输入前缀触发，或出现在命令列表中
- 内部实现为特殊的 `SearchProvider`，搜索结果的执行动作是调用 Python 回调

```swift
class CommandManager {
    func register(name: String, prefix: String, pluginId: String, callback: PythonObject)
    func unregister(pluginId: String)  // 移除该插件的所有命令
    func execute(commandId: String, query: String) async
}
```

**验证：**
- [ ] 插件注册的命令出现在搜索结果中
- [ ] 选择命令后正确执行 Python 回调
- [ ] 卸载插件后命令自动移除

---

### Step 6.2：快捷键注册集成

**改动：**
- 扩展 `HotKeyManager`，支持动态注册/注销快捷键
- Python 插件通过 `@lingxi.hotkey("cmd+shift+g")` 注册的快捷键
  → Swift 侧解析快捷键字符串
  → 调用 `HotKeyManager.register(shortcut:handler:)`
- 卸载插件时自动注销对应快捷键

**快捷键字符串解析：**
- 格式：`"cmd+shift+g"`、`"alt+space"`、`"ctrl+shift+k"` 等
- 解析为 `CGEventFlags` + `CGKeyCode`

**验证：**
- [ ] 插件注册的快捷键在全局生效
- [ ] 按下快捷键正确触发 Python 回调
- [ ] 卸载插件后快捷键自动注销
- [ ] 快捷键冲突时给出警告

---

## 阶段 P7：WebView 交互

目标：插件可以打开 WebView 面板，通过双向消息进行交互。

### Step 7.1：PluginWebView 面板

**改动：**
- 新建 `LingXi/Plugin/PluginWebView.swift`
- 创建 WKWebView 窗口，加载插件目录下的 HTML 文件
- 支持 `plugin://` URL scheme，解析为插件目录下的本地文件路径
- 窗口大小可配置

```swift
class PluginWebView {
    func open(pluginId: String, htmlPath: String, width: CGFloat, height: CGFloat)
    func close()
    func sendMessage(_ message: [String: Any])  // Swift → JS
}
```

**验证：**
- [ ] `lingxi.open_webview(url="plugin://my-plugin/index.html")` 打开窗口
- [ ] WebView 正确加载插件目录下的 HTML/CSS/JS
- [ ] `lingxi.close_webview()` 关闭窗口

---

### Step 7.2：双向消息通信

**改动：**

**JS → Python 方向：**
- WKWebView 注入 `window.lingxi.postMessage(data)` 接口
- 通过 `WKScriptMessageHandler` 接收消息
- Swift 转发到 Python 侧插件注册的 `on_message` 回调

**Python → JS 方向：**
- `lingxi.send_to_webview(data)` → `_bridge.call("send_to_webview", data=data)`
- Swift 侧调用 `webView.evaluateJavaScript("window.onLingXiMessage(\(json))")`

**JS 侧 API：**
```javascript
// 发送消息给 Python 插件
window.lingxi.postMessage({ action: "submit", code: "..." });

// 接收来自 Python 插件的消息
window.onLingXiMessage = function(data) {
    console.log("Received:", data);
};
```

**验证：**
- [ ] JS 调用 `postMessage` 后 Python 的 `on_message` 收到数据
- [ ] Python 调用 `send_to_webview` 后 JS 的 `onLingXiMessage` 收到数据
- [ ] 消息中的复杂 JSON 结构正确传递（嵌套对象、数组、中文）
- [ ] WebView 关闭后消息不再传递，不报错

---

## 阶段 P8：内置能力 API

目标：完善 lingxi SDK 的内置能力，供插件调用。

### Step 8.1：剪贴板与通知

**改动：**

在 `PluginBridge.dispatch` 中实现以下 method handler：

| SDK 方法 | bridge method | Swift 实现 |
|----------|--------------|-----------|
| `lingxi.get_clipboard()` | `get_clipboard` | `NSPasteboard.general.string(forType: .string)` |
| `lingxi.set_clipboard(text)` | `set_clipboard` | `NSPasteboard.general.setString(...)` |
| `lingxi.notify(title, body)` | `notify` | `UNUserNotificationCenter` |
| `lingxi.open_url(url)` | `open_url` | `NSWorkspace.shared.open(URL)` |
| `lingxi.get_selection()` | `get_selection` | Accessibility API 获取选中文本 |

**验证：**
- [ ] 每个 API 在插件中调用正常工作
- [ ] 权限不足时（如 Accessibility）返回明确的错误信息

---

### Step 8.2：搜索能力调用

**改动：**

允许插件调用 LingXi 已有的搜索能力：

| SDK 方法 | bridge method | Swift 实现 |
|----------|--------------|-----------|
| `await lingxi.search_apps(query)` | `search_apps` | `ApplicationSearchProvider.search()` |
| `await lingxi.search_files(query)` | `search_files` | `FileSearchProvider.search()` |
| `await lingxi.search_bookmarks(query)` | `search_bookmarks` | `BookmarkSearchProvider.search()` |

**验证：**
- [ ] 插件中 `await lingxi.search_apps("Safari")` 返回结果
- [ ] 返回的数据结构包含 title、subtitle、icon 等字段
- [ ] 搜索超时时 async 函数正常抛出异常

---

## 阶段 P9：安全与稳定性

### Step 9.1：错误隔离

**改动：**
- 所有 Python 插件调用都包裹在 try/except 中（Python 侧）
- Swift 侧捕获 Python 异常，转换为日志，不传播到主程序
- 插件连续崩溃 N 次后自动禁用，在设置界面提示
- 搜索超时保护：单个插件搜索超过 `timeoutMilliseconds` 后取消

**验证：**
- [ ] 插件抛出异常不影响主程序和其他插件
- [ ] 插件死循环（不 await）被超时机制终止
- [ ] 连续崩溃的插件被自动禁用

---

### Step 9.2：资源限制

**改动：**
- 限制单个插件的内存使用（通过监控 Python 的 tracemalloc）
- 限制 WebView 的数量（同一时间最多一个插件 WebView）
- 限制快捷键注册数量（每个插件最多 N 个）

**验证：**
- [ ] 超出限制时给出明确错误提示
- [ ] 不影响其他插件和主程序

---

## 实现顺序总结

| 阶段 | 内容 | 依赖 |
|------|------|------|
| P1 | 环境管理（uv + Python 安装） | 无 |
| P2 | CPython 加载 + C 桥接 | P1 |
| P3 | lingxi Python SDK | P2 |
| P4 | 插件加载与生命周期 | P3 |
| P5 | 搜索源集成 | P4 |
| P6 | 命令与快捷键集成 | P4 |
| P7 | WebView 交互 | P4 |
| P8 | 内置能力 API | P2 |
| P9 | 安全与稳定性 | P5-P8 |

P5、P6、P7、P8 之间无强依赖，可以并行开发。

---

## 示例插件

以下是一个完整的示例插件，展示各项能力：

```
~/.lingxi/plugins/github-search/
├── plugin.json
├── pyproject.toml
└── main.py
```

**plugin.json:**
```json
{
  "id": "github-search",
  "name": "GitHub Search",
  "version": "1.0.0",
  "description": "Search GitHub repositories",
  "author": "LingXi Community",
  "entrypoint": "main.py"
}
```

**pyproject.toml:**
```toml
[project]
name = "github-search"
version = "1.0.0"
dependencies = ["aiohttp>=3.9"]
```

**main.py:**
```python
import lingxi
import aiohttp

@lingxi.source(prefix="gh", name="GitHub Search", icon="github.png")
async def search(query: str) -> list[lingxi.SearchResult]:
    if len(query) < 2:
        return []

    async with aiohttp.ClientSession() as session:
        url = f"https://api.github.com/search/repositories?q={query}&per_page=10"
        async with session.get(url) as resp:
            data = await resp.json()

    return [
        lingxi.SearchResult(
            title=repo["full_name"],
            subtitle=repo.get("description", ""),
            action=lingxi.Action.url(repo["html_url"]),
            modifier_actions={
                "cmd": lingxi.Action.copy(repo["clone_url"]),
            },
        )
        for repo in data.get("items", [])
    ]

@lingxi.hotkey("cmd+shift+g")
def quick_github():
    text = lingxi.get_selection()
    if text:
        lingxi.open_url(f"https://github.com/search?q={text}")
```
