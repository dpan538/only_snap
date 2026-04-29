# only_snap — 项目技术总结

**平台**: iOS (SwiftUI + AVFoundation + Metal + CoreImage)  
**语言**: Swift 5.9+  
**最低部署目标**: iOS 17+  
**核心定位**: 一款极简风格的胶片感相机 App，UI 沉浸、操控直觉、输出质感。

---

## 项目结构

```
only_snap/
├── only_snapApp.swift     应用入口、AppDelegate、场景生命周期
├── ContentView.swift      主界面 SwiftUI 视图（取景框 + 控制层）
├── Theme.swift            设计系统（颜色、字体、布局常量）、AspectFormat 枚举
├── CameraManager.swift    AVFoundation 会话管理、拍照、后处理流水线
├── PreviewView.swift      双模式取景预览（标准 PreviewLayer / Metal RY 实时渲染）
├── ColorProcessor.swift   VG 滤镜核心算法（场景分析 + 多级 CIImage 管道）
└── CropManager.swift      传感器坐标系转换 + 多画幅裁切
```

---

## 架构概览

```
ContentView (SwiftUI, 主线程)
    │
    ├─ CameraManager (ObservableObject)
    │       └─ AVCaptureSession (sessionQueue)
    │               ├─ AVCaptureDeviceInput  (ultra-wide / wide / tele)
    │               ├─ AVCapturePhotoOutput
    │               └─ AVCaptureVideoDataOutput  (VG 模式时动态接入)
    │
    └─ PreviewView (UIViewRepresentable)
            └─ RYPreviewUIView (UIView)
                    ├─ AVCaptureVideoPreviewLayer  (RAW 模式，零开销)
                    └─ CAMetalLayer                (VG 模式，30fps Metal 渲染)
                            └─ CIContext (extendedLinearSRGB, cacheIntermediates:false)
```

**线程模型**:

| 操作 | 线程 |
|---|---|
| SwiftUI 状态、UI 更新 | 主线程 |
| AVCaptureSession 所有配置 | `sessionQueue`（通过 CameraManager 路由） |
| Metal 实时预览渲染 | `videoQueue`（serial，数据竞争安全） |
| 拍照后处理（色彩/裁切/超采样） | `imageProcessingQueue` |

---

## 文件详解

### `only_snapApp.swift`

- `AppDelegate` + `@UIApplicationDelegateAdaptor`: 锁定 portrait 方向
  - 原因：SwiftUI `WindowGroup` 无 iOS `.supportedInterfaceOrientations` modifier，必须通过 `UIApplicationDelegate.application(_:supportedInterfaceOrientationsFor:)` 返回 `.portrait`
- `scenePhase` 监听：`.active` → `camera.start()`，`.background` → `camera.stop()`（`.inactive` 不停，避免权限弹窗等瞬态触发重启）

---

### `Theme.swift`

- **颜色系统**: 奶油白底（`#F5F0E8`）+ 深棕文字，胶片相机质感
- **AspectFormat**: `.square(1:1)` / `.threeToFour(3:4)` / `.twoToThree(2:3)`
  - `heightRatio`: 驱动取景框高度计算
  - `verticalOffset(forWidth:)`: 实现画幅切换时取景框垂直居中动画
  - `next()` / `previous()`: 支持按钮点击与滑动手势双路切换

---

### `ContentView.swift`

**布局策略**: 永久竖屏布局（`VStack` 不旋转），横屏时单独旋转图标/文字。

关键实现：
- `iconRotation`: `landscapeLeft → .degrees(90)`, `portrait → .degrees(0)`
- 设备方向通过 `UIDevice.orientationDidChangeNotification` 接收，仅响应 `.portrait` 和 `.landscapeLeft`（开发机只向左转，右转和倒置被过滤）
- `isDeviceLandscape` / `landscapeRotationAngle: CGFloat { 0 }` 传递给 `PreviewView`
- `.rotationEffect(iconRotation)` 独立应用于每个图标/文字，不旋转整个层级（旋转 AVCaptureVideoPreviewLayer 所在的 CALayer 树会破坏 XPC 链路 → err=-17281）
- 格式按钮：`.rotationEffect` 必须放在 `.overlay(RoundedRectangle)` **之后**，确保边框随文字一同旋转
- 快门按钮：0.6s 线性动画驱动 `shutterProgress`，带弧形进度环；使用 `guard` 防止 session 未运行时触发

