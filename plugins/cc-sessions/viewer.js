// viewer.js - Core session viewer rendering logic
// Simplified from WenZi's viewer.html (1978 lines -> ~350 lines)

// Configure marked + highlight.js
document.addEventListener("DOMContentLoaded", () => {
  if (typeof marked !== "undefined") {
    marked.setOptions({
      highlight: (code, lang) => {
        if (typeof hljs !== "undefined" && lang && hljs.getLanguage(lang)) {
          try { return hljs.highlight(code, { language: lang }).value; } catch {}
        }
        if (typeof hljs !== "undefined") {
          try { return hljs.highlightAuto(code).value; } catch {}
        }
        return code;
      },
      breaks: false,
      gfm: true,
    });
  }

  // Wire up close button
  document.getElementById("titlebar-close").addEventListener("click", () => {
    if (typeof window.lingxi !== "undefined") {
      window.lingxi.postMessage({ action: "close" });
    }
  });

  // Send init message to request session data
  if (typeof window.lingxi !== "undefined") {
    window.lingxi.postMessage({ action: "init" });
  } else {
    document.getElementById("loading-msg").textContent =
      "Bridge not available. Open this file through LingXi.";
  }
});

// ── Tool metadata ──
const TOOL_META = {
  Read:       { icon: "📄", css: "tool-read",  mergeable: true },
  Glob:       { icon: "📄", css: "tool-read",  mergeable: true },
  Grep:       { icon: "🔍", css: "tool-grep",  mergeable: true },
  Edit:       { icon: "✏️",  css: "tool-edit",  mergeable: true },
  Bash:       { icon: "▶️",  css: "tool-bash",  mergeable: false },
  Write:      { icon: "📝", css: "tool-write", mergeable: false },
  Agent:      { icon: "🤖", css: "tool-other", mergeable: false },
};

function getToolMeta(name) {
  return TOOL_META[name] || { icon: "🔧", css: "tool-other" };
}

function toolDetail(name, input) {
  if (!input) return "";
  if (name === "Read" && input.file_path) return basename(input.file_path);
  if (name === "Glob" && input.pattern) return input.pattern;
  if (name === "Grep" && input.pattern) return `"${truncate(input.pattern, 40)}"`;
  if (name === "Edit" && input.file_path) return basename(input.file_path);
  if (name === "Write" && input.file_path) return basename(input.file_path);
  if (name === "Bash" && input.command) return truncate(input.command, 60);
  if (name === "Agent" && input.description) return truncate(input.description, 60);
  const first = Object.values(input)[0];
  return typeof first === "string" ? truncate(first, 50) : "";
}

function basename(p) {
  if (!p) return "";
  return p.split("/").pop();
}

function truncate(s, n) {
  if (!s) return "";
  return s.length > n ? s.slice(0, n) + "..." : s;
}

function formatTime(ts) {
  if (!ts) return "";
  try {
    const d = new Date(ts);
    if (isNaN(d.getTime())) return "";
    return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false });
  } catch {
    return "";
  }
}

function renderMarkdown(text) {
  if (!text) return "";
  if (typeof marked !== "undefined") {
    try { return marked.parse(text); } catch {}
  }
  return "<p>" + escapeHtml(text) + "</p>";
}

function escapeHtml(s) {
  const el = document.createElement("div");
  el.textContent = s;
  return el.innerHTML;
}

// ── Copy helpers ──
function copyToClipboard(text) {
  if (typeof window.lingxi !== "undefined") {
    window.lingxi.postMessage({ action: "copy", text });
  }
}

const _copyIconTpl = document.createElement("template");
_copyIconTpl.innerHTML = `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="5" width="8" height="8" rx="1.5"/><path d="M3 11V3a1.5 1.5 0 0 1 1.5-1.5H11"/></svg>`;
const _checkIconTpl = document.createElement("template");
_checkIconTpl.innerHTML = `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3.5 8.5 6.5 11.5 12.5 4.5"/></svg>`;

const _copyTimers = new Set();
function _clearCopyTimers() {
  for (const id of _copyTimers) clearTimeout(id);
  _copyTimers.clear();
}

