# LingXi 语音输入 Phase 3 计划

> **状态：已完成（2026-08-14）。**
>
> - 阶段 A（多 Provider 模型层）：commit bfadfbc
> - 阶段 B（提示词模式）：commit 8573e81
> - 阶段 C（预览面板增强）：commit 11cc377
> - 阶段 D（对话历史）：commit 21a2791
>
> 实现说明（与计划的差异）：
> - 面板内 ⌘1-9 / 模型下拉的切换会持久化到 `voiceEnhanceMode` / `voiceLLMSelection`（作为新会话默认值），而非仅会话内生效
> - 重增强期间按 Enter 确认会被忽略（需等待完成或 Esc），首版接受
>
> 前置：Phase 2（LLM 增强 / 预览面板 / 浮动 HUD）已于 2026-08-14 完成，commit 9bc86ef。
> 状态机 `VoiceInputController`（MainActor + 代际号），增强协议 `TextEnhancer`，
> 预览协议 `VoicePreviewPresenting`，设置存 UserDefaults（可注入 defaults）。

## 目标

参考 WenZi 的 AI 增强体系，在 Phase 2 基础上补齐四块能力：

1. **多 ASR 模型**：Apple Speech + 多个 OpenAI 兼容远程 provider × 多 model，配置与切换
2. **多 LLM 模型**：多 provider × 多 model 配置与切换
3. **提示词模式**：增强 prompt 以 Markdown 模式文件管理（`~/.config/LingXi/enhance_modes/`），可增删改，预览面板内 `⌘1-9` 快速切换并重新增强
4. **对话历史**：JSONL 记录每次会话，将用户确认过的最终文本按模式注入增强 prompt，提高纠错一致性

## 已确认的范围裁剪（2026-08-14 与用户确认）

| 项 | 决定 |
|---|---|
| 链式模式（steps） | **不做**。模式文件遇到 `steps` 字段忽略并 log，格式向前兼容 |
| 面板内 STT 切换/重转写 | **推迟到 Phase 3.5**（需要每会话保留音频并重喂 ASR）。首版面板只做 LLM 模型与模式切换 |
| 历史浏览器 UI | **不做**。JSONL 文件本身可读可 grep |
| API key 存储 | **维持明文 UserDefaults**。Keychain 迁移仍是独立任务 |
| 音频播放/保存、Google 翻译按钮 | **不做** |
| 词库（vocabulary） | **不做**（需求明确排除） |

## 目录约定（对齐 WenZi 的 XDG 划分）

| 类型 | 路径 | 内容 |
|---|---|---|
| 配置 | `~/.config/LingXi/enhance_modes/` | 提示词模式文件（用户可手编） |
| 数据 | `~/.local/share/LingXi/` | `conversation_history.jsonl` + `conversation_history_archives/` |
| 缓存 | `~/.cache/LingXi/` | 现状不变（`RegistryManager.cacheDirectory`） |

所有目录在代码中可注入（测试用临时目录，绝不触碰真实路径）。

## 设计原则

1. **沿用 Phase 1/2 骨架**：状态机、代际号、工厂注入、`TextEnhancer`/`VoicePreviewPresenting`/`VoiceHUDPresenting` 协议只扩展不推翻
2. **不引入本地 ASR 模型**：WenZi 的 FunASR/MLX/sherpa 属 Python 生态；LingXi 的多 ASR = Apple Speech（内置）+ 远程 OpenAI 兼容端点
3. **配置结构化**：provider 列表用 Codable 结构 JSON 编码存 UserDefaults；坏数据回退默认值
4. **失败降级**：模式文件缺失回退第一个可用模式；provider 被删回退 Apple Speech / 第一个可用 LLM；历史读写失败不阻塞增强
5. **提示词缓存友好**：对话历史注入采用 WenZi 的追加式构建（前缀稳定，达阈值才重建）

---

## 阶段 A：多 Provider 模型层（ASR + LLM）

### 工作内容

1. **新文件 `LingXi/Voice/VoiceProviders.swift`**

   ```swift
   struct VoiceProvider: Codable, Sendable, Identifiable {
       var name: String          // 唯一 ID，如 "groq"、"ollama"
       var baseURL: String
       var apiKey: String
       var models: [String]
   }

   enum ASRSelection: Codable, Sendable, Equatable {
       case apple
       case remote(provider: String, model: String)
   }

   struct LLMSelection: Codable, Sendable, Equatable {
       var provider: String
       var model: String
   }
   ```

