# 踩坑记录（Pitfalls）

本文件记录开发/构建/分发 Mix-Recording 时踩过的坑与正确做法，避免重复。命令均为实测可用。
（英文文档见 `README.md` 与 `Documentation/`。）

## 1. 签名与分发

### 1.1 构建时禁用签名 → 下载后提示"已损坏"
- **症状**：安装后打开提示 *"Mix-Recording.app"已损坏，无法打开*，且"系统设置 → 隐私与安全性"里**没有**"仍要打开"按钮。
- **原因**：构建命令带了 `CODE_SIGNING_ALLOWED=NO`。bundle 里缺少 `_CodeSignature/CodeResources`，只剩可执行文件的 linker ad-hoc 签名，签名结构不完整 → Gatekeeper 判为 damaged（不是"未验证"，所以不给放行入口）。
- **正确做法**：不要禁用签名，让 xcodebuild 用它默认的 "Sign to Run Locally"（ad-hoc），同时自动应用 `Mix-Recording/Mix-Recording.entitlements`：
  ```bash
  xcodebuild -project Mix-Recording.xcodeproj -scheme Mix-Recording -configuration Release build
  codesign --verify --deep --strict --verbose=2 <app>   # 必须输出 "valid on disk"
  spctl -a -t exec -vv <app>                            # ad-hoc 仍会 rejected，这是预期的
  ```
- 全新下载的副本还需要一次 `xattr -dr com.apple.quarantine <app>`（或右键→打开）。要彻底免提示只能 Developer ID 签名 + 公证（需付费 Apple 开发者账号）。

### 1.2 在同步目录里构建 → codesign 失败
- **症状**：CodeSign 步骤报 `resource fork, Finder information, or similar detritus not allowed`。
- **原因**：产物落在文件提供者同步目录（如 iCloud 同步的 `~/Documents`，`-derivedDataPath build` 就在仓库内），bundle 被打上 `com.apple.FinderInfo` / `com.apple.fileprovider.fpfs#`。
- **正确做法**：用默认 DerivedData（`~/Library/Developer/Xcode/DerivedData`）或 `/tmp` 构建；用 `xattr -l <app>` 确认没有 FinderInfo/fileprovider 属性。

### 1.3 打包 zip 破坏签名
- 用 `ditto -c -k --sequesterRsrc --keepParent <app> <out.zip>`，不要用普通 `zip`。打包后解压复验：
  ```bash
  mkdir -p /tmp/check && (cd /tmp/check && ditto -x -k <zip> .)
  codesign --verify --deep --strict /tmp/check/Mix-Recording.app
  ```

### 1.4 `brew reinstall` 后 App 无窗口
- **症状**：进程存在（`pgrep` 有）但 `CGWindowList` 显示 0 个窗口，或 `open` 后什么都没起。
- **原因**：brew reinstall 是"先删后解包"，LaunchServices 残留指向旧 bundle 的注册。
- **正确做法**：
  ```bash
  /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f -R -trusted /Applications/Mix-Recording.app
  open /Applications/Mix-Recording.app        # 按路径打开，比 open -a 名称稳
  ```
- 判断 bundle 本身是否健康：直接前台跑 `Contents/MacOS/Mix-Recording`，能起且窗口正常就说明包没问题。

## 2. Homebrew

### 2.1 Homebrew 6 的 tap 有信任门槛，且 cask 必须声明 macOS 依赖
- **症状**：`brew tap user/tap <repo-url>` 报 `Cannot tap ...: invalid syntax in tap!`（误导性错误）。
- **原因**：① Homebrew 6 拒绝加载未信任 tap 的 cask；② cask 缺少 `depends_on macos:`，跨平台校验先报 `Invalid cask (Linux on ...)`。
- **正确做法**（顺序不能反）：
  1. cask 里写 `depends_on macos: :ventura`（**不要**写已弃用的 `">= :ventura"` 字符串比较形式）；
  2. `brew trust dct74/tap`；
  3. `brew tap dct74/tap`；
  4. `brew install --cask mix-recording`。
- 本项目的 cask 放在通用 tap 仓库 `dct74/homebrew-tap`（cask 全名 `dct74/tap/mix-recording`）。