function createCopyMsgBtn(textFn) {
  const btn = document.createElement("button");
  btn.className = "copy-msg-btn";
  btn.title = "Copy message";
  btn.appendChild(_copyIconTpl.content.cloneNode(true));
  let resetTimer = 0;
  btn.addEventListener("click", (e) => {
    e.stopPropagation();
    const text = typeof textFn === "function" ? textFn() : textFn;
    copyToClipboard(text);
    _copyTimers.delete(resetTimer);
    clearTimeout(resetTimer);
    btn.replaceChildren(_checkIconTpl.content.cloneNode(true));
    btn.classList.add("copied");
    resetTimer = setTimeout(() => {
      _copyTimers.delete(resetTimer);
      if (!btn.isConnected) return;
      btn.replaceChildren(_copyIconTpl.content.cloneNode(true));
      btn.classList.remove("copied");
    }, 1500);
    _copyTimers.add(resetTimer);
  });
  return btn;
}

function setupCollapsibles(container) {
  const maxH = 13 * 1.6 * 8; // ~166px for 8 lines

  container.querySelectorAll(".user-content, .assistant-text").forEach(el => {
    if (el.scrollHeight <= maxH + 4) return; // +4px tolerance

    el.classList.add("collapsible");

    const btn = document.createElement("button");
    btn.className = "show-more-btn";
    btn.textContent = "\u25BC Show more";
    btn.addEventListener("click", () => {
      const expanded = el.classList.toggle("expanded");
      btn.textContent = expanded ? "\u25B2 Show less" : "\u25BC Show more";
    });
    el.parentNode.insertBefore(btn, el.nextSibling);
  });
}

function addCodeCopyButtons(container) {
  container.querySelectorAll("pre").forEach(pre => {
    if (pre.querySelector(".copy-code-btn")) return;
    const code = pre.querySelector("code");
    if (!code) return;
    const btn = document.createElement("button");
    btn.className = "copy-code-btn";
    btn.textContent = "Copy";
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      copyToClipboard(code.textContent);
      btn.textContent = "Copied!";
      btn.classList.add("copied");
      setTimeout(() => {
        btn.textContent = "Copy";
        btn.classList.remove("copied");
      }, 1500);
    });
    pre.style.position = "relative";
    pre.appendChild(btn);
  });
}

// ── Extract text from user/assistant content ──
function extractUserText(content) {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .filter(p => (p.type || "text") === "text")
      .map(p => p.text || "")
      .join("\n");
  }
  return "";
}

function extractAssistantText(content) {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .filter(p => p.type === "text")
      .map(p => p.text || "")
      .join("\n");
  }
  return "";
}

// ── State ──
let sessionInfo = null;
let subagentList = [];
const outlineItems = [];
let activeOutlineIdx = -1;

// Label for the assistant bubble. Defaults to "Claude" for cc sessions;
// switches to "OpenCode" when the Lua side reports source === "opencode".
function getAssistantLabel() {
  return (sessionInfo && sessionInfo.source === "opencode") ? "OpenCode" : "Claude";
}

// ── Main entry: receive data from Lua ──
window.onLingXiMessage = function(raw) {
  let data;
  try {
    data = JSON.parse(raw);
  } catch {
    console.error("Invalid JSON from Lua:", raw);
    return;
  }

  if (data.action === "session_data") {
    sessionInfo = data.info || {};
    subagentList = data.subagents || [];
    renderSession(data.info, data.messages || []);
  }
};

