# 构建 Echoes

以下命令均在仓库根目录执行。本指南覆盖 Android APK、Windows x64 与 Ubuntu/Linux x64。项目通过 `.fvmrc` 固定 Flutter **3.47.5**，CI 使用相同版本；`pubspec.yaml` 要求 Dart `^3.10.8`。

## 准备环境

1. 安装 Flutter 3.47.5，并确认 `flutter`、`dart` 在 `PATH` 中。也可以执行 `fvm install`，之后使用 `fvm flutter` / `fvm dart` 运行本指南中的命令。运行 `flutter doctor -v` 检查工具链。
2. Android 构建需要 Android SDK、Build Tools、已接受的 SDK licenses，以及 JDK 17。首次配置可运行 `flutter doctor --android-licenses`。Linux 构建需要 C/C++、GTK 与打包工具；Ubuntu 22.04 可安装与 CI 相同的依赖：

   ```bash
   sudo apt-get update
   sudo apt-get install -y clang lld llvm cmake ninja-build pkg-config \
     libgtk-3-dev liblzma-dev libayatana-appindicator3-dev \
     desktop-file-utils zip
   ```

3. 拉取 Dart/Flutter 依赖：

   ```bash
   flutter pub get
   ```

仓库已提交 Freezed、JSON 和 Drift 的生成文件。发布构建直接使用这些文件；CI 会检查每个 `part` 指向的生成文件存在并已提交，然后通过静态分析和编译检查其可用性。发布构建不需要运行 `build_runner`。当前检查不能证明生成文件与输入完全同步；修改模型或数据库定义时须在同一提交中更新对应生成文件。

当前锁定的 `analyzer 7.6.0` 只支持到较早的 Dart 语言版本，使用 Flutter 3.47.5 / Dart 3.13 执行 `build_runner` 会因 SDK 中的 dot shorthand 语法崩溃。若修改了生成器输入，需要先将 Freezed、Drift、JSON 等生成器依赖整体升级到兼容 Dart 3.13 的版本，再运行并提交生成结果：

```bash
dart run build_runner build --delete-conflicting-outputs
```

Flutter 3.47.5 的分析器会列出旧代码中的提示和警告；当前 PR 检查保留这些输出，但只将 `error` 视为失败。可在本地用 `flutter analyze --no-fatal-infos --no-fatal-warnings` 复现该检查。

## 版本号与 Android 签名

`pubspec.yaml` 中的 `version: 2.0.1+2074` 是当前版本：`2.0.1` 是 Android `versionName`，`2074` 是基础 `versionCode`，Linux 打包脚本使用完整的 `2.0.1+2074` 作为 DEB 版本。发布新版本前递增构建号；安装更新时，新 APK 的**实际** `versionCode` 必须大于设备上已有的包。

发布签名可放在被 Git 忽略的 `android/key.properties` 中：

```properties
storeFile=/absolute/path/to/release-keystore.jks
storePassword=<store-password>
keyAlias=<key-alias>
keyPassword=<key-password>
```

也可以改用 `ECHO_STORE_FILE`、`ECHO_STORE_PASSWORD`、`ECHO_KEY_ALIAS`、`ECHO_KEY_PASSWORD` 环境变量。`storeFile` 建议填写绝对路径；不要提交密钥、密码或 `key.properties`。当前 [`android/app/build.gradle.kts`](android/app/build.gradle.kts) 在没有完整发布签名配置时**会用调试密钥签署 release 构建**：这种 APK 不能直接覆盖用正式密钥安装的版本。分发前使用 Android SDK Build Tools 的 `apksigner verify --print-certs <APK 路径>` 核对证书。

### `versionCode` 与 ABI

Flutter 默认会给 `--split-per-abi` 产物添加 ABI 版本码偏移。本项目在 `android/gradle.properties` 设置了 `force-version-code-ignoring-abi=true`，因此 ARM64、ARM32、x86-64 拆分 APK 和通用 APK 都使用 `pubspec.yaml` 中的基础构建号：当前均为 **2074**。今后发布升级包时逐次提高这个构建号即可，不会因 ABI 偏移突然跳到 4073。可用 `aapt dump badging <APK 路径>` 核对实际 `versionCode`。

如果某台设备已经安装过带旧 ABI 偏移、实际版本码高于 2073 的 APK，切换到此规则时需要先把构建号提高到该设备已安装版本码之上。此设置适用于目前通过 GitHub 直接分发 APK 的方式；将来若要向 Google Play 同时上传多个按 ABI 拆分的 APK，需重新评估该商店的版本码要求。

本机若保留了 Git 忽略的 `scripts/local/build_android_release_arm64.sh`，也可以用它生成并校验发布签名的 ARM64 单包。该脚本是这台机器的私有辅助工具，不属于仓库；它使用 `pubspec.yaml` 的构建号，并在 `build/` 之外记录上次 ARM64 版本码，拒绝生成比已有 APK 更低的版本。重新构建同一版本可以复用构建号；发布下一版时先递增 `pubspec.yaml`。其他机器按下面的通用命令构建即可。