**控件布局**:
- 焦段行：21 / 35 / 50 / 105mm，激活焦段大字 + "mm" 单位，非激活小字
- 左侧：闪光灯按钮 + VG/raw 切换按钮
- 中间：快门按钮
- 右侧：画幅切换按钮（支持点击 + 上下/左右滑动）

---

### `CameraManager.swift`

**设备选择** (`device(for:mm)`):
- 21mm → 超广角（`builtInUltraWideCamera`）
- 35mm / 50mm → 广角（`builtInWideAngleCamera` + 数字变焦）
- 105mm → 长焦（`builtInTelephotoCamera` + 变焦）
- 等效焦距公式：`equivFL = 21.6 / tan(FOV_rad / 2)`（21.6mm ≈ 35mm 胶片对角线半径）

**焦段切换优化**:
- 同物理摄像头（如 35↔50mm 同用广角）：仅调 `videoZoomFactor`，跳过 begin/commit 开销
- 跨物理摄像头：完整 begin/remove/add/commit 流程

**AVCaptureSession 重要约定**:
- 所有 session 操作必须在 `sessionQueue` 执行
- `commitConfiguration()` 会静默重置所有 connection 的 `videoRotationAngle`，必须在 commit 后重新设置
- VG 模式的 `addVideoDataOutput` / `removeVideoDataOutput` 接受 `onCommit` 闭包，commit 完成后由主线程重新应用 previewLayer 角度

**拍照后处理流水线** (`handleCapturedPhoto`):
```
原始 CGImage（landscape）
    → CropManager.crop()          裁切到目标画幅
    → ColorProcessor.process()    色彩处理（VG 或 pass-through）
    → 动态超采样                   < 12MP → 上采样至 12MP；12–36MP → 不变；> 36MP → 下采样
    → CIUnsharpMask               自适应锐化（ISO 衰减，越高 ISO 越轻）
    → CINoiseReduction            条件降噪（ISO > 200 启用）
    → 黑色边框合成（VG 模式）      5pt 黑边 + inset 裁切
    → CGImageDestination          写入 JPEG + EXIF
    → PHPhotoLibrary              保存到相册
```

**ISO 自适应**（锐化强度衰减）:
- ISO ≤ 200：全强度
- ISO 800：×0.65
- ISO 3200：×0.30（下限）

**焦段锐化基准**:
- 21mm: 0.12 / 35mm: 0.16 / 50mm: 0.20 / 105mm: 0.28

---

### `PreviewView.swift`

**双模式架构**:

| 模式 | 渲染路径 | 开销 |
|---|---|---|
| RAW | `AVCaptureVideoPreviewLayer` | 零（系统级） |
| VG | `CAMetalLayer` + `AVCaptureVideoDataOutput` + CIContext | 30fps GPU |

**关键设计决策**:

1. **Metal Layer 预分配**: `layoutSubviews` 首次有效 bounds 时即分配 `CAMetalLayer`（隐藏），VG 切换时仅 `isHidden = false`，消除切换延迟。

2. **previewLayer.session 延迟绑定**: `configure()` 阶段不绑定，等 `layoutSubviews` 拿到非零 bounds 后才赋值，避免零帧触发 AVFoundation "Invalid frame dimension" → err=-17281。

3. **videoRotationAngle 管理**:
   - previewLayer connection: portrait=90°，landscapeLeft=0°
   - videoDataOutput connection: portrait=90°，landscape=0°（Metal 路径需要原生像素方向）
   - `lastLandscapeAngle` 保存最后设置的角度，供 `layoutSubviews` 使用（`commitConfiguration` 会重置连接角度，不能读 connection 上的值）

4. **60fps 节流**:
   - `setLandscape`: guard `abs(previewAngle - lastLandscapeAngle) > 0.1`
   - `setFormat`: guard `format == lastMaskFormat && sz == lastMaskBoundsSize && !maskLayers.isEmpty`
   - 避免快门动画（0.6s × 60fps = 36次）每帧触发 CALayer begin/commit