function renderSession(info, messages) {
  // Update title bar
  if (info.title) {
    const t = info.title.length > 60 ? info.title.slice(0, 60) + "…" : info.title;
    document.getElementById("titlebar-title").textContent = t;
  }

  // Collect metadata from messages
  let userCount = 0, assistantCount = 0;
  const models = new Set();
  let firstTime = null, lastTime = null;
  for (const msg of messages) {
    if (msg.type === "user") userCount++;
    else if (msg.type === "assistant") {
      assistantCount++;
      const model = msg.message?.model || msg.model;
      if (model) models.add(model);
    }
    const ts = msg.timestamp;
    if (ts) {
      const d = new Date(ts);
      if (!isNaN(d.getTime())) {
        if (!firstTime || d < firstTime) firstTime = d;
        if (!lastTime || d > lastTime) lastTime = d;
      }
    }
  }

  // Update info bar
  const infoBar = document.getElementById("info-bar");
  infoBar.innerHTML = "";

  const parts = [];

  // Project
  parts.push(`<span class="label">Project:</span><span class="value">${escapeHtml(info.project || "—")}</span>`);
  // Branch
  if (info.git_branch) {
    parts.push(`<span class="label">Branch:</span><span class="value">${escapeHtml(info.git_branch)}</span>`);
  }
  // Version
  if (info.version) {
    parts.push(`<span class="label">Version:</span><span class="value">${escapeHtml(info.version)}</span>`);
  }
  // Model
  if (models.size > 0) {
    const modelStr = Array.from(models).join(", ");
    parts.push(`<span class="label">Model:</span><span class="value">${escapeHtml(truncate(modelStr, 40))}</span>`);
  }
  // Messages
  const total = userCount + assistantCount;
  if (total > 0) {
    parts.push(`<span class="label">Msgs:</span><span class="value">${total}</span>`);
  }
  // Time range
  if (firstTime && lastTime) {
    const fmt = (d) => d.toLocaleDateString() + " " + d.toLocaleTimeString([], {hour:"2-digit", minute:"2-digit"});
    parts.push(`<span class="label">Time:</span><span class="value">${fmt(firstTime)} – ${fmt(lastTime)}</span>`);
  }
  // Session ID
  if (info.session_id) {
    parts.push(`<span class="label">ID:</span><span class="value" title="${escapeHtml(info.session_id)}">${escapeHtml(info.session_id.slice(0, 8))}…</span>`);
  }

  infoBar.innerHTML = parts.join(`<span class="sep">|</span>`);

  // Parent session link (for subagents)
  if (info.is_subagent && info.parent_file_path) {
    const parentLink = document.createElement("a");
    parentLink.className = "parent-link";
    parentLink.href = "#";
    parentLink.textContent = "← Parent Session";
    parentLink.addEventListener("click", (e) => {
      e.preventDefault();
      openParentSession(info.parent_file_path);
    });
    infoBar.appendChild(document.createTextNode(" "));
    infoBar.appendChild(parentLink);
  }

  renderConversation(messages);
  renderStats(messages);
}

function openSubagentSession(filePath) {
  if (typeof window.lingxi !== "undefined") {
    window.lingxi.postMessage({ action: "open_subagent", file_path: filePath });
  }
}

function openParentSession(filePath) {
  if (typeof window.lingxi !== "undefined") {
    window.lingxi.postMessage({ action: "open_parent", file_path: filePath });
  }
}

