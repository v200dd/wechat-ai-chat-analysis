# wechat-ai会话分析

微信 AI 助手 Tweak（Theos 工程）：读取当前聊天上下文，做意图分析、生成建议回复，并支持记忆档案、画图与视频。

> 仅供学习与个人研究使用。请遵守微信服务条款与当地法律法规，不要用于骚扰、诈骗或批量营销。

## 功能

- **意图分析**：判断对方这句话的潜台词、情绪与意图，流式输出，边生成边显示。
- **建议回复**：一次生成多条不同风格的话术，点一下即可填入输入框。
- **记忆档案**：按联系人保存关系、称呼、偏好与历史摘要，分析时自动带上。
- **内嵌分析卡**：分析结果直接显示在消息气泡下方，不用来回切页面。
- **长按分析**：长按任意文字消息 →「🤖 分析」，只分析这一条。
- **画图 / 视频**：聊天里发 `#画图`、`#改图`、`#视频`，生成后直接发送到当前会话。
- **会话级开关**：每个聊天单独开启或关闭，互不影响。
- **自动回复**：可选功能，默认关闭；按会话配置，收尾消息不自动回。

## 环境要求

- 已越狱的 iOS 设备（rootful 或 rootless 均可），iOS 14.0+
- [Theos](https://github.com/theos/theos)
- iOS SDK（默认使用 `iPhoneOS14.5.sdk`）
- `ldid`（Theos 打包签名用）

## 编译

```bash
make package                 # rootful：/Library/MobileSubstrate
make package ROOTLESS=1      # rootless：/var/jb/Library/MobileSubstrate
```

产物在 `packages/`：

```
com.wechatai.analysis_2.7.6_iphoneos-arm64.deb
```

Theos 不在 `~/theos` 时，改 `Makefile` 第一行，或编译时传入：

```bash
make package THEOS=/path/to/theos
```

## 安装

```bash
scp packages/com.wechatai.analysis_2.7.6_iphoneos-arm64.deb root@DEVICE_IP:/var/mobile/
ssh root@DEVICE_IP "dpkg -i /var/mobile/com.wechatai.analysis_2.7.6_iphoneos-arm64.deb && killall -9 WeChat"
```

rootless 设备（Dopamine / palera1n）安装带 `-rootless` 后缀的包。

## 使用

| 操作 | 说明 |
|---|---|
| 聊天页顶部左侧小字 | `AI 会话分析（开启/关闭）`，点击打开分析面板 |
| 连点聊天页顶部备注名三下 | 隐藏 / 显示入口 |
| 长按文字消息 | 「🤖 分析」，只分析这一条，不写历史、不自动回复 |
| 设置 → 接口设置 | 填端点、API Key、模型 |

入口只在聊天页显示，朋友圈、视频号等页面不出现。

## 接口配置

设置 → 接口设置：

| 项 | 默认值 |
|---|---|
| 接口地址 | `https://api.openai.com/v1`（需自备 Key） |
| 对话模型 | `gpt-4o-mini` |
| 画图模型 | `gpt-image-1` |
| 视频模型 | `sora-2` |

- 支持任意 OpenAI 兼容接口：把地址填到 `/v1`，插件自动补 `/chat/completions`。
- 「获取模型」会请求 `/models` 后列出可选模型。
- 画图 Key 留空时复用主 Key；视频 Key 可单独填写。
- 模型名称仅作默认值，按你的服务商文档修改即可。

## 画图 / 视频

在已开启的会话里发：

```
#画图 一只橘猫趴在窗台晒太阳
#改图 换成油画风          （先发一张图作为参考）
#视频 海边日落延时摄影
```

端点：

| 能力 | 路径 |
|---|---|
| 文生图 | `/v1/images/generations` |
| 图生图 | `/v1/images/edits` |
| 视频 | `/v1/videos/generations` |
| 轮询 | `/v1/videos/{request_id}` |

生成后直接下载并发送到当前会话，不写相册。
调用明细在 设置 → 画图 / 视频 → 调用日记（每次调用一行，点开看步骤）。

## 流式

- 判官与建议回复都走 SSE（`stream: true`）。
- 读心结论 `humanRead` 排在 JSON 第一位，收到多少显示多少，卡片逐字长出来。
- 网关不支持 stream 时自动退一次普通请求，仍失败才提示「这条没能分析出来」。

## 目录结构

```
.
├── Makefile                     # 构建（rootful / rootless）
├── control                      # deb 元信息
├── WeChatAIAnalysis.plist       # 注入过滤：仅 com.tencent.xin
└── Sources/
    ├── JGPTCommon.h/.m          # 日志、Toast、Alert、取顶层 VC、菜单状态
    ├── JGPTConfig.h/.m          # 配置中心（NSUserDefaults + 会话开关 + 用量）
    ├── JGPTModels.h/.m          # 数据模型：JGPTJudgeResult / JGPTMemoryNote
    ├── JGPTPrompts.h/.m         # 全部提示词（改文案只动这里）
    ├── JGPTClient.h/.m          # HTTP：对话 / 画图 / 视频 / 模型列表
    ├── JGPTStream.h/.m          # SSE 流式对话（对话与判官共用）
    ├── JGPTMemoryStore.h/.m     # 记忆档案与上下文持久化
    ├── JGPTWeChat.h/.m          # 微信运行时适配（类/方法动态解析）
    ├── JGPTEngine.h/.m          # 主流程：收消息 → 判断 → 起草 → 记忆 → 自动回复
    ├── JGPTAssistantPanel.h/.m  # 分析 / 建议回复面板
    ├── JGPTChatCard.h/.m        # 聊天页顶部入口条
    ├── JGPTInlineCard.h/.m      # 消息气泡下方的内嵌分析卡
    ├── JGPTMessageMenu.h/.m     # 长按消息 →「🤖 分析」
    ├── JGPTSettingsVC.h/.m      # 设置中心
    ├── JGPTMemoryVC.h/.m        # 记忆档案列表 / 编辑
    ├── JGPTMediaLog.h/.m        # 画图 / 视频调用日记
    ├── JGPTMediaLogVC.h/.m
    ├── JGPTAboutVC.h/.m         # 关于页
    └── JGPTEntry.m              # 注入入口：Hook 安装、入口挂载
```

## 修改指引

- 改提示词 → `Sources/JGPTPrompts.m`
- 改设置项 → `JGPTConfig.h` 加属性 → `JGPTConfig.m` 加 seed/getter/setter → `JGPTSettingsVC.m` 加行
- 改内嵌卡样式 → `Sources/JGPTInlineCard.m`
- 改长按菜单 → `Sources/JGPTMessageMenu.m`
- 微信类名/方法变动 → 只改 `Sources/JGPTWeChat.m`
- 改自动回复策略 → `JGPTEngine.m` 的 `autoReplyIfNeeded:` / `isClosingMessage:`
- 改画图/视频端点 → `JGPTClient.m` 的 `generateImage:` / `generateVideo:`

## 说明

工程只做静态分析与运行时适配，不包含任何第三方二进制。
微信内部类名、方法签名会随版本变化；升级微信后如果入口消失，优先检查
`JGPTWeChat.m` 里的动态解析和 `JGPTInlineCard.m` 的 `rowHeight` hook。

## License

[MIT](LICENSE)