2. **AppSettings 扩展**：`voiceASRProviders` / `voiceLLMProviders`（JSON Data 编解码）、`voiceASRSelection` / `voiceLLMSelection`
   - **迁移**：旧 `voiceAPIBaseURL/Key/Model` → 一条 ASR provider + selection；旧 `voiceEnhanceBaseURL/Key/Model` → 一条 LLM provider + selection；迁移只在新 key 不存在时执行一次
3. **工厂改造**：`defaultTranscriberFactory` / `defaultEnhancerFactory` 按 selection 解析 provider 构造 `WhisperAPITranscriber` / `LLMTextEnhancer`（这两个类不改）；解析失败降级（ASR → Apple，LLM → 第一个可用，均 log）
4. **设置 UI（VoiceSettingsView 重构）**
   - STT 分节：Apple Speech + 所有远程 provider×model 平铺单选（当前项高亮）
   - LLM 分节：所有 provider×model 平铺单选
   - Provider 管理 sheet：name / baseURL / apiKey / models（多行文本），Add / Edit / Remove；不能删除当前激活的 provider
   - **Verify 按钮**：ASR 发一段短静音 WAV 到 `/audio/transcriptions`；LLM 发一条短 completion 到 `/chat/completions`

### 验证

- 单测：Codable 往返；迁移逻辑（有旧配置/无旧配置/已迁移不重复）；selection 解析与降级；Verify 的 URLProtocol mock（成功/401/超时）
- 手测：添加 Groq + Ollama 各一条，切换后录音走对应端点

---

## 阶段 B：提示词模式（enhance modes）

### 工作内容

1. **新文件 `LingXi/Voice/EnhanceMode.swift`**
   - 模式文件格式与 WenZi 相同：YAML front matter（`label`、`order`）+ 正文 prompt；文件名（不含 `.md`）= 模式 ID；`off` 为保留 ID = 不增强
   - front matter 解析写成 nonisolated 纯函数（只需支持 `key: value` 单行格式，不引入 YAML 库）
   - Loader：扫描目录所有 `.md`，按 order 排序；目录可注入
   - **播种**：启动确保内置模式存在（`proofread.md` 纠错润色、`translate_en.md` 翻译为英文），缺失才创建、不覆盖
   - 遇到 `steps` 字段：忽略该字段并 log（不支持链式，格式兼容）
2. **设置迁移**：`voiceEnhanceMode: String` 替代 `voiceEnhanceEnabled`（true → `proofread`，false → `off`）；`voiceEnhancePrompt` 废弃（prompt 进模式文件，旧自定义 prompt 迁移为 `custom.md`）
3. **状态机接入**：`beginEnhancing` 取当前模式 prompt 构造 `LLMEnhancerConfiguration`；模式为 `off` 时行为同 Phase 2 增强关闭
4. **设置 UI**：模式 Picker（含"关闭"）+ "Open Modes Folder" 按钮；模式列表变更需重启或重新打开设置页生效（首版不做 FSEvents 监听）

### 验证

- 单测：front matter 解析（正常/缺 label 用文件名/坏格式/非 md 忽略/steps 忽略）；播种不覆盖已有文件；模式被删回退第一个可用；`voiceEnhanceEnabled` → mode 迁移
- 手测：手建 `summarize.md` 出现在 Picker；编辑 `proofread.md` 后 prompt 生效

---

## 阶段 C：预览面板增强

### 工作内容

在 Phase 2 `VoicePreviewPanel` / `previewing` 状态上扩展：

1. **⌘Enter 仅复制**：写剪贴板、关面板、不粘贴（`KeyCapturePanel` Return 分支加 command 判断）
2. **模式快速切换 `⌘1-9`**：面板持有本次会话的原始 ASR 文本；按键序号对应模式列表顺序；切换 → 状态机回 `enhancing`（同代际重入，走增强看门狗与降级）→ 完成后更新面板文本
3. **按（模式+LLM模型）缓存结果**：切回已跑过的组合即时显示（UI 标 `cached`），新录音清缓存
4. **面板内 LLM 模型下拉**：切换后重新增强（同缓存机制）
5. **预览历史（内存）**：环形队列保留最近 10 条（ASR 文本、各组合结果、最终文本），应用重启清空；面板工具栏时钟下拉召回；菜单栏加 "Show Last Preview" 入口
6. 保留 Phase 2 行为：可编辑、Show original、Enter 粘贴、Esc/失焦丢弃、previewing 中 fnDown 开新会话