// ── Stats Dashboard ──
function renderStats(messages) {
  const toggle = document.getElementById("stats-toggle");
  const panel = document.getElementById("stats-panel");
  const summary = document.getElementById("stats-summary");

  // Calculate stats
  let userCount = 0, assistantCount = 0, toolCount = 0;
  const toolUsage = {};
  let inputTokens = 0, outputTokens = 0;

  for (const msg of messages) {
    if (msg.type === "user") {
      userCount++;
      const usage = msg.message?.usage || msg.usage;
      if (usage?.input_tokens) inputTokens += usage.input_tokens;
    } else if (msg.type === "assistant") {
      assistantCount++;
      const usage = msg.message?.usage || msg.usage;
      if (usage?.output_tokens) outputTokens += usage.output_tokens;

      const content = msg.message?.content || msg.content;
      if (Array.isArray(content)) {
        for (const part of content) {
          if (part.type === "tool_use") {
            toolCount++;
            toolUsage[part.name] = (toolUsage[part.name] || 0) + 1;
          }
        }
      }
    }
  }

  const totalTurns = userCount + assistantCount;
  if (totalTurns === 0) {
    toggle.style.display = "none";
    return;
  }

  toggle.style.display = "";

  // Summary line — richer stats
  const parts = [`${totalTurns} turns`];
  if (toolCount > 0) parts.push(`${toolCount} tools`);

  // Token breakdown
  if (inputTokens > 0 || outputTokens > 0) {
    const fmt = (n) => n >= 1000 ? (n / 1000).toFixed(n >= 10000 ? 0 : 1) + "K" : n.toString();
    const tokenParts = [];
    if (inputTokens > 0) tokenParts.push(`${fmt(inputTokens)} in`);
    if (outputTokens > 0) tokenParts.push(`${fmt(outputTokens)} out`);
    parts.push(tokenParts.join(" / "));
  }

  // Subagents count
  if (subagentList.length > 0) {
    parts.push(`${subagentList.length} subagent${subagentList.length > 1 ? "s" : ""}`);
  }

  // Models used
  const models = new Set();
  for (const msg of messages) {
    if (msg.type === "assistant") {
      const model = msg.message?.model || msg.model;
      if (model) models.add(model);
    }
  }
  if (models.size > 0) {
    const modelStr = Array.from(models).join(", ");
    parts.push(truncate(modelStr, 30));
  }

  summary.textContent = parts.join(" · ");

  // Build panel content — all cards in a unified 2-column grid
  let html = '<div class="stats-grid">';

  // Messages card
  html += '<div class="stats-card"><h4>Messages</h4>';
  html += `<div class="stats-row"><span>User</span><span class="val">${userCount}</span></div>`;
  html += `<div class="stats-row"><span>Assistant</span><span class="val">${assistantCount}</span></div>`;
  html += `<div class="stats-row"><span>Total</span><span class="val">${totalTurns}</span></div>`;
  html += '</div>';

  // Tokens card
  html += '<div class="stats-card"><h4>Tokens</h4>';
  html += `<div class="stats-row"><span>Input</span><span class="val">${inputTokens.toLocaleString()}</span></div>`;
  html += `<div class="stats-row"><span>Output</span><span class="val">${outputTokens.toLocaleString()}</span></div>`;
  html += `<div class="stats-row"><span>Total</span><span class="val">${(inputTokens + outputTokens).toLocaleString()}</span></div>`;
  html += '</div>';

  // Tool Usage card
  const toolNames = Object.keys(toolUsage).sort((a, b) => toolUsage[b] - toolUsage[a]);
  if (toolNames.length > 0) {
    const maxCount = toolUsage[toolNames[0]];
    const colors = {
      Read: "#f59e0b", Glob: "#f59e0b", Grep: "#6366f1",
      Edit: "#ef4444", Bash: "#10b981", Write: "#ec4899", Agent: "#9ca3af",
    };

    html += '<div class="stats-card"><h4>Tool Usage</h4>';
    for (const name of toolNames) {
      const count = toolUsage[name];
      const pct = Math.round((count / maxCount) * 100);
      const color = colors[name] || "#9ca3af";
      html += `<div class="stats-bar-row">`;
      html += `<span class="stats-bar-label">${escapeHtml(name)}</span>`;
      html += `<span class="stats-bar-track"><span class="stats-bar-fill" style="width:${pct}%;background:${color}"></span></span>`;
      html += `<span class="stats-bar-count">${count}</span>`;
      html += `</div>`;
    }
    html += '</div>';
  }

  // Subagents card
  if (subagentList.length > 0) {
    html += '<div class="stats-card"><h4>Subagents</h4>';
    for (const sa of subagentList) {
      const modelLabel = sa.model ? `<span class="model">${escapeHtml(truncate(sa.model, 25))}</span>` : "";
      html += `<div class="stats-list-item">`;
      html += `<span class="name">${escapeHtml(sa.agent_type || "Agent")}</span>`;
      html += `<div class="item-right">${modelLabel}<button class="stats-subagent-link" data-path="${escapeHtml(sa.file_path)}">View</button></div>`;
      html += `</div>`;
    }
    html += '</div>';
  }

  html += '</div>'; // end stats-grid

  panel.innerHTML = html;

  // Wire up subagent links in stats panel
  panel.querySelectorAll(".stats-subagent-link").forEach(btn => {
    btn.addEventListener("click", () => {
      openSubagentSession(btn.dataset.path);
    });
  });

  // Wire up toggle
  toggle.onclick = () => {
    const isOpen = panel.classList.toggle("open");
    document.getElementById("stats-arrow").classList.toggle("open", isOpen);
  };
}

// ── Render conversation ──
let _lastRenderedTime = "";

function buildToolResultMap(messages) {
  const map = {};
  for (const msg of messages) {
    if (msg.type !== "user") continue;
    const content = msg.message?.content || msg.content;
    if (!Array.isArray(content)) continue;
    for (const part of content) {
      if (part.type === "tool_result" && part.tool_use_id) {
        map[part.tool_use_id] = part;
      }
    }
  }
  return map;
}

