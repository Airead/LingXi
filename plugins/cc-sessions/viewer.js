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
  Read:       { icon: "📄", css: "tool-read" },
  Glob:       { icon: "📄", css: "tool-read" },
  Grep:       { icon: "🔍", css: "tool-grep" },
  Edit:       { icon: "✏️",  css: "tool-edit" },
  Bash:       { icon: "▶️",  css: "tool-bash" },
  Write:      { icon: "📝", css: "tool-write" },
  Agent:      { icon: "🤖", css: "tool-other" },
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
const outlineItems = [];
let activeOutlineIdx = -1;

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
    renderSession(data.info, data.messages || []);
  }
};

function renderSession(info, messages) {
  // Update title bar
  if (info.title) {
    const t = info.title.length > 60 ? info.title.slice(0, 60) + "…" : info.title;
    document.getElementById("titlebar-title").textContent = t;
  }

  // Update info bar
  if (info.project) document.getElementById("info-project").textContent = info.project;
  if (info.git_branch) document.getElementById("info-branch").textContent = info.git_branch;
  if (info.version) document.getElementById("info-version").textContent = info.version;

  renderConversation(messages);
}

// ── Render conversation ──
let _lastRenderedTime = "";

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

  // Build tool result map for resolving tool outputs
  const resultMap = {};
  for (const msg of turns) {
    if (msg.type !== "user") continue;
    const content = msg.message?.content || msg.content;
    if (!Array.isArray(content)) continue;
    for (const part of content) {
      if (part.type === "tool_result" && part.tool_use_id) {
        resultMap[part.tool_use_id] = part;
      }
    }
  }

  for (let i = 0; i < turns.length; i++) {
    const msg = turns[i];

    if (msg.type === "user") {
      // Skip pure tool_result messages
      if (_isToolResultOnly(msg)) continue;
      renderUserTurn(conv, msg);
    } else if (msg.type === "assistant") {
      renderAssistantTurn(conv, msg, resultMap);
    }
  }

  setupOutlineObserver();

  // Auto-scroll to bottom
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

  conv.appendChild(turnEl);
  addOutlineItem(text, turnEl, "user");
}

// ── Assistant turn ──
function renderAssistantTurn(conv, msg, resultMap) {
  const time = formatTime(msg.timestamp);
  const showTime = time !== _lastRenderedTime;
  if (showTime) _lastRenderedTime = time;

  const turnEl = document.createElement("div");
  turnEl.className = "turn";

  const header = document.createElement("div");
  header.className = "turn-header";
  header.innerHTML = `
    <span class="badge badge-assistant">Claude</span>
    ${showTime ? `<span class="timestamp">${escapeHtml(time)}</span>` : ""}
  `;
  turnEl.appendChild(header);

  const content = msg.message?.content || msg.content;
  const texts = [];

  if (Array.isArray(content)) {
    for (const part of content) {
      if (part.type === "text" && part.text && part.text.trim()) {
        const textEl = document.createElement("div");
        textEl.className = "assistant-text";
        textEl.innerHTML = renderMarkdown(part.text);
        turnEl.appendChild(textEl);
        texts.push(part.text.trim());
      } else if (part.type === "thinking" && part.thinking) {
        turnEl.appendChild(createThinkingBlock(part.thinking));
      } else if (part.type === "tool_use") {
        const result = resultMap[part.id];
        turnEl.appendChild(createToolBlock(part, result));
      }
    }
  } else if (typeof content === "string" && content.trim()) {
    const textEl = document.createElement("div");
    textEl.className = "assistant-text";
    textEl.innerHTML = renderMarkdown(content);
    turnEl.appendChild(textEl);
    texts.push(content.trim());
  }

  conv.appendChild(turnEl);

  const combinedText = texts.join(" ").trim();
  if (combinedText) {
    addOutlineItem(combinedText, turnEl, "assistant");
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

// ── Tool block (simplified: no merging, no subagents) ──
function createToolBlock(call, result) {
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