### 2.2 tap 名 = 仓库名去掉 `homebrew-` 前缀
- **症状**：把 cask 直接放进 app 仓库（`dct74/Mix-Recording`）后，安装名变成 `dct74/mix-recording/mix-recording`，看起来像把名字写重了。
- **原因**：仓库名不是 `homebrew-<名字>` 形式时，Homebrew 只能用仓库名本身当 tap 名（`dct74/mix-recording`），于是 `tap/cask` 两段恰好同名；而且这种仓库**不能用简写 tap**，必须 `brew tap dct74/mix-recording https://github.com/dct74/Mix-Recording` 传完整 URL。
- **正确做法**：想要 `user/tap/<名字>` 这种规范形式，cask 必须放在名为 `homebrew-tap`（或 `homebrew-<名字>`）的仓库里，然后 `brew tap dct74/tap` 即可（无需 URL）。同一个 cask 不要同时存在于两个 tap，否则同名产生歧义。

### 2.3 改了 cask 但 brew 仍用旧版
- **原因**：本地 tap 的 git 克隆滞后（Homebrew 会复用缓存）。
- **正确做法**：
  ```bash
  T="$(brew --repository)/Library/Taps/dct74/homebrew-tap"
  git -C "$T" fetch origin && git -C "$T" reset --hard origin/main
  ```

### 2.4 发布 Release：`gh release create` 受 scope 预检阻挡
- **症状**：`gh release create` 报 `"workflow" scope may be required`。
- **正确做法**：用 REST API 建 release，再用 curl 上传资产（`repo` scope 足够）：
  ```bash
  gh api --method POST /repos/<owner>/<repo>/releases \
    -f tag_name=v1.0.1 -f target_commitish=main -f name="..." -f body="..."
  REL=$(gh api /repos/<owner>/<repo>/releases/tags/v1.0.1 --jq .id)
  curl -sS -X POST -H "Authorization: Bearer $(gh auth token)" \
    -H "Content-Type: application/zip" --data-binary @Mix-Recording-1.0.1.zip \
    "https://uploads.github.com/repos/<owner>/<repo>/releases/$REL/assets?name=Mix-Recording-1.0.1.zip"
  ```
  注意：`gh api --hostname uploads.github.com` 会拼成 `api.uploads.github.com` 而失败，用 curl。
- cask 用 `version` + `sha256` 固定产物，**改了产物就要升版本**（本项目 1.0 因产物未签名，发布 1.0.1 并删除 v1.0），并核对"下载文件的 sha256 == 本地"。

## 3. Xcode 工程设置

- **手写 Info.plist**：必须同时设置 `GENERATE_INFOPLIST_FILE = YES` 与 `INFOPLIST_FILE = Info.plist`，才会"自定义键 + 自动注入的标准键"都生效；只设 `INFOPLIST_FILE` 会丢掉 `CFBundleIdentifier/Executable/Version`，App 没有 Bundle ID。
- **`INFOPLIST_KEY_*` 有白名单**：`INFOPLIST_KEY_NSScreenCaptureUsageDescription` 不被支持、静默忽略，此类键必须写进 Info.plist 文件。
- **接手他人工程**：删掉 `DEVELOPMENT_TEAM`（原作者的 Team ID 会导致签名/证书不匹配）。
- **文件系统同步组**（`fileSystemSynchronizedGroups`）：放进被同步目录（如 `Mix-Recording/`）的 `.swift` 会自动参与编译；要在仓库根目录新增源文件，才需要手工改 pbxproj 四处（PBXBuildFile、PBXFileReference、group children、Sources phase）。
- **测试 target 的 `MACOSX_DEPLOYMENT_TARGET`** 若不显式设置会继承工程级值，容易与 app target 不一致。

## 4. 音频 / AVAudioEngine（本项目历史坑）