## Android APK

下面三种构建方式任选其一。命令里的 `--no-pub` 以已执行 `flutter pub get` 为前提；如果依赖刚改过，请先重新执行 `flutter pub get`。

| 目标 | 命令 | 产物 |
| --- | --- | --- |
| 按 ABI 拆分，生成 32 位 ARM、64 位 ARM、x86-64 三个 APK | `flutter build apk --release --no-pub --split-per-abi` | `build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk`、`app-arm64-v8a-release.apk`、`app-x86_64-release.apk` |
| 只生成 Android ARM64 APK | `flutter build apk --release --no-pub --split-per-abi --target-platform android-arm64` | `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` |
| 生成一个包含所有目标 Android ABI 的通用 APK | `flutter build apk --release --no-pub` | `build/app/outputs/flutter-apk/app-release.apk` |

通用 APK 只是把**多个 Android CPU 架构**装进一个文件，不包含 Linux 桌面版；文件体积通常比单个 ABI 包大。独立分发时可选择通用包以减少用户选错架构的情况；已知设备都是 ARM64 时，单独的 ARM64 包更小。

构建后至少核对版本码、ABI 与签名。`aapt`、`apksigner` 随 Android SDK Build Tools 安装；如果命令不在 `PATH` 中，请使用该 Build Tools 目录下的绝对路径。

```bash
aapt dump badging build/app/outputs/flutter-apk/app-release.apk
unzip -Z1 build/app/outputs/flutter-apk/app-release.apk | awk -F/ '/^lib\/[^/]+\// {print $2}' | sort -u
apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
```

构建拆分包时将上面路径换成对应的 `app-arm64-v8a-release.apk` 等文件。APK 的包名应为 `com.az1n.echoes`；在已有正式版的设备上安装前，还需确认签名证书一致。

## Linux x64：bundle、DEB 与 ZIP

在 Ubuntu/Linux x64 主机上执行：

```bash
flutter build linux --release --no-pub
bash scripts/package_linux_deb.sh
```

产物位置：

| 类型 | 路径 | 用途 |
| --- | --- | --- |
| 原始 Flutter bundle | `build/linux/x64/release/bundle/` | 可执行文件 `echoes` 与必需的 `lib/`、`data/`；拷贝时必须保留整个目录 |
| Debian 安装包 | `build/linux/packages/echoes_<pubspec 版本>_amd64.deb` | 安装到 `/opt/echoes`，带应用菜单项和图标 |
| 便携 ZIP | `build/linux/packages/echoes_<pubspec 版本>_linux-x64-bundle.zip` | 包含完整原始 bundle |

打包脚本检查 Flutter 引擎、插件、manifest 和资源是否齐全。DEB 声明运行依赖 `libgtk-3-0`、`libayatana-appindicator3-1` 和 `libmpv1`。当前验证基线是 Ubuntu 22.04 x64；Ubuntu 24.04 / Wayland 等环境仍需实际安装和播放验证。

Linux GTK 应用 ID 与安装的 `com.az1n.echoes.desktop` 对齐，窗口和应用菜单按系统语言显示 Echoes 或“回响”；DEB 提供应用菜单项、桌面图标和系统媒体面板身份。便携 bundle 内的 `echoes` 可执行文件也会设置窗口图标和标题。Ubuntu 托盘中键可触发“显示应用名”；双击激活还取决于托盘宿主与系统 Ayatana 库是否提供 `Activate`，Ubuntu 22.04 的 0.5.90 库不提供该方法，菜单中的显示项仍可使用。

## Windows x64：EXE 安装包与便携 ZIP

Windows 构建需要 Visual Studio 的 C++ 桌面开发工具和 Windows SDK，打包需要 Inno Setup 6。在 PowerShell 中执行：

```powershell
flutter pub get
flutter build windows --release --no-pub
./scripts/package_windows.ps1
```

脚本从 `pubspec.yaml` 读取完整版本，核对程序版本，检查音频库、Flutter 引擎与资源，并将 Visual Studio 提供的 x64 Visual C++ 运行库一起打包。默认输出在 `build/windows/packages/`：

| 类型 | 文件名 | 用途 |
| --- | --- | --- |
| EXE 安装包 | `echoes-<版本>-windows-x64-setup.exe` | 安装到当前用户的应用目录，提供开始菜单项、可选桌面快捷方式和卸载功能 |
| 便携 ZIP | `echoes-<版本>-windows-x64-portable.zip` | 解压整个目录后运行 `echoes.exe`；应用设置、缓存仍使用系统用户目录 |
| SHA-256 校验文件 | `echoes-<版本>-windows-x64-SHA256SUMS.txt` | 核对两种产物的文件完整性 |