5. **`CIContext(.cacheIntermediates: false)`**: 30fps 不缓存中间 GPU 纹理，防止 Metal heap 无限增长 → OOM → err=-17281

6. **像素缓冲区方向检测**: `captureOutput` 用 `raw.extent.width > raw.extent.height` 判断方向，不用 `isLandscape` flag（主线程变量，与 videoQueue 存在数据竞争）

**实时预览渲染（`applyVGCurve`）**:
- 轻量 CIColorMatrix（R×1.02/B×0.95，比保存路径更保守）
- CIColorControls 饱和度 0.88
- 不做 CIToneCurve / CIColorPolynomial / CIBloom（实时帧不需要，且 bloom 会使预览模糊）

**LUT 预热**: `enableRYMode()` 在 `videoQueue` 触发 `vgAtmosphereLUT()` 预构建，拍照时直接命中缓存

---

### `ColorProcessor.swift`

**VG Vintage Gold 滤镜哲学**:

> 不是"注入暖色"，而是"亮部染金 + 自然色保护"——Pentax Gold 的光影层次感 × Kodak Gold 200 的肤色忠实度。

**完整处理管道**:

```
0. CINoiseReduction (pre-smooth, 0.01)   可选，105mm 跳过
1. applyVGToneCurve (CIColorPolynomial)  暗部冷蓝 / 亮部金色
2. CIToneCurve                           胶片 S 型曲线对比度
3. vgAtmosphereLUT (33³ CIColorCube)    逐色相大气映射
4. CIColorControls (adaptive sat)        自适应饱和度
5. CIBloom (dynamic)                     胶片卤化银晕染
6. applyAdaptiveCorrection               场景自适应精调
```

**Stage 1 — `applyVGToneCurve` (CIColorPolynomial)**:

核心公式：`out = a + b·in + c·in² + d·in³`（c=0）

| 通道 | 暗部偏置 a | 线性项 b | 立方项 d | 效果 |
|---|---|---|---|---|
| R | -0.012·s | 1.0 | +0.030·s | 暗部冷 → 亮部暖红 |
| G | -0.005·s | 1.0 | +0.013·s | 微量支撑金色色相 |
| B | +0.014·s | 1.0 | -0.032·s | 暗部蓝深度 → 亮部去青 |

强度 s 随色温 bell-curve 变化：
- 中性日光（~5000K）：s=1.0
- 极暖/极冷场景：s=0.40（下限）
- 日出日落：s=1.20
- 夜景：s=0.40

**Stage 3 — `vgAtmosphereLUT`（与 RY 的关键差异）**:

| 色相范围 | VG | 旧 RY | 原因 |
|---|---|---|---|
| 绿色 120–165° | 0° 偏移 + ×1.10 sat | +2° 偏移 | 防止植被变黄绿色 |
| 青色 165–200° | −3° 偏移 | −10° 偏移 | 保护水面/泳池/湿润天空颜色 |
| 红/橙/黄 暖色 | ×1.04–1.08 sat | ×1.05–1.10 sat | 避免肤色过饱和叠加 tone curve |
| 皮肤色 15–42° | satMult 上限 1.02 | satMult 上限 1.02 | 双重保护（LUT + tone curve） |

**Stage 6 — `applyAdaptiveCorrection` 场景分支**（优先级顺序）:

1. 退化/单色 → pass-through
2. 夜景 → 黑点轻度抬升（防数字黑噪点压死）
3. 日落 → 饱和度微增 1.06（VG 已有 tone curve，不再 1.10）
4. 雾霾 → 对比度增强 + 轻度去霾
5. 雨雪 → 饱和度大幅提升 + 微亮度
6. **水面（VG 新增）** → G 微压 + B 微增 + 冷偏置保护反光
7. 逆光 → 阴影提升（保护主体细节）
8. 阴天 → `applyOvercastEnhancement`（油画深度处理）
9. 绿色主导 → 轻度矫正（VG LUT 已保护，干预减半）
10. 钨丝灯/室内暖光 → 平滑反暖色
11. 标准中性 → 以 4593K 为基准的微调

