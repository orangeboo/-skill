---
name: goodsclassify-c
description: Query 商品归类, 商品编码, 海关编码, HS编码, 税则号, 税号 and customs classification data through three FastGPT agents. On first use, require a mobile number, save it locally, verify it with agent A, insert it with agent B when missing, then answer classification questions with agent C. When agent C returns content, the final user-facing reply must be the exact raw output from C with no summary, rewrite, prefix, suffix, formatting cleanup, or additional explanation. Use when the user asks about 商品归类, 商品编码, 海关编码, HS编码, 税则, 税号, customs code, or tariff code.
homepage: http://agent.ccorp.cn:16800/
metadata: {"clawdbot":{"emoji":"📦","requires":{"bins":["powershell"],"env":["FASTGPT_API_URL","AGENT_A_KEY","AGENT_B_KEY","AGENT_C_KEY"]}}}
---

# 商品归类 Skill

## Required Execution Contract

处理本 skill 时，严格按下面顺序执行：

1. 执行 `powershell -ExecutionPolicy Bypass -File "skills/goodsclassify-c/scripts/goodsclassify.ps1" -Message "<用户原始消息>" -SessionId "<当前会话ID>"`
2. 读取该命令产生的 stdout
3. 如果 stdout 是 `请先输入手机号（仅首次需要）`，就只回复这一句
4. 否则，把 stdout 原样作为最终回复发给用户

这里的“原样”是强约束：

- 直接复制 stdout
- 不做总结
- 不做删减
- 不做格式整理
- 不补充解释
- 不添加前后缀
- 不改成更短版本
- 不把 stdout 当素材重新组织
- 不要说“根据查询结果”或“以下是结果”
- 每次调用 A、B、C 都必须使用新的 chatId，禁止复用旧 chatId，避免把历史问题一起带回

通过 3 个 FastGPT 智能体处理商品归类问题：

- A：检查手机号是否已存在于数据库
- B：当手机号不存在时写入数据库
- C：回答商品归类、商品编码、税则号、HS 编码等问题

## Setup

本 skill 读取当前目录下的 `.env` 配置文件，不需要额外安装 Python 依赖。

默认配置项：

```bash
FASTGPT_API_URL=http://agent.ccorp.cn:16800/api/v1/chat/completions
AGENT_A_KEY=your-agent-a-key
AGENT_B_KEY=your-agent-b-key
AGENT_C_KEY=your-agent-c-key
FASTGPT_TIMEOUT=200
MIN_PHONE_REPLY_DELAY_MS=4000
```

## Usage

所有商品归类相关问题都必须执行本地 PowerShell 脚本：

```powershell
powershell -ExecutionPolicy Bypass -File "skills/goodsclassify-c/scripts/goodsclassify.ps1" -Message "<用户原始消息>" -SessionId "<当前会话ID>"
```

如果当前环境拿不到会话 ID，也可以先直接运行：

```powershell
powershell -ExecutionPolicy Bypass -File "skills/goodsclassify-c/scripts/goodsclassify.ps1" -Message "<用户原始消息>"
```

## Workflow

1. 第一次使用时，如果本地还没有手机号记录：
   - 若用户输入的不是手机号，就提示：`请先输入手机号（仅首次需要）`
   - 并把这次商品问题暂存到本地 txt
2. 当用户输入手机号后：
   - 将手机号保存到本地 txt
   - 调用 A 检查手机号是否存在
   - 若 A 返回 `[]`，则调用 B 入库
   - 然后调用 C 继续回答之前暂存的问题
3. 后续每次商品归类提问：
   - 先读取本地手机号
   - 调用 A 校验手机号
   - 若不存在则调用 B 补录
   - 最后调用 C
4. 成功进入 C 之后，优先以流式方式实时输出 C 的原始结果，不要自己改写、摘要或补充推断

## Final Response Contract

当脚本已经拿到 C 的结果后，最终回复必须严格遵守以下规则：

- 最终发给用户的内容必须与 C 的原始输出完全一致
- 不允许总结、改写、压缩、翻译、润色、补充解释或补充结论
- 不允许额外添加开场白、结束语、提示语、项目符号、标题、代码块包裹或引用标记
- 不允许修正 C 的措辞、格式、换行、顺序或标点
- 如果 C 是流式返回，就按流式原样向用户透传
- 如果 C 是整段返回，就整段原样返回
- 只有在脚本明确返回 `请先输入手机号（仅首次需要）` 这种前置流程提示时，才向用户返回该提示

## Local Storage

本 skill 会在 `skills/goodsclassify-c/data/` 下维护本地状态：

- `<session>.phone.txt`：保存手机号
- `<session>.pending.txt`：保存首次提问但尚未回答的问题
- `<session>.await-phone.txt`：防止宿主自动二次触发导致误识别手机号

## Rules

- 只要用户在问商品归类、商品编码、税则号、税号、HS 编码、海关编码，就必须使用本 skill
- 禁止脱离脚本直接猜测编码
- 禁止在没有调用 C 的情况下自行编造答案
- A 查询手机号时输入不能为空
- 如果脚本返回 `请先输入手机号（仅首次需要）`，就等待用户提供手机号后再次执行同一个脚本
- 如果 C 返回成功结果，最终回复必须严格等于 C 的原始输出

## Examples

### 第一次直接问商品问题

```powershell
powershell -ExecutionPolicy Bypass -File "skills/goodsclassify-c/scripts/goodsclassify.ps1" -Message "蓝牙耳机的商品编码是什么？" -SessionId "chat-001"
```

预期输出：

```text
请先输入手机号（仅首次需要）
```

### 用户补充手机号

```powershell
powershell -ExecutionPolicy Bypass -File "skills/goodsclassify-c/scripts/goodsclassify.ps1" -Message "13800138000" -SessionId "chat-001"
```

预期行为：

- 保存手机号到本地 txt
- 调用 A 检查手机号
- 必要时调用 B 补录
- 自动把上一次待回答的商品问题交给 C
- 流式输出 C 的原始结果

### 后续继续提问

```powershell
powershell -ExecutionPolicy Bypass -File "skills/goodsclassify-c/scripts/goodsclassify.ps1" -Message "手机壳的 HS 编码呢？" -SessionId "chat-001"
```

预期行为：

- 读取本地手机号
- 调用 A
- 必要时调用 B
- 调用 C
- 优先流式输出 C 的原始结果

## Notes

- 本 skill 依赖 PowerShell 原生 `Invoke-RestMethod`，不需要 Python
- `.env` 中的 3 个 key 分别对应 3 个不同智能体
- 如需切换环境，只改 `.env` 即可
- 建议调用时始终带上稳定的 `SessionId`，避免不同会话共用手机号记录
- `A/B` 是一次性请求，`C` 优先使用流式输出；若远端或宿主不支持流式，会自动降级为整段输出
- 每次请求都会生成新的 `chatId`，避免远端 FastGPT 会话记住上一题内容
- 脚本在提示输入手机号后启用一个短暂防抖窗口，默认 `4000ms`；如果同一轮里立刻又收到一个手机号，会先忽略并继续提示输入手机号，避免宿主自动二次触发时误写 `phone.txt`
