# LingXi 语音输入 Phase 2 计划

> **状态：未开始。**
>
> 前置：Phase 1（按住 Fn 说话 → 转写 → 直接粘贴）已于 2026-08-14 完成，commit 66c61bc。
> 核心代码位于 `LingXi/Voice/`，状态机为 `VoiceInputController`（MainActor + 代际号），
> ASR 双后端（Apple Speech / Whisper API）通过 `SpeechTranscriber` 协议接入。

## 目标

在 Phase 1 的直接粘贴管线上，补齐三块用户体验：

1. **浮动 HUD**：录音时给出可视反馈（状态、电平、实时识别中间文本），替代目前仅菜单栏图标变化的弱反馈
2. **LLM 增强**：转写完成后可选地经 LLM 校对/润色（口语转书面、去语气词、修标点）
3. **预览面板**：粘贴前展示最终文本，回车确认 / Esc 丢弃，避免错误文本直接进入前台应用

## 设计原则

1. **极简优先**：参考 WenZi 但大幅裁剪——不做多模式切换、动态热词、会话历史、文本 diff；单一可编辑 prompt 即可
2. **每步可关**：HUD、增强、预览各自独立开关；全部关闭时行为与 Phase 1 完全一致（直接粘贴）
3. **失败降级**：LLM 增强失败/超时一律回退到原始转写文本，绝不因增强丢掉一次录音
4. **并发纪律不变**：所有新状态转移仍只发生在 MainActor；新增异步阶段（增强请求、预览等待）全部纳入现有代际号机制；跨 await 回调第一行比对 gen
5. **复用已有基础设施**：非激活面板参考 `PanelManager.createPanel()` / `LeaderKeyPanel`，HTTP 复用 `WhisperAPITranscriber` 的 URLSession 注入 + RequestBuilder 纯函数模式，粘贴复用 `prepareTransientPasteboard` + `simulatePaste`

## 状态机扩展

Phase 1：`idle → starting → recording → transcribing → idle`

Phase 2 在 `transcribing` 之后插入两个可选状态：

```
transcribing ──转写完成──▶ [enhancing] ──增强完成/失败降级──▶ [previewing] ──Enter──▶ 粘贴 → idle
                │(增强关闭)                  │(预览关闭)                      │Esc/超时
                └──────────────────────────▶│──────────────▶ 直接粘贴 → idle  └────▶ idle（丢弃）
```

转移规则：

| 状态 | 事件 | 动作 → 新状态 |
|---|---|---|
| transcribing | done(text) 且增强开启 | 发起 LLM 请求（带 gen）→ **enhancing** |
| transcribing | done(text) 且增强关闭 | 预览开启→ **previewing**；否则粘贴→ idle |
| enhancing | enhanceDone(gen, text) | 预览开启→ **previewing**；否则粘贴→ idle |
| enhancing | enhanceFailed(gen, error) | log + **降级用原始转写文本**，走同样的预览/粘贴分支 |
| enhancing | 增强看门狗(gen, 15s) | 同 enhanceFailed 降级 |
| previewing | Enter / 点击确认 | activate previousApp + 粘贴 → idle |
| previewing | Esc / 点击关闭 | 丢弃 → idle |
| previewing | fnDown | 丢弃当前预览，直接开新录音会话（gen+1）|
| enhancing / previewing | 陈旧回调（gen 不符）| 丢弃，仅自清理 |

`VoiceActivityModel.Phase` 相应增加 `enhancing`（菜单栏图标沿用 `waveform` 或加 `sparkles`）。

---

## 阶段 A：浮动 HUD

### 工作内容

1. **`SpeechTranscriptionSession` 协议扩展 partial 回调**

   ```swift
   protocol SpeechTranscriptionSession: AnyObject, Sendable {
       // 既有 append/finish/cancel ...
       /// Called on an arbitrary queue with the latest partial text.
       /// Implementations without streaming support may never call it.
       nonisolated func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void)
   }
   ```

   - `AppleSpeechSession`：识别回调里已有 `latestText`，锁内取 handler 后调用（注意与 continuation 同样的锁纪律）
   - `WhisperAPISession`：空实现（批式后端无 partial）

2. **电平采集**：`VoiceInputController.fnDown` 组装 sink 时叠加 RMS 计算：

   ```swift
   sink: { buffer in
       newSession.append(buffer)
       levelMeter.ingest(buffer)   // nonisolated，轻量 RMS，内部节流 ~100ms
   }
   ```

   - 新文件 `LingXi/Voice/AudioLevelMeter.swift`：`final class ... @unchecked Sendable`，RMS 计算在实时线程完成（只做乘加，无分配），节流后 `DispatchQueue.main.async` 更新 `VoiceActivityModel.level: Double`

3. **HUD 面板** `LingXi/Voice/VoiceHUDPanel.swift`
   - `NSPanel`，styleMask 含 `.nonactivatingPanel` + borderless，`level = .statusBar`，`ignoresMouseEvents = true`，不可成为 key window（纯展示）
   - 位置：主屏底部居中（参考 `LeaderKeyPanel` 的定位代码）
   - 内容：SwiftUI（`NSHostingView`）——录音红点/波形动画（绑定 `VoiceActivityModel.level`）+ partial 文本单行滚动；transcribing/enhancing 阶段显示对应状态文案
   - 显示/隐藏由 `VoiceInputController` 在状态转移处驱动；`voiceHUDEnabled == false` 时完全不创建

4. **设置**：`AppSettings.voiceHUDEnabled: Bool = true`，VoiceSettingsView 加 Toggle

### 验证

