# poker_trainer

A new Flutter project.

## iOS 打包 / 装到自己手机上

1. 包名与签名（已配好）：`ios/Runner.xcodeproj` 里 `PRODUCT_BUNDLE_IDENTIFIER = com.tcgroup.bewt`、
   `DEVELOPMENT_TEAM = LQG3344N2G`。版本号在 `pubspec.yaml`（`0.1.0+1`，iOS 必须有构建号，否则出包会报
   `Action Required: You must set a build name and number`）。
2. 出包（第一次会顺带跑 CocoaPods 装 iOS 依赖，需要联网）：

   ```bash
   flutter build ipa --release --export-method development   # 或者 --export-method ad-hoc
   ```

   产物：`build/ios/ipa/*.ipa`（归档在 `build/ios/archive/Runner.xcarchive`）。
3. 装到手机上，二选一：
   - 有线：Windows/macOS 上用爱思助手或 Sideloadly 直接安装这个 ipa；
   - 无线（OTA）：把 ipa 做成安装页，手机 Safari 上点一下就装——

     ```bash
     zsh tool/ota/make_ota.sh build/ios/ipa/poker_trainer.ipa https://你的静态托管地址
     ```

     生成的 `build/ota/` 整个目录传上去，手机 Safari 打开 `…/install.html` 点「安装」。
     用 GitHub Pages 托管的话有现成脚本（仓库要先在 GitHub 上建好、为空）：

     ```bash
     zsh tool/ota/publish_gh_pages.sh build/ios/ipa/poker_trainer.ipa <github用户名> <仓库名>
     # 然后仓库 Settings → Pages → Deploy from a branch → main → /(root)
     ```
4. 注意：
   - ipa 必须用「包含这台 iPhone UDID」的描述文件签名，否则下载完会提示无法安装
     （到 developer.apple.com → Devices 加设备，然后重新出包即可）；
   - development 签名的包在 iOS 16+ 要开「设置 → 隐私与安全性 → 开发者模式」并重启；
   - 同一个 bundle id 在一台设备上只能存在一个 App，换 id 前先确认没有同名应用；
   - 表现是「下载完成，但一直显示等待中/装不上」，多半是**相同 bundle id 的版本冲突**：
     手机上已有的同名 App 版本更高（比如公司正式的 BEWT 是 `2026082002`，而训练器是 build `1`），
     iOS 会拒绝降级安装。办法是二选一——先删掉手机上那个 App，或者换个包名重新出包：

     ```bash
     zsh tool/ios_set_bundle_id.sh com.tcgroup.pokertrainer LQG3344N2G
     flutter build ipa --release --export-method ad-hoc
     ```

     换包名后是全新的 App ID，需要到 developer.apple.com 给新 App ID 重新生成一份
     包含设备 UDID 的 Ad Hoc 描述文件，否则装不上。
