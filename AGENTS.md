# AGENTS.md

本仓库的历史踩坑与正确做法汇总在 **`Documentation/Pitfalls.md`**。改动构建、签名、分发或音频代码前先读一遍。

最容易重犯的三条：

1. **签名**：构建命令不要加 `CODE_SIGNING_ALLOWED=NO`（bundle 会缺 `_CodeSignature/CodeResources`，下载后被判"已损坏"）。用项目默认的 ad-hoc 签名，构建后跑 `codesign --verify --deep --strict` 确认输出 `valid on disk`；只在默认 DerivedData 或 `/tmp` 下构建（同步目录里构建会报 `detritus not allowed`）。
2. **音频**：不要监听麦克风（`mainMixerNode` 连着输出会造成声学反馈环路，实测约 12ms 振铃）；`AVAudioPCMBuffer` 必须先设 `frameLength` 再拷贝，tap 交付帧数不保证等于 `bufferSize`，缓冲池必须自适应；运行中的 `AVAudioEngine` 不能改图（先 `stop()`）。
3. **改码**：大范围修改前先备份，用精确文本替换并断言命中次数，每次改完立刻编译；音频问题必须用数值（峰值/包络/中位置噪）验证。