Inno Setup 不在默认安装位置时，可传入 `-IsccPath 'D:/tools/Inno Setup 6/ISCC.exe'`；也支持 `-BundleDirectory` 和 `-OutputDirectory` 指定程序与产物目录。当前包未做代码签名，验证范围为 Windows x64；其他架构仍需实际验证。

音频缓存可在 **设置 → 缓存管理 → 缓存上限 → 关闭缓存** 中关闭。关闭后绕过已有音频缓存并停止自动缓存、下一首预缓存，已有缓存保留供手动清除；手动下载、图片与歌词缓存不受影响。

## GitHub Actions 手动构建

将含工作流的提交推送到 GitHub 默认分支后，打开仓库的 **Actions**，选 **Build Linux**、**Build Windows** 或 **Build Android**，点击 **Run workflow** 并选择要构建的分支。手动构建完成后，从该次运行页面的 **Artifacts** 下载产物；不会自动创建 GitHub Release。GitHub 要求手动触发的工作流文件先存在于默认分支。

- **Build Linux**：在 Ubuntu 22.04 上生成完整 bundle 的 ZIP 和 DEB，分别上传为 `echoes-linux-bundle-*` 和 `echoes-linux-deb-*` 两个 Artifact，可单独下载，保留 14 天。GitHub Actions 下载 Artifact 时仍会额外套一层 ZIP。
- **Build Windows**：推送 `main` 或手动运行时生成 EXE 安装包、便携 ZIP 和 SHA-256 校验文件，分别上传为 `echoes-windows-installer-*`、`echoes-windows-portable-*`、`echoes-windows-checksums-*`，保留 14 天。与本地共用 `scripts/package_windows.ps1`，自动读取 `pubspec.yaml` 版本。Artifact 下载会额外套一层 ZIP，其中安装包需要解压后运行。
- **Build Android**：默认只构建 ARM64、使用发布证书签名；也可在运行前选择全部 ABI。推送 `v2.0.0` 之类与 `pubspec.yaml` 的版本名一致的标签时，仍会自动构建全部 ABI 并发布 GitHub Release。
- **构建信息**：三项工作流会把 Git 提交和 Flutter 版本写入应用内的 **设置 → 关于**；本地直接构建仍会显示从安装包读取的版本、构建号、应用 ID 和平台。
- **Android 签名配置**：在仓库 **Settings → Secrets and variables → Actions** 添加 `KEYSTORE_BASE64`（发布 keystore 文件的 Base64 内容）、`KEY_ALIAS`、`KEY_PASSWORD`、`STORE_PASSWORD`。工作流会检查发布签名配置是否齐全，以及 APK 的包名与版本；不再验证 APK 签名或比较证书。密钥只在 GitHub runner 的临时目录中解码，不提交到仓库。
- **临时验证**：尚未配置发布密钥时，可以在手动触发 Android 构建时选择 `debug` 签名；标签发布始终要求发布密钥。

更多操作方式见 [GitHub 手动运行工作流文档](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow) 和 [GitHub Actions Secrets 文档](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)。

若通过 `flutter config --build-dir=<其他目录>` 改过 Flutter 构建目录，可用 `ECHO_LINUX_BUNDLE_DIR=/绝对路径/到/bundle bash scripts/package_linux_deb.sh <输出目录>` 指定 bundle 和包输出目录。

排查 Linux 窗口缩放或恢复时的闪屏时，可以先完全退出正在运行的 Echoes，再用同一份 bundle 比较默认渲染器和关闭 Impeller 的结果：

```bash
build/linux/x64/release/bundle/echoes
ECHO_DISABLE_IMPELLER=1 build/linux/x64/release/bundle/echoes
```

环境变量只对第二次启动生效，不会改写配置。测试时必须先退出第一个进程，否则 GTK 的单实例机制可能只唤醒已有窗口，无法切换渲染器。

## 清理与常见问题

- `flutter clean` 会删除 Flutter 生成内容；之后重新运行 `flutter pub get` 再构建。仅清理旧产物时可以删除 `build/`，但它会同时删除此前的 Android APK 和 Linux 包。需要同时保留两端产物时，不要在两次构建之间清理。
- Linux 打包提示缺少文件时，先确认执行了 **release** 构建，且 `ECHO_LINUX_BUNDLE_DIR` 指向完整 bundle，不要只复制 `echoes` 可执行文件。
- Android APK 无法覆盖安装时，分别核对包名、签名证书以及实际 `versionCode`；尤其注意拆分包的 ABI 版本码偏移。

参考：[Flutter Android 发布文档](https://docs.flutter.dev/deployment/android)、[Flutter Linux 构建文档](https://docs.flutter.dev/platform-integration/linux/building)。
