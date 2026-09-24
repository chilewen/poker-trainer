# poker_trainer

A new Flutter project.

## iOS 打包 / 装到自己手机上

1. 包名与签名（已配好）：`ios/Runner.xcodeproj` 里 `PRODUCT_BUNDLE_IDENTIFIER = com.tcgroup.bewt`、
   `DEVELOPMENT_TEAM = LQG3344N2G`。版本号在 `pubspec.yaml`（`0.1.0+1`，iOS 必须有构建号，否则出包会报
   `Action Required: You must set a build name and number`）。
2. 出包 + 发布，一条命令（第一次会顺带跑 CocoaPods 装 iOS 依赖，需要联网）：

   ```bash
   zsh tool/ota/release_ios.sh --bump
   ```

   它做四件事：构建号 +1 → `flutter build ipa --release --export-method ad-hoc`
   → 重新生成 `build/ota/` 里的安装页 → commit 并 push 到 `chilewen/poker-ota`。
   产物在 `build/ios/ipa/`（归档在 `build/ios/archive/Runner.xcarchive`）。

   - `--dry-run` 只打印「会做什么」，不出包也不推送；
   - `--skip-build` 复用现有的 ipa，只重推安装页；
   - 想换签名方式：`EXPORT_METHOD=development zsh tool/ota/release_ios.sh`。

   等价的手动三步（想自己控制时用）：

   ```bash
   zsh tool/ota/bump_version.sh                     # 构建号 +1，手机上才分得清新旧
   flutter build ipa --release --export-method ad-hoc
   zsh tool/ota/publish_gh_pages.sh build/ios/ipa/poker_trainer.ipa \
       chilewen poker-ota \
       https://cdn.jsdelivr.net/gh/chilewen/poker-ota@main/poker_trainer.ipa
   ```
3. 装到手机上，二选一：
   - 有线：Windows/macOS 上用爱思助手或 Sideloadly 直接安装这个 ipa；
   - 无线（OTA）：把 ipa 做成安装页，手机 Safari 上点一下就装——

     ```bash
     zsh tool/ota/make_ota.sh build/ios/ipa/poker_trainer.ipa https://你的静态托管地址
     ```

     生成的产物都带时间戳文件名：`poker_trainer-<时间戳>.ipa`、
     `manifest-<时间戳>.plist`（旧的一并删掉）。CDN（jsDelivr 这类）和 iOS 都是按
     完整地址缓存的，换个文件名就等于换了个新文件。

     **别用 `?v=时间戳` 这种写法**：`itms-services` 的地址一旦带 query，iOS 会直接
     不响应——点「安装」毫无反应，不弹窗也不报错，特别难查（踩过一次）。

     `manifest.plist` 里的 `bundle-version` 写的是 `0.1.0.3` 这种「短版本 + 构建号」：
     iOS 靠它判断有没有新版本，跟手机上已装的版本一样时，点「安装」会**完全没反应**
     （不弹窗也不报错，很容易误以为链接坏了）。改了安装页/hook 之后如果手机上已经装过
     同一版，把构建号 +1 再发一次即可（或者先从手机上删掉那个 App）。

     安装页上显示的是 `版本 0.1.0（build 3）· 发布时间`：`pubspec.yaml` 里
     `0.1.0+3` 的 `+3` 是**构建号**，进的是 `CFBundleVersion`，而苹果的短版本
    永远停在 `0.1.0`。只看短版本的话每次发布页面上都是 0.1.0，会让人以为
    没更新——所以页面把构建号和发布时间一起打出来。

     页面的版本号不会「一直不变」：`publish_gh_pages.sh`（和 `release_ios.sh`）
     会往 `build/ota/.git/hooks/pre-commit` 装一个钩子。所以就算你偷懒手动
     「把新 ipa 拷进 `build/ota` → `git add . && git commit && git push`」，
     提交前也会按目录里现有的那个 ipa 重新生成 `install.html` / `manifest.plist`，
     页面上永远是对应这个包的版本号（生成失败会直接拒绝提交，别用
     `--no-verify` 绕过）。`build/ota/.ota.conf` 是本机发布配置，已被 gitignore。

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