function renderConversation(messages) {
  const conv = document.getElementById("conversation");
  conv.innerHTML = "";
  document.getElementById("outline").innerHTML = '<div class="outline-title">Outline</div>';
  outlineItems.length = 0;
  activeOutlineIdx = -1;
  _lastRenderedTime = "";

  // Filter to user/assistant messages only
  const validTypes = new Set(["user", "assistant"]);
  const turns = messages.filter(m => validTypes.has(m.type));

  const resultMap = buildToolResultMap(turns);

  let i = 0;
  while (i < turns.length) {
    const msg = turns[i];

    if (msg.type === "user") {
      if (_isToolResultOnly(msg)) {
        i++;
        continue;
      }
      renderUserTurn(conv, msg);
      i++;
    } else if (msg.type === "assistant") {
      // Merge consecutive assistant messages into one turn
      const turnEl = document.createElement("div");
      turnEl.className = "turn";

      const firstTime = formatTime(msg.timestamp);
      const showTime = firstTime !== _lastRenderedTime;
      if (showTime) _lastRenderedTime = firstTime;

      const header = document.createElement("div");
      header.className = "turn-header";
      header.innerHTML = `
        <span class="badge badge-assistant">${escapeHtml(getAssistantLabel())}</span>
        ${showTime ? `<span class="timestamp">${escapeHtml(firstTime)}</span>` : ""}
      `;
      turnEl.appendChild(header);

      const assistantTexts = [];
      turnEl.appendChild(createCopyMsgBtn(() => assistantTexts.join("\n\n").trim()));

      // Collect consecutive assistant messages (and tool_result-only user msgs in between)
      while (i < turns.length && (turns[i].type === "assistant" || (turns[i].type === "user" && _isToolResultOnly(turns[i])))) {
        if (turns[i].type === "assistant") {
          renderAssistantContent(turnEl, turns[i], assistantTexts, resultMap);
        }
        i++;
      }

      conv.appendChild(turnEl);

      const combinedText = assistantTexts.join(" ").trim();
      if (combinedText) {
        addOutlineItem(combinedText, turnEl, "assistant");
      }
    } else {
      i++;
    }
  }

  setupOutlineObserver();
  setupCollapsibles(conv);
  addCodeCopyButtons(conv);
  conv.scrollTop = conv.scrollHeight;
}

function _isToolResultOnly(msg) {
  const content = msg.message?.content || msg.content;
  if (!Array.isArray(content)) return false;
  const hasRealText = content.some(p =>
    (p.type || "text") === "text" && p.text && p.text.trim() &&
    !p.text.startsWith("<system-reminder>")
  );
  const hasToolResult = content.some(p => p.type === "tool_result");
  return hasToolResult && !hasRealText;
}

// ── User turn ──
function renderUserTurn(conv, msg) {
  const time = formatTime(msg.timestamp);
  const showTime = time !== _lastRenderedTime;
  if (showTime) _lastRenderedTime = time;

  const text = extractUserText(msg.message?.content || msg.content || "");
  if (!text.trim()) return;

  const turnEl = document.createElement("div");
  turnEl.className = "turn";

  const header = document.createElement("div");
  header.className = "turn-header";
  header.innerHTML = `
    <span class="badge badge-user">You</span>
    ${showTime ? `<span class="timestamp">${escapeHtml(time)}</span>` : ""}
  `;
  turnEl.appendChild(header);

  const contentEl = document.createElement("div");
  contentEl.className = "user-content";
  contentEl.textContent = text;
  turnEl.appendChild(contentEl);

  turnEl.appendChild(createCopyMsgBtn(text));

  conv.appendChild(turnEl);
  addOutlineItem(text, turnEl, "user");
}

// ── Assistant content (renders into an existing turnEl) ──
function renderAssistantContent(turnEl, msg, textCollector, resultMap) {
  const content = msg.message?.content || msg.content;

  if (Array.isArray(content)) {
    const blocks = buildBlocks(content, resultMap);
    for (const block of blocks) {
      if (block.kind === "text") {
        const textEl = document.createElement("div");
        textEl.className = "assistant-text";
        textEl.innerHTML = renderMarkdown(block.text);
        turnEl.appendChild(textEl);
        textCollector.push(block.text.trim());
      } else if (block.kind === "thinking") {
        turnEl.appendChild(createThinkingBlock(block.text));
      } else if (block.kind === "tool_group") {
        turnEl.appendChild(createToolGroup(block));
      } else if (block.kind === "tool_single") {
        turnEl.appendChild(createToolSingle(block.call, block.result));
      }
    }
  } else if (typeof content === "string" && content.trim()) {
    const textEl = document.createElement("div");
    textEl.className = "assistant-text";
    textEl.innerHTML = renderMarkdown(content);
    turnEl.appendChild(textEl);
    textCollector.push(content.trim());
  }
}

