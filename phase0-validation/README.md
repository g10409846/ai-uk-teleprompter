# Phase 0 · 原生可行性验证

## 你需要在你的 Mac 上做的 3 步

### 第 1 步：运行冒烟测试

打开终端，cd 到这个文件夹，运行：

```bash
chmod +x setup.sh
./setup.sh
```

这会自动检查环境、跑冒烟测试、验证 VAD 和 Prompt 引擎的基本逻辑。

### 第 2 步：在 Xcode 中打开并运行

**前提**：你的 Mac 需要安装 Xcode（App Store 免费下载）。开发 Apple 平台 App 必须有这个。

两种方式：

**方式 A（推荐）**——在 Finder 中双击 `Package.swift`，Xcode 会自动打开整个项目。然后在 Xcode 顶部选择运行目标为 **My Mac**，按 `Cmd+R` 运行冒烟测试。

**方式 B**——打开 Xcode → File → Open → 选择 `Package.swift`。

### 第 3 步：允许权限

首次运行完整实验时，macOS 会依次弹出权限请求：
- **相机** → 允许
- **麦克风** → 允许
- **语音识别** → 允许

如果不小心点了拒绝，去「系统设置 → 隐私与安全性」重新授权。

## 权限配置（如果第一次拒绝后需要重新授权）

在系统设置中启用：
- 隐私与安全性 → 相机 → 勾选你的 App
- 隐私与安全性 → 麦克风 → 勾选你的 App
- 隐私与安全性 → 语音识别 → 勾选你的 App

## 项目结构

```
phase0-validation/
├── Package.swift
├── Sources/
│   ├── Core/Models/Types.swift           # 所有数据类型
│   ├── Core/Services/
│   │   ├── VADEngine.swift               # 能量型语音活动检测
│   │   ├── PromptEngine.swift            # 光标跟踪、语速映射、锚定
│   │   ├── SpeechService.swift           # SFSpeechRecognizer 封装
│   │   └── ThermalMonitor.swift          # 系统热状态轮询
│   └── Phase0Validator/
│       ├── main.swift                    # CLI 入口：冒烟测试
│       └── PhaseZeroValidator.swift      # 三实验编排器
├── Resources/
│   └── test-scripts/
│       ├── script1-short.txt             # 流畅念稿（~190字）
│       ├── script2-with-pauses.txt       # 含自然停顿
│       └── script3-with-revisions.txt    # 含改口、跳句、即兴
├── Tests/CoreTests/VADAndPromptTests.swift
└── README.md
```

## 三个实验

### 实验 1：同时采集（Concurrent Capture）

**问题**：前置相机 + 内置麦克风同时录制视频，并从同一条音频管线取样本给 VAD 和语音识别，会不会冲突或丢帧？

**方法**：AVCaptureSession 单管线 → 视频输出给文件录制，音频数据输出给 VAD/语音识别。录制 5 分钟。

**通过条件**：成片可播放、音画同步、无 AVCaptureSession 冲突日志。

### 实验 2：跟随手感（Follow Feel）

**问题**：VAD 启停 + 语速调速 + 讲稿锚定的综合体验能否达到 7/10？

**方法**：用 3 段测试稿（流畅/停顿/改口），VAD 驱动启停，Speech 驱动调速和位置锚定。跟踪状态转换次数、速度方差、光标跳跃次数。

**通过条件**：停顿与恢复自然，无明显大跳（5 次以内），用户主观评分 ≥ 7/10。

### 实验 3：热与稳定性（Thermal & Stability）

**问题**：1080p30 录制 + 语音识别 5 分钟是否触发 serious/critical 热状态？

**方法**：录制 1080p30 视频 5 分钟，同时 VAD/识别运行，轮询 thermalState。如果 serious，回退测 720p30。

**通过条件**：不进入 serious 或 critical，成片正常。

## 版本要求

- macOS 14+ / iOS 17+
- Xcode 15+
- Swift 5.9+

## 隐私配置

在你的 Xcode 项目 Info.plist 中添加：

```xml
<key>NSCameraUsageDescription</key>
<string>用于录制口播视频</string>
<key>NSMicrophoneUsageDescription</key>
<string>用于语音跟随和音频录制</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>用于识别语速以自动滚动提词</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>用于保存录制的视频</string>
```

## 运行冒烟测试

```bash
cd phase0-validation
swift test
```

## 运行完整验证

在 Xcode 中创建 macOS App target，将 PhaseZeroValidator 作为 Swift Package 依赖引入，然后：

```swift
let validator = PhaseZeroValidator()
try validator.setup()

let script = Script(title: "测试", rawText: "你的口播文案...")
let settings = AppSettings.default

validator.onStatusUpdate = { print($0) }
validator.onAllComplete = { report in
    print("Gate: \(report.gateStatus)")
    for r in report.recommendations { print("→ \(r)") }
}

validator.runAllExperiments(script: script, settings: settings)
```

## 退出闸门

只有同时满足以下条件才进入完整 MVP：

1. 实测设备可稳定同时录制和分析音频
2. 用户主观评分"跟得上且不干扰念稿"至少 7/10
3. 自动模式失败时，手动模式仍能完整录制
4. 已确定 P0 的默认画质、最长时长、联网政策和目标机型

## 输出物

- 三段录制文件（实验 1+3 的成片）
- Phase 0 报告（实验结论 + Gate 状态 + 建议）
