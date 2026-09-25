# poker_trainer

A new Flutter project.

## 跑测试

- 全量回归门禁（静态分析 + 引擎用例 + 引擎校验）：

  ```bash
  zsh tool/regression.sh
  ```

  约 7 秒（源码没动，dill 缓存直接命中）；改过 `lib/` 要重编那一遍，约 9 秒。
  用例默认走 `tool/sharded_test.sh`：先编译一次，再按用例拆 8 片并行跑。
  `flutter test` 只按**文件**并行，`test/engine_test.dart` 里那 121 条用例它拆不开，
  裸跑要 18 秒上下。

- 只想确认「有没有跑不起来 / 结构性错」：

  ```bash
  zsh tool/regression.sh --fast
  ```

  约 3 秒：只跑发牌 / 牌型评估 / 存档 / 标题这类结构性冒烟用例，要重放牌局的 AI
  用例整条跳过（输出里报成 skipped）。**AI 行为有没有被改坏它看不出来**，那种改动
  必须跑全量。

- 改完 AI 想看行为数字（弃牌率、加注率这些比例）：

  ```bash
  zsh tool/regression.sh --probes
  ```

  在门禁之外再跑 6 个诊断探针（`tool/ai_*_probe.dart`），它们只打印比例、从不
  让回归失败：加注战、多人池、听牌、翻前 3bet、再加注，以及
  `tool/ai_river_defense_probe.dart`（河牌被连开三枪时的弃牌率 vs MDF 保本线，
  另外带一张「翻牌/转牌各自筛掉多少弱牌」的沿街表）。约 26 秒（探针合计约 170 秒
  CPU，门禁把每条拆成进程/格子并行跑，10 核机器上摊成 26 秒墙钟；墙钟由最慢的
  那个探针进程决定，不是全部 CPU 相加）。

  迭代时更常用的是「**门禁照跑全量，探针只取 1/4 样本**」这一档：

  ```bash
  zsh tool/regression.sh --quick-probes
  ```

  约 14 秒（探针 20 秒 → 6 秒）。121 条用例一条不少、就是真门禁，只是上面那些
  比例带 ±5~10% 的抖动，只够看方向——要写进注释、拿去改阈值的数字，还是跑
  `--probes` 全量那遍。（`--fast` 也能把探针砍到 1/4，但那档连用例都跳过，
  门禁就废了，所以单列了这一档。）

  只想看数字、不想等门禁（分析 + 121 条用例 + 校验）那一半：

  ```bash
  zsh tool/regression.sh --probes-only
  ```

  它跳过门禁、只跑探针，所以**不是门禁**——别拿它当「没改坏」的证据。

- 改完一处 AI、只想看相关那一节的数字（比全量探针快一个数量级）：

  ```bash
  PROBE_ONLY=ai_probe AI_PROBE_SECTION=强牌的加注率 zsh tool/regression.sh --probes
  ```

  `PROBE_ONLY` 只跑名字含这个子串的探针文件；`AI_PROBE_SECTION` 让
  `tool/ai_probe.dart` 只跑标题含这个子串的段落（其余段落**连模拟都不跑**，
  不是只把打印关掉）——用例门禁照跑，整条命令从 26 秒变 11 秒；再叠上
  `--probes-only` 把门禁那 8 秒也省掉，改一处 AI 看数字是 1~4 秒。关键字没命中
  任何段落时会提示。

- 改哪条就试哪条（编辑循环里最省时间；它只证明这一条过得去，不是回归门禁）：

  ```bash
  TEST_ONLY=转牌重注 zsh tool/sharded_test.sh test/engine_test.dart
  ```

  只跑名字里含这个子串的用例。全量回归的墙钟下限是「编译 2.5 秒 + 重放 5 秒」，
  单条基本只花编译那 2.5 秒；源码没动再跑一遍是 1 秒以内。改完记得跑全量那遍。

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