// ── Thinking block ──
function createThinkingBlock(text) {
  const wrapper = document.createElement("div");

  const toggle = document.createElement("div");
  toggle.className = "thinking-toggle";
  toggle.innerHTML = "💭 Thinking...";
  wrapper.appendChild(toggle);

  const content = document.createElement("div");
  content.className = "thinking-content";
  content.textContent = text;
  wrapper.appendChild(content);

  toggle.addEventListener("click", () => content.classList.toggle("visible"));
  return wrapper;
}

// ── Build blocks with tool merging ──
function buildBlocks(parts, globalResultMap) {
  const blocks = [];
  const resultMap = Object.assign({}, globalResultMap || {});
  for (const p of parts) {
    if (p.type === "tool_result") {
      resultMap[p.tool_use_id] = p;
    }
  }

  let i = 0;
  while (i < parts.length) {
    const p = parts[i];

    if (p.type === "text" && p.text && p.text.trim()) {
      blocks.push({ kind: "text", text: p.text });
      i++;
    } else if (p.type === "thinking" && p.thinking) {
      blocks.push({ kind: "thinking", text: p.thinking });
      i++;
    } else if (p.type === "tool_use") {
      const meta = getToolMeta(p.name);

      if (meta.mergeable) {
        const group = [];
        while (i < parts.length && parts[i].type === "tool_use" && parts[i].name === p.name) {
          group.push({ call: parts[i], result: resultMap[parts[i].id] });
          i++;
        }
        if (group.length === 1) {
          blocks.push({ kind: "tool_single", call: group[0].call, result: group[0].result });
        } else {
          blocks.push({ kind: "tool_group", name: p.name, items: group });
        }
      } else {
        blocks.push({ kind: "tool_single", call: p, result: resultMap[p.id] });
        i++;
      }
    } else {
      i++;
    }
  }
  return blocks;
}

// ── Extract agentId from tool result text content ──
function extractAgentId(result) {
  if (!result) return null;
  let text = "";
  const c = result.content;
  if (typeof c === "string") {
    text = c;
  } else if (Array.isArray(c)) {
    for (const part of c) {
      if (part && part.type === "text" && part.text) {
        text += part.text;
      }
    }
  }
  const match = text.match(/agentId:\s*([a-f0-9]+)/);
  return match ? match[1] : null;
}

// ── Tool block (with subagent support) ──
function createToolSingle(call, result) {
  const meta = getToolMeta(call.name);
  const detail = toolDetail(call.name, call.input);

  const block = document.createElement("div");
  block.className = `tool-block ${meta.css}`;

  const headerEl = document.createElement("div");
  headerEl.className = "tool-header";
  headerEl.innerHTML = `
    <span class="tool-icon">${meta.icon}</span>
    <code class="tool-label">${escapeHtml(call.name)}</code>
    <span class="tool-detail">${escapeHtml(detail)}</span>
    <span class="tool-arrow">▶</span>
  `;
  block.appendChild(headerEl);

  const body = document.createElement("div");
  body.className = "tool-body";

  let html = '<div class="tool-section-label">Input</div>';
  html += `<pre>${escapeHtml(formatToolInput(call))}</pre>`;
  if (result) {
    html += '<div class="tool-section-label">Output</div>';
    html += `<pre>${escapeHtml(formatToolResult(result))}</pre>`;
  }
  body.innerHTML = html;
  block.appendChild(body);

  // Subagent link: if this is an Agent tool and we have a matching subagent
  if (call.name === "Agent") {
    const agentId = extractAgentId(result);
    if (agentId) {
      const matched = subagentList.find(sa => sa.agent_id === agentId);
      if (matched) {
        const subagentTag = document.createElement("div");
        subagentTag.className = "subagent-tag";
        const modelLabel = matched.model ? ` · ${escapeHtml(truncate(matched.model, 20))}` : "";
        subagentTag.innerHTML = `
          <span class="subagent-model">${escapeHtml(matched.agent_type || "Agent")}${modelLabel}</span>
          <button class="subagent-link">View Session</button>
        `;
        const btn = subagentTag.querySelector(".subagent-link");
        btn.addEventListener("click", (e) => {
          e.stopPropagation();
          openSubagentSession(matched.file_path);
        });
        block.insertBefore(subagentTag, body);
      }
    }
  }

  headerEl.addEventListener("click", () => block.classList.toggle("expanded"));
  return block;
}