**SceneAnalysis 指标**:
- `kelvin`: R/B 比 → 分段线性 → CCT（2500–9000K）
- `luminance`: 0.2126R + 0.7152G + 0.0722B（感知亮度）
- 三区域加权采样：中心 40%×40% 权重 0.6 + 全图 0.4，顶部 60%×25% 独立（高光代理）
- `isBacklit`: 中心亮度 < 全图亮度 55%
- `isWaterScene`（VG 新增）: B−R > 0.08 && B > 0.28 && satScore > 0.18

---

### `CropManager.swift`

**坐标系注意**:  
iPhone 传感器始终输出 landscape（宽 > 高）。`UIImage.orientation = .right` 显示时旋转 90°，因此：
- 显示宽 = 传感器高（srcH）
- 显示高 = 传感器宽（srcW）

| 画幅 | 传感器裁切逻辑 | 目标 |
|---|---|---|
| 3:4 | 不裁（srcH:srcW = 3024:4032 = 3:4） | 传感器原生 |
| 1:1 | min(srcW,srcH) 方形裁切 | 对称 center-crop |
| 2:3 | 保留 srcW，srcH 裁至 srcW×(2/3) | 等效 2:3 竖幅 |

---

## 关键工程问题与解决方案

### err=-17281（AVFoundation XPC 链路崩溃）

这是整个开发过程中最复杂的问题，有多个独立根源：

| 根因 | 症状 | 修复方案 |
|---|---|---|
| 零帧赋值 session | `Invalid frame dimension` | `layoutSubviews` 有效 bounds 后才赋值 |
| 60fps `setFormat` 触发 CALayer begin/commit | Metal 内存压力飙升 | `(format, boundsSize)` guard，跳过无变化调用 |
| CIContext 不限制中间缓存 | Metal heap 30fps 无限增长 | `.cacheIntermediates: false` |
| `commitConfiguration` 重置旋转角度 | VG 切换时预览旋转 | `onCommit` 闭包在 commit 后重新应用角度 |
| 横屏时 `videoDataOutput` 角度未更新 | 横屏预览保持竖屏视角 | `setLandscape` 同时更新 previewLayer 和 dataOutput 两个 connection |
| `isLandscape` flag 跨线程读写 | 偶发渲染方向错误 | 改用像素缓冲区尺寸判断（`raw.extent.width > raw.extent.height`） |

### CIBloom 白边问题

`CIBloom` 输出 extent 比输入大 `radius`（10pt）pt，下游 `createCGImage` 会渲染溢出区域产生白色边框。  
修复：`.cropped(to: splitOut.extent)` + CameraManager 中 5pt 黑边合成替代。

---

## 设计系统

**主色调**: 奶油白 `#F5F0E8`，深棕 `#2A2520`，哑光金属质感按钮  
**字体**: SF Symbols + SF Pro，多 size 组合（36/20/19/15pt）  
**交互**: 所有切换均有 haptic feedback（`.rigid` 风格）

**控件语言**:
- 取景框：圆角矩形 + 角标 + 中心十字准星（半透明白色）
- 焦段数字：激活态大字，非激活态小字，支持滑动连续切换
- 快门：三层同心圆（透明点击区 + 静态环 + 进度弧 + 实心圆）
- VG/raw 按钮：VG 激活时奶油底 + 深棕描边，raw 时哑光灰底

---

## 横屏支持

**策略**: UI 布局永远锁定竖屏，设备方向通过 `UIDevice.orientationDidChangeNotification` 单独追踪：
- 图标/文字：`.rotationEffect(iconRotation)` 独立旋转
- 取景预览：`videoRotationAngle` 调整（previewLayer + dataOutput 各自独立）
- 仅支持 `landscapeLeft`（`landscapeRight` 和 `portraitUpsideDown` 过滤掉）

---

## 下一步方向（可选）

- [ ] 曝光/对焦锁定（长按取景框）
- [ ] 定时器自拍
- [ ] 照片预览/快速回顾界面
- [ ] VG 模式强度滑杆（用户自定义金色浓度）
- [ ] 更多胶片 LUT 预设（Fuji Superia、Ilford HP5 黑白等）
- [ ] 视频录制支持