- 单测：`AudioLevelMeter` RMS 与节流逻辑（纯函数部分）；FakeSession 验证 partial handler 被 controller 正确接线到 activityModel
- 手测：录音时 HUD 出现、电平跳动、Apple 后端实时出字、不抢焦点（当前输入框光标不丢）、Esc/短按等取消路径 HUD 正确消失

---

## 阶段 B：LLM 增强

### 工作内容

1. **协议与实现** `LingXi/Voice/TextEnhancer.swift`

   ```swift
   protocol TextEnhancer: Sendable {
       func enhance(_ text: String) async throws -> String
   }

   struct LLMEnhancerConfiguration: Sendable {
       var baseURL: String        // OpenAI 兼容 /chat/completions
       var apiKey: String
       var model: String
       var systemPrompt: String   // 可编辑，默认校对 prompt
       var timeout: TimeInterval = 15
   }

   final class LLMTextEnhancer: TextEnhancer, @unchecked Sendable {
       init(configuration: LLMEnhancerConfiguration, urlSession: URLSession? = nil)
       // @concurrent 内：POST {base}/chat/completions
       // body: {model, messages: [{role:system, prompt},{role:user, text}], temperature: 0.2, stream: false}
       // 解析 choices[0].message.content
   }
   ```

   - `EnhanceRequestBuilder` 抽 nonisolated 纯函数（同 `WhisperRequestBuilder` 模式，可单测）
   - 默认 system prompt（中文场景）：修正同音字/标点/去语气词，**只输出修正后的文本**，不解释

2. **状态机接入**：`VoiceInputController` 增 `enhancing` 状态、`enhanceDidFinish(gen:result:)`、15s 看门狗（模式与转写看门狗一致，超时=降级不是丢弃）
   - enhancer 经工厂闭包注入（同 transcriberFactory），每次会话按当前设置创建

3. **设置**：`voiceEnhanceEnabled(false)` / `voiceEnhanceBaseURL` / `voiceEnhanceAPIKey` / `voiceEnhanceModel` / `voiceEnhancePrompt`；VoiceSettingsView 增加折叠分节（默认沿用 Whisper API 的 baseURL/key 作为占位提示，但独立存储——本地 Ollama 是常见组合：ASR 走云、增强走本地）

### 验证

- 单测：RequestBuilder 结构断言；URLProtocol mock 正常/非 2xx/超时/坏 JSON；FakeEnhancer 注入状态机——增强成功粘贴增强文本、失败降级粘贴原文、看门狗降级、陈旧 enhanceDone 被丢弃（gen 机制）
- 手测：接本地 Ollama 与一个云端点各跑通一次；增强中拔网线验证降级

---

## 阶段 C：预览面板

### 工作内容

1. **面板** `LingXi/Voice/VoicePreviewPanel.swift`
   - 参考 `PanelManager.createPanel()`：`.nonactivatingPanel`，**可成为 key window**（需要接收 Enter/Esc），`makeKeyAndOrderFront` 不激活 app
   - 进入 previewing 前记录 `NSWorkspace.shared.frontmostApplication`（同 PanelManager.previousApp 模式）
   - 内容：结果文本（可编辑 TextEditor，用户可手改）+ 底部提示 "⏎ 粘贴 · Esc 取消"；增强开启时提供"显示原文"小切换（只读对照，不做 diff）
   - Enter：关面板 → `previousApp?.activate()` → 延迟 ~150ms → 写剪贴板 + `simulatePaste()`（对齐 `pasteAndActivate` 的时序）
   - Esc / 失焦点击关闭：丢弃

2. **状态机接入**：`previewing(text:original:)` 状态；面板回调（confirm/cancel）带 gen 回状态机；previewing 中 fnDown = 丢弃并开新会话

3. **设置**：`voicePreviewEnabled: Bool = false`（默认关，保持 Phase 1 直接粘贴的爽快；文档里说明开启场景）

### 验证

- 单测：FakePanel 注入——Enter 粘贴（含用户编辑后的文本）、Esc 丢弃、previewing 中 fnDown 开新会话、陈旧确认回调被丢弃
- 手测：预览面板不抢当前 app 焦点但能收键；确认后粘贴回原 app；多屏/全屏 app 下面板位置正确

---

## 实施顺序与依赖

1. **阶段 B（LLM 增强）先行**：纯逻辑 + 状态机扩展，无 UI 依赖，单测覆盖率最高，且是三者中用户价值最直接的
2. **阶段 C（预览面板）**：依赖 B 的状态机扩展（previewing 在 enhancing 之后）
3. **阶段 A（HUD）**：独立于 B/C，可并行或最后做；涉及协议扩展（partial 回调）需同步改两个 session 实现与测试 fake

每阶段完成后跑全量单测：

```bash
xcodebuild test -scheme LingXi -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LingXiTests
```

## 风险与已知取舍

- **previewing 无超时**：面板可长期停留，用户下次按 Fn 会自动丢弃开新会话；如反馈困扰再加自动关闭
- **增强 API key 仍明文存 UserDefaults**：与 Whisper API key 一致，Keychain 迁移作为独立任务另行安排
- **HUD 的 partial 回调**给 `AppleSpeechSession` 增加一条新的锁内路径，注意保持 "resume-once + handler 锁外调用" 纪律，避免在锁内回调用户代码
- **可编辑预览 + 增强降级**组合下文本来源有三种（原文/增强/手改），粘贴一律以面板当前文本为准，状态机不区分来源
- WenZi 的多模式（翻译/自定义指令）、动态热词、会话历史**明确不做**，如有需求作为 Phase 3 评估
