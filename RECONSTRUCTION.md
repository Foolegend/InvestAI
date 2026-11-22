# 源码快照本地运行重建说明

本工程原本只是 `src/` 源码快照（无 `package.json`、无依赖、缺失若干模块），
现在已补成一个可以用 Bun 直接运行的 TypeScript 工程。

## 快速开始

```bash
bun install            # 已执行过；依赖见 package.json

# 查看版本（最快路径，几乎不加载模块）
bun run start -- --version

# 帮助
bun run start -- --help

# 非交互运行
bun run start -- -p "你的问题"

# 交互式 REPL（在当前终端直接启动）
bun run start
```

`start` 实际执行的命令：

```bash
bun run --preload ./compat/preload.ts ./src/entrypoints/cli.tsx
```

`--preload` 会注入原构建流程里由 `bun build --define` 提供的 `MACRO` 对象
（版本号、反馈地址等），详见 `compat/preload.ts`。

认证沿用你本机的 Claude Code 配置（`~/.claude/settings.json` / 环境变量），
仓库内没有任何凭据。

## 已验证

| 场景 | 结果 |
|---|---|
| `--version` | 输出 `2.1.330 (Claude Code)` |
| `--help` | 完整参数与子命令列表 |
| `mcp list` | `No MCP servers configured...` |
| `-p` 完整查询链路 | 通过本地 Messages API mock 返回流式响应 |
| 工具调用链路 | mock 返回 `Bash` tool_use → 实际执行 `echo mock-tool-ok` → 结果回传 |

端到端测试没有访问任何外部 API，使用 `scripts/mock-anthropic.ts`：

```bash
# 终端 A
bun run scripts/mock-anthropic.ts

# 终端 B（端口按 mock 默认 8787 调整）
ANTHROPIC_BASE_URL=http://127.0.0.1:8787 ANTHROPIC_AUTH_TOKEN=test \
  bun run start -- --bare -p "ping"
```

## 改动清单

### 新增工程文件

- `package.json` — 依赖与启动脚本（Bun 1.4.5，Node 25 亦可安装依赖）
- `tsconfig.json` — `src/*` 路径别名、JSX、私有/原生包指向本地 stub；
  `@anthropic-ai/claude-agent-sdk` 的类型导入指向内部 `src/types/permissions.ts`
  （本仓库自身就是 SDK 源码，无需外部 agent-sdk 包）
- `compat/feature.ts` — `bun:bundle` 的运行时替代品（环境变量控制特性开关）
- `compat/preload.ts` — 注入 `MACRO` 全局对象
- `compat/stubs/` — 私有/原生包的替代实现（见下）
- `scripts/codemod-bun-bundle.py` — 把 196 处 `from 'bun:bundle'` 改为 `cc-feature`
- `scripts/generate-missing-stubs.py` — 为快照缺失模块生成占位实现（可重复执行）
- `scripts/mock-anthropic.ts` — 本地 Messages API mock，用于离线验证

### 对 `src/` 的修改

| 类型 | 数量 | 说明 |
|---|---:|---|
| `bun:bundle` 导入改写 | 196 文件 | 改为 `cc-feature`；Bun 只在 `bun build` 内提供该虚拟模块 |
| 缺失模块占位 | 120 个 `.js` | 通用 Proxy 导出，缺失的 feature-gated 模块/类型模块 |
| 文本资源占位 | 33 个 | 内置技能文档、yolo 分类器提示词等 |
| `.d.ts` 占位 | 1 个 | `src/ink/global.d.ts` |
| 源码补丁 | 2 处 | 见下 |

源码补丁：

1. `src/main.tsx`：`-d2e, --debug-to-stderr` 改为 `--debug-to-stderr`。
   新版 Commander 不再接受多字符短选项。
2. `src/bootstrap/state.ts`：补充 `isReplBridgeActive()` 导出。
   快照里只有字段没有 getter，而其他模块会导入它；Remote Control 未启用，恒为 `false`。

## 实现原理

### 1. `feature()` 特性开关

原工程用 `bun:bundle` 的编译期 `feature('FLAG')` 做死代码消除。本工程改为运行时查找：

```bash
# 启用多个特性
CC_FEATURES=KAIROS,VOICE_MODE bun run start

# 或逐个启用
CC_FEATURE_VOICE_MODE=1 bun run start
```

默认全部关闭，与官方 external build 的行为一致。

### 2. `MACRO` 全局

`MACRO.VERSION` 等 97+ 处引用在打包时被常量替换。这里由 preload 设置到
`globalThis.MACRO`，Bun 中模块可以直接以全局标识符访问。

### 3. 私有/原生包

| 包 | 处理 |
|---|---|
| `color-diff-napi` | 复用 `src/native-ts/color-diff` 的纯 TS 移植 |
| `image-processor-napi` | 转发到公开的 `sharp`；剪贴板原生接口返回不可用 |
| `audio-capture-napi` | 语音输入不可用 |
| `url-handler-napi` | deep link 等待恒返回 `null` |
| `modifiers-napi` | macOS 修饰键检测恒为 `false` |
| `@ant/computer-use-*` | Computer Use 不可用，工具列表为空 |
| `@ant/claude-for-chrome-mcp` | 浏览器工具不可用 |

## 已知限制

- **交互式 REPL 尚未实测**：`-p` 非交互链路已验证；Ink/React 终端 UI 需要真实 TTY，
  建议在你自己的终端里运行 `bun run start` 观察。
- **缺失模块是占位实现**：`services/contextCollapse`、`services/compact/snip*`、
  `services/skillSearch`、`proactive`、`assistant`、workflow/monitor/UDS/server/daemon
  等路径被替换为恒等 Proxy。默认特性开关下通常不会进入这些分支；一旦启用相关
  feature flag，需要补真实实现。
- **内置技能内容不完整**：claude-api 技能的 Markdown 资源是占位文本。
- **没有类型检查**：Bun 只做转译，`tsc` 对这份快照仍会报大量缺失类型错误。
- **依赖版本按 2.1.330 选取**：快照与依赖之间存在少量 API 漂移（例如上面的
  Commander 选项格式），继续使用中若遇到类似 `Export named ... not found`
  或参数校验错误，属于同源问题。
- **`python/` 目录未使用**：那是早期 `ts2py` 的失败产物（81% 文件语法非法），
  与本次可运行工程无关。
- **依赖表只保留运行时引用**：`type-fest`、`vscode-languageserver-protocol`、
  `vscode-languageserver-types` 等纯类型包已移除，`@anthropic-ai/claude-agent-sdk`
  的类型导入改指向内部源码。运行时不受影响，但 `tsc`/编辑器会报这些模块无法解析。

## 继续补全的建议顺序

1. 在真实终端跑交互 REPL，确认 Ink 渲染、输入、权限弹窗。
2. 跑一次 `-p "写一个 hello world 文件"` 之类需要工具的多轮任务。
3. 若需要 context collapse / snip compact 等核心能力，优先替换对应 stub：
   `src/services/contextCollapse/index.js`、`src/services/compact/snipCompact.js`、
   `src/services/compact/cachedMicrocompact.js`。
4. 需要语音/Computer Use/浏览器能力时，替换 `compat/stubs/` 下的对应实现。