- **不要在录音时把麦克风送进连到输出节点的混音器**：`engine.mainMixerNode` 默认连着输出，麦克风 + 捕获到的系统音频都会被播放（监听），麦克风再录一遍延迟信号 → 声学反馈环路（实测 ~12ms 周期振铃、中位置噪从 ~200 升到 5570）。正确架构：麦克风走 `AVAudioRecorder`、系统音频走 ScreenCaptureKit，停止时用 **AVAudioEngine 手动渲染模式离线混音**（`AudioMixdown`），全程不碰音频硬件。
- **tap 取样在音量之后**：把 `mainMixerNode.outputVolume` 置 0 会让**录音也变静音**（不是只静音监听）。另外置 0 还会让 AVAudioEngine 剪掉静音子图，导致 `AVAudioPlayerNode.play()` 抛 `player started when in a disconnected state`（隔离用的最小复现程序里却正常，说明与真实图/时序有关）。
- **运行中不能改音频图**：`engine.start()` 之后调用 `connect/disconnect/detach` 会抛 `required condition is false: !IsRunning()`；必须先 `engine.stop()` 再改。
- **`AVAudioPCMBuffer` 的坑**：新建缓冲在设置 `frameLength` 之前其 `mDataByteSize` 为 0；拷贝时必须**先设 `target.frameLength`**，容量比较要用 `min(src, dst)`，否则每次拷贝都失败。
- **tap 交付的帧数不保证等于 `bufferSize`**：实测请求 4096 却交付 4800 帧；缓冲池必须自适应（不够大就按需分配并回收），否则所有缓冲被丢弃 → 文件只有文件头、0 帧、无法播放（症状："录音文件无法播放"，`afinfo` 显示 `audio 0 valid frames`）。
- **停止顺序**：先关采集闸（`isCapturing = false`）→ drain 写队列 → 关文件 → 再移动/提升文件；否则会有 in-flight 写在文件移动后重建残留。
- 混音两路电平相加容易削顶，多路混音时每路给 −3dB 余量（`player.volume = 0.707`）。

## 5. 权限（TCC）

- **会失效的时机**：改 bundle ID；每次重新构建 ad-hoc 签名的 App（签名变化）。麦克风与屏幕录制都要重新授权。
- **申请屏幕录制必须显式调用 `CGRequestScreenCaptureAccess()`**（只 `CGPreflightScreenCaptureAccess()` 不够），否则应用不会出现在"系统设置 → 隐私与安全性 → 屏幕录制"列表里，用户找不到开关。自定义 NSAlert 要在调用之后弹。
- 沙箱开启时 `FileManager` 的临时/文档目录解析到 `~/Library/Containers/<bundle-id>/Data/` 下。

## 6. 可复用的验证方法

| 目的 | 方法 |
| --- | --- |
| 回声/反馈 | 播放 20ms 1kHz 单脉冲 wav，2ms 窗口算 RMS 包络：正常 30ms 内衰减完；有反馈则持续振铃且周期约等于设备 I/O 往返（~12ms）。同时比较"中位置噪"基线 |
| 录音是否有内容 | `afconvert -f WAVE -d LEI16 -c 2 in out.wav` 后 python 读回算峰值（peak>300 即有声）。注意 `-d LEI16@48000` 这种带 `@` 的写法在 macOS 上偶发报 `Couldn't open input file ('dta?')` |
| 混音正确性/对齐 | python 生成不同采样率、带已知偏移的合成源，混音后按时间轴打印 RMS/峰值；再用 `AVURLAsset` + `AVAudioPlayer` 复读确认容器可播放 |
| 容器/时长 | `afinfo`；`plutil -p` 看 Info.plist |
| UI 流程 | 优先读状态文本（AXValue）；System Events 会间歇性失效（跨应用 0 窗口、CGEvent 也送不进），备选：自建 Swift AX 客户端按名点击 + CGWindowList 定位窗口 + 屏幕捕获按像素颜色识别按钮 + CGEvent 点击（SwiftUI 常无可访问性标签，只能按索引/坐标） |

## 7. 工程纪律

- **脚本化大范围改代码前先备份**：曾用 python 按索引切片删代码时算错范围，把 `CombinedAudioEngine.swift` 从 659 行拼成 207 行碎片，只能从 git 索引恢复后整体重写。
- 优先用**精确文本替换**而不是"起点/终点索引切片"；replace 要断言语料命中次数（`assert count == 1`），命中 0 或多次立即停下；每次改动后**立刻编译**，不要累积多处修改。
- **声音类问题必须用数值验证**（峰值/包络/中位置噪），"看起来正常/声音没问题"不足以判定（本项目"系统录音似乎没问题"实际也是 0 帧）。
- 删除用户可见产物前先确认或备份（`/tmp/backup_mic_recording.m4a`、`/tmp/user-recording-backup.m4a` 等即为历次测试前的备份）。
