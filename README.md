# 涟漪核心功能

创建一份当天的行程，设置开始时间、时长、地点、时间约束和前置行程。时间轴会标出重叠的安排，并沿着依赖关系检查后续行程能否准时开始。用户核对并确认方案后，应用才更新本机的行程。

## 体验看展流程

1. 点「创建看展示例」。初始计划为 14:00 集合、14:30 入场和 17:00 返程。
2. 点「模拟朋友晚到 40 分钟」，或编辑「与朋友集合」的开始时间。时间轴会提示入场和返程两处冲突。
3. 点「查看冲突」，选择演示场次 15:00 入场，或保留 14:30 的预约并在参观后会合。确认前可以核对时间、时长、地点和依赖变更。
4. 点「确认并更新行程」。刷新或重新启动后可以继续查看已保存的行程。

当前版本支持一份当天的行程。分析和保存都在本机完成，看展场次使用演示数据。

首页的摘要卡片用当天的主要行程作标题。优先显示预约，其次选择耗时最长的行程，时长相同则选开始较早的一项。看展示例显示「周末看展」。

右下角的加号用于添加行程。检测到冲突后，警告卡片右侧会显示「查看冲突」。滚动时间轴时，摘要和警告固定在上方，加号暂时收起。底部导航可在「日程」和「关系」之间切换，关系页显示前置行程和转场时间。

## 界面基准

使用原生 Material 3 的配色、组件、圆角和系统字体，尽量少做视觉改造。系统提供动态颜色时直接使用，否则通过 Material 3 生成对应明暗模式的色板。采用原生卡片、右下角 FAB 和底部导航栏。

Android 使用系统字体。Web 预览附带 Noto Sans SC 中文补字，支持离线显示。字体许可证见 [SIL OFL](assets/OFL.txt)。

## 运行和验证

在本目录使用 Flutter 3.50.1、Dart 3.14。Android 构建还需要 JDK 17 和 Android SDK 36。

在 Windows 上构建 Android 版本时，请使用纯英文的工程和 Android SDK 路径。当前工作区可以通过临时盘符映射来构建。

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Web 可用以下方式构建和预览。

```powershell
flutter build web --no-web-resources-cdn
python -m http.server 8781 --bind 127.0.0.1 --directory build/web
```

启动服务器后打开 [本机预览](http://127.0.0.1:8781/)。

## 开源组件

- [Material UI](https://pub.dev/packages/material_ui) 提供 Material 3 控件和简体中文日期、时间界面。
- [dynamic_color](https://pub.dev/packages/dynamic_color) 提供可用平台的系统动态配色。
- [Riverpod](https://pub.dev/packages/flutter_riverpod) 管理行程状态，[shared_preferences](https://pub.dev/packages/shared_preferences) 保存本机行程。
