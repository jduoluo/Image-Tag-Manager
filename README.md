# 图签 · Image Tag Manager

本地图片打标与筛选工具，支持 Windows 与 Android。标签直接保存在图片文件名前缀中，便于按标签组合查找图片。

开发者：多落孑（jduoluo）。当前版本：1.0.0。

## 功能

- 为图片批量添加、删除标签，调整主体名并预览改名结果。
- 使用 AND、OR、NOT 组合筛选图片。
- 管理标签名组、标签类组及多份配置，导入和导出配置。
- 查看图片，复制选中的图片；按平台提供文件操作与改名历史。
- 双端内置离线图文指南。

打标会修改文件名，依赖旧文件路径的软件引用可能失效。首次使用请先用图片副本熟悉流程。

## 安装与使用

GitHub 仓库名称已确定为 `jduoluo/Image-Tag-Manager`，远端仓库及下载页尚待创建。发布后，Windows 绿色版 ZIP 和 Android APK 将放在项目 Releases 中。

- Windows：解压完整程序包后运行 `Tuqian.exe`，保留同级 DLL 和 `data/`。更新时退出程序，覆盖程序文件并保留原来的 `config/` 文件夹。
- Android：安装对应设备架构的 APK。覆盖更新要求应用 ID、签名身份和版本规则兼容；自行签名的构建不能直接覆盖其他签名的安装版本。
- 双端默认启动时显示指南，也可从顶栏感叹号入口打开。

使用说明：[Windows](docs/WINDOWS_USER_GUIDE.md) / [Android](docs/ANDROID_USER_GUIDE.md)。

## 从源码构建

环境基线：Flutter 3.47.5、Dart 3.13.4。依赖版本以 `pubspec.lock` 为准。Windows 构建还需要 Visual Studio 的 C++ 桌面开发工具；Android 构建需要 Android SDK、兼容的 Java 和 Android 原生构建工具。

在项目根目录执行：

```sh
flutter pub get
flutter analyze
flutter test
```

Windows：

```sh
flutter build windows --release
```

产物位于 `build/windows/x64/runner/Release/`；分发时需要完整运行文件，排除个人 `config/` 和旧测试程序。

Android 调试版：

```sh
flutter build apk --debug
```

Android Release 需要自行准备签名密钥，并在本地创建 `android/key.properties`：

```properties
storeFile=../private-signing/your-release.p12
keyAlias=your-alias
storePassword=YOUR_LOCAL_PASSWORD
```

这里是配置格式示例，需替换为自己的值。项目当前使用 PKCS12 密钥库，密钥密码与密钥库密码相同；也可通过进程环境变量 `ITM_RELEASE_STORE_PASSWORD` 提供密码。不要提交密钥库或密码配置。

```sh
flutter build apk --release --split-per-abi
```

APK 位于 `build/app/outputs/flutter-apk/`。首次构建需要获取既有依赖和工具链；上述为通用构建步骤，尚未在全新电脑上完成验收。

源码包含 Dart、平台原生代码、测试、必要图标与内置指南。内部开发记录、本机专用脚本、测试图库、签名文件和构建缓存不属于公开源码内容。

## 许可与反馈

Copyright (c) 2026 jduoluo。图签自身的代码采用 **GPL-3.0-only**（仅第三版），许可全文见 [LICENSE](LICENSE)。允许商业使用；分发受 GPL 覆盖的程序或衍生版本时，须遵守 GPL 的许可和对应源码提供要求。

本程序不提供任何担保。第三方组件及素材保留各自适用的权利与许可，见 [第三方声明](THIRD_PARTY_NOTICES.md)。

项目地址：`https://github.com/jduoluo/Image-Tag-Manager`

问题反馈：`https://github.com/jduoluo/Image-Tag-Manager/issues`

以上地址按已确定的仓库名称预留，实际可访问性待仓库建立后核验。