// ── Merged tool group ──
function createToolGroup(group) {
  const meta = getToolMeta(group.name);
  const count = group.items.length;
  const details = group.items.map(it => toolDetail(group.name, it.call.input)).join(", ");

  const block = document.createElement("div");
  block.className = `tool-block ${meta.css}`;

  const headerEl = document.createElement("div");
  headerEl.className = "tool-header";
  headerEl.innerHTML = `
    <span class="tool-icon">${meta.icon}</span>
    <code class="tool-label">${escapeHtml(group.name)} ${count} files</code>
    <span class="tool-detail">${escapeHtml(truncate(details, 80))}</span>
    <span class="tool-arrow">▶</span>
  `;
  block.appendChild(headerEl);

  const body = document.createElement("div");
  body.className = "tool-body";
  for (const it of group.items) {
    const detail = toolDetail(group.name, it.call.input);
    const itemDiv = document.createElement("div");
    itemDiv.style.marginBottom = "8px";

    let html = `<div class="tool-section-label">${escapeHtml(group.name)}: ${escapeHtml(detail)}</div>`;
    html += `<pre>${escapeHtml(formatToolInput(it.call))}</pre>`;
    if (it.result) {
      html += `<div class="tool-section-label">Output</div>`;
      html += `<pre>${escapeHtml(formatToolResult(it.result))}</pre>`;
    }
    itemDiv.innerHTML = html;
    body.appendChild(itemDiv);
  }
  block.appendChild(body);

  headerEl.addEventListener("click", () => block.classList.toggle("expanded"));
  return block;
}

function formatToolInput(call) {
  if (!call.input) return "";
  if (call.name === "Bash" && call.input.command) return call.input.command;
  return JSON.stringify(call.input, null, 2);
}

function formatToolResult(result) {
  if (!result) return "";
  const c = result.content;
  if (typeof c === "string") return truncate(c, 2000);
  if (Array.isArray(c)) {
    return truncate(c.filter(p => p.type === "text").map(p => p.text || "").join("\n"), 2000);
  }
  return truncate(JSON.stringify(c, null, 2), 2000);
}

// ── Outline ──
function addOutlineItem(text, targetEl, role) {
  const outline = document.getElementById("outline");
  const item = document.createElement("div");
  item.className = "outline-item" + (role === "assistant" ? " outline-assistant" : "");
  item.textContent = truncate(text.trim(), 45);

  item.addEventListener("click", () => {
    targetEl.scrollIntoView({ behavior: "smooth", block: "start" });
  });

  outline.appendChild(item);
  outlineItems.push({ el: item, targetEl });
}

function setActiveOutline(idx) {
  if (idx === activeOutlineIdx) return;
  if (activeOutlineIdx >= 0 && activeOutlineIdx < outlineItems.length) {
    outlineItems[activeOutlineIdx].el.classList.remove("active");
  }
  if (idx >= 0 && idx < outlineItems.length) {
    outlineItems[idx].el.classList.add("active");
    outlineItems[idx].el.scrollIntoView({ block: "nearest" });
  }
  activeOutlineIdx = idx;
}

function setupOutlineObserver() {
  if (outlineItems.length === 0) return;

  const conv = document.getElementById("conversation");

  const observer = new IntersectionObserver(
    (entries) => {
      let topIdx = -1;
      let topY = Infinity;
      for (const entry of entries) {
        if (entry.isIntersecting) {
          const idx = outlineItems.findIndex(o => o.targetEl === entry.target);
          if (idx >= 0 && entry.boundingClientRect.top < topY) {
            topY = entry.boundingClientRect.top;
            topIdx = idx;
          }
        }
      }
      if (topIdx >= 0) setActiveOutline(topIdx);
    },
    { root: conv, rootMargin: "0px 0px -70% 0px", threshold: 0 }
  );

  for (const item of outlineItems) {
    observer.observe(item.targetEl);
  }

  if (outlineItems.length > 0) setActiveOutline(0);
}