状态机影响：`previewing` 携带会话上下文（asrText、缓存表）；`VoicePreviewPresenting` 回调扩展 `onModeSwitch` / `onModelSwitch`；所有重入仍带 gen 校验。

### 验证

- 单测（FakePresenter 扩展）：切模式触发重增强、缓存命中不再调 enhancer、重增强期间 Esc/确认/fnDown 的代际正确性、⌘Enter 只进剪贴板（自定义 NSPasteboard）、历史队列上限 10
- 手测：⌘1-9 切换即时性、cached 标记、召回上一条预览

---

## 阶段 D：对话历史

### 工作内容

1. **新文件 `LingXi/Voice/ConversationHistory.swift`（actor）**
   - 路径：`~/.local/share/LingXi/conversation_history.jsonl`（目录可注入）
   - 记录字段（对齐 WenZi）：`timestamp`（ISO 8601 UTC）、`asr_text`、`enhanced_text`、`final_text`、`enhance_mode`、`preview_enabled`、`asr_model`、`llm_model`、`user_corrected`、`audio_duration`
   - 直接模式与预览模式的会话都记录；预览取消不记录
   - **轮转**：文件 < 4 MB 跳过检查；超 20,000 条按 `timestamp` 月份归档到 `conversation_history_archives/YYYY-MM.jsonl`（追加式），主文件临时文件 + 原子替换保留最近 20,000 条
2. **注入（Enhancer 集成）**
   - 只取 `preview_enabled == true` 且同模式的最近 N 条
   - 格式：每条一行，`识别→确认`（相同则只写一遍无箭头），统一指令头部说明
   - **追加式构建**：新条目追加到已有列表尾部保持前缀稳定；条目数达 `refresh_threshold`(50) 或字符数达 `max_chars`(6000) 时以最近 `max_entries`(10) 条重建
   - 历史读取失败：log 后无历史继续增强
3. **记录时机**：预览确认（Enter/⌘Enter）→ `preview_enabled: true`、`user_corrected` = 面板文本 ≠ 增强文本；直接粘贴 → `preview_enabled: false`
4. **设置**：`voiceHistoryEnabled: Bool = false`（VoiceSettingsView 加 Toggle）；max_entries / refresh_threshold / max_chars 用代码默认值，不暴露 UI

### 验证

- 单测（全部临时目录）：JSONL 读写与坏行容错；过滤（模式隔离/仅预览确认）；注入格式（箭头/无箭头/头部）；追加式前缀稳定性（连续注入前缀不变、达阈值重建）；轮转归档（按月分组/原子替换/unknown 兜底）；user_corrected 判定
- 手测：确认"平平→萍萍"后下一轮同类输入被正确纠正；关闭开关后不注入

---

## 实施顺序与依赖

**A（模型层）→ B（模式）→ C（面板）→ D（历史）**

- C 依赖 B（`⌘1-9` 切模式）；D 依赖 B/C（按模式过滤 + 预览确认记录）
- A 先行可一次性完成 VoiceSettingsView 重构，避免 B/C 反复改设置页
- 每阶段完成后跑全量单测并单独 commit：

```bash
xcodebuild test -scheme LingXi -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LingXiTests
```

## 风险与已知取舍

- **UserDefaults 存 provider JSON**：结构演进需带版本容错（未知字段忽略、解码失败回退默认并 log），避免升级后配置丢失
- **`⌘1-9` 重入 enhancing**：previewing → enhancing → previewing 的往返是 Phase 3 状态机最复杂的改动，所有回调必须带 gen，看门狗降级路径要回到面板（显示原 ASR 文本）而不是丢会话
- **对话历史明文落盘**：`final_text` 可能含敏感内容，默认关闭（`voiceHistoryEnabled: false`），文档中说明
- **模式文件热加载不做**：改文件需重开设置页/重启，首版接受
- **Phase 3.5 预留**：面板内 STT 切换/重转写（需会话音频保留 + Apple 后端重喂 buffer），另行立项
