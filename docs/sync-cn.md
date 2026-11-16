# 同步 CN 上游与发布

`joylae/tinycast` 从 `conversun/tinycast-cn` 合并已发布版本，后者负责跟进原始项目
`abue-ammar/tinycast`。本仓库自行签名、打包和发布，不更新任何 Homebrew 仓库。

## 正常路径

[`sync-upstream-release.yml`](../.github/workflows/sync-upstream-release.yml) 每 6 小时检查一次：
UTC 00:23、06:23、12:23、18:23（北京时间 08:23、14:23、20:23、次日 02:23）。
GitHub 调度可能延迟，也可手动派发：

```sh
gh workflow run sync-upstream-release.yml --repo joylae/tinycast
# 指定 CN tag 时加：-f upstream_tag=v0.12.15-cn.1
```

默认请求 CN 上游的 `/releases/latest`，只选择正式版；指定 tag 可选择 beta。
版本必须是 `vMAJOR.MINOR.PATCH[-beta.N]-cn.N`，发布时沿用完整版本，
例如 `v0.12.15-cn.1`，不会再拼接一次 `-cn.1`。

本仓库同名 Release 已存在时跳过。否则检出 `main`，从 CN 上游拉取 tag 到 `FETCH_HEAD`，
合并、运行 `run-tests.sh`，通过后推送 `main`，将确切提交 SHA 交给
[`release-cn.yml`](../.github/workflows/release-cn.yml)。拉取上游 tag 不写入本地同名 tag，
因为本仓库的发布 tag 指向含自身改动的合并提交，与 CN 上游 tag 的提交不同。

发布流程再次运行测试与完整中文检查，构建自签名 Universal 应用，验证主程序和所有 helper
的签名与架构，打包 DMG 和应用内更新 ZIP，再创建当前仓库的 Release。
应用内更新仅检查 `joylae/tinycast`；正式与 beta 通道继续隔离。
更新检查缓存记录来源仓库，切换时忽略旧源或没有来源标记的缓存，重新检查当前仓库。

## 启用条件

- 将工作流和更新来源改动提交并推送到默认分支 `main`。
- 在 GitHub Actions 中启用 fork 的工作流及定时执行，允许工作流写入仓库内容。
- 开启仓库 Issues，供合并或测试受阻时报告；分支规则须允许工作流向 `main` 推送。
- 在当前仓库的 Actions repository secrets 配置 `SIGNING_P12_BASE64` 与
  `SIGNING_P12_PASSWORD`：前者是含私钥的 `Tinycast Self-Signed` 证书 P12 的 Base64，
  后者是其导出密码。不能使用原项目的 secrets；fork 不继承这些值。
- 所有后续发布保持使用同一证书。更换证书或从 CN 上游版本切换时，手动安装一次本仓库 DMG。

签名身份的本地创建方法见 [signing.md](signing.md#1-create-the-tinycast-self-signed-identity-once)。
这里不需要 Developer ID、公证、更新 Ed25519 私钥或 Homebrew 部署密钥。

## 受阻路径

合并冲突时撤销合并；测试失败时也不推送 `main`。工作流创建标题为
`Sync vX.Y.Z-cn.N needs a hand` 的 Issue，附冲突文件或测试日志，能创建标签时标记
`sync-blocked`。同 tag 已有未关闭 Issue 时不重复创建。受阻已成功报告时工作流保持绿色，
发布 job 跳过；需查看 job 和 Issue，不能只看总状态。Issues 关闭或报告失败会使任务失败。

本地解决方式：

```sh
git switch -c sync/v0.12.15-cn.1 main
git fetch --no-tags https://github.com/conversun/tinycast-cn.git refs/tags/v0.12.15-cn.1
git merge FETCH_HEAD
```

解决冲突、完成测试与构建后将合并结果放入 `main`，关闭 Issue，再派发同步或等待定时任务。
已合并的 tag 不再产生代码变化，测试通过后仍会补发缺失的 Release。
如果合并已经推送，但发布阶段失败，修复后重新派发也可继续发布。

## 手动发布

```sh
gh workflow run release-cn.yml --repo joylae/tinycast \
  -f version=0.12.15-cn.1 -f prerelease=false \
  -f upstream_tag=v0.12.15-cn.1 -f ref=<verified-commit-sha> \
  -f release_notes='<本次中文更新说明>'
```

同步沿用 CN 上游版本。手动补丁可递增 `cn.N`，但不要提前占用 CN 上游未来的版本号，
否则同名 Release 的去重会跳过该上游版本；通常等待下一个 CN Release 再发布。
本仓库不创建或更新 Homebrew cask；首次安装使用本仓库 DMG，后续走应用内更新。

## 上游 rebase 过历史时（merge 炸假冲突）

**症状**：`git merge vX.Y.Z` 出现几十上百个 add/add 与 content 冲突，同步派发失败。
**原因**：上游发布后重写了 main，同一批 PR 换了 SHA，merge-base 退回到很旧的提交，
两侧把相同内容各自「重放」了一遍。v0.9.4 → v0.9.5 实测过一次。

配方（本地手动执行）：

1. **确认内容等价**：`git diff <fork 已合并的上游头> <rebase 后的等价提交>` 应为空。
   不为空说明 rebase 还夹带了改动，残差也要一并应用。
2. **找真实增量**：`git log --oneline <等价提交>..vX.Y.Z`，通常只有几个新提交。
3. 在临时分支上**逐个 cherry-pick**。剩下的冲突才是汉化与上游的真实交叠，逐个解决；
   上游把某文件重构走了的（如 CommandCatalog → CommandID），先取上游形状，
   汉化在后续提交里重新套上。
4. **合成合并提交，恢复祖先关系**——这是让下次自动同步恢复干净的关键：

   ```sh
   M=$(git commit-tree "$(git rev-parse 'HEAD^{tree}')" \
       -p <旧 main> -p vX.Y.Z -m 'Merge upstream vX.Y.Z: …')
   git switch main && git merge --ff-only "$M"
   ```

   第二父是上游 tag，之后 merge-base 就是它。
5. **校验工程文件**：`xcodegen generate` 后 `Tinycast.xcodeproj` 应无 diff，
   证明 pbxproj 的自动合并没有伤到工程。
6. **校验增量纯净**：`git diff vX.Y.Z HEAD --stat` 只应剩 fork 自有改动
   （汉化、拼音搜索、CN workflow、README）。

## 找出漏译：先用编译器，再补它的盲区

不要靠 grep 猜。Xcode 自己的抽取是权威清单：

```sh
xcodebuild -exportLocalizations -project Tinycast.xcodeproj \
  -localizationPath /tmp/loc -exportLanguage zh-Hans SWIFT_EMIT_LOC_STRINGS=YES
```

`SWIFT_EMIT_LOC_STRINGS=YES` 是关键 —— 不加只抽 SwiftUI 字面量，`String(localized:)` 一条不出
（v0.10.2 那次是 785 条 vs 242 条）。把 `/tmp/loc/zh-Hans.xcloc/Localized Contents/zh-Hans.xliff`
里的 `<source>` 与 `Localizable.strings` 的 key 求差集，就是待译清单。改完再跑一次直到差集为空。

**它抽不到的两类**，得另外找：

- **`.localizedUI` 接的变量** —— 字符串来自 model 层的 `title`/`label`/`detail`/`message` 字面量，
  编译期看不见。扫「合并动过的 .swift 里的字面量，减去抽取集，减去已有词条」，再逐条判断是否用户可见。
- **`Info.plist` 的用途说明** —— 走 `InfoPlist.strings`，按 `NSCameraUsageDescription` 这类
  **键名**索引，不是按英文原文。

## 渲染路径：词条在表里 ≠ 界面会变中文

v0.10.2 那次，292 条用户可见字符串里有 200 条只加词条不生效。判定标准是**这个字面量最终落进
`LocalizedStringKey` 还是 `String`** —— 后者绑定的是不查表的重载：

| 写法 | 结果 | 修法 |
| --- | --- | --- |
| `Text("字面量")` | 查表 | 只加词条 |
| `Text(cond ? "A" : "B")` | **不查表**，三元是 String | 两个分支各套 `String(localized:)` |
| `Text("A" + "B")` | **不查表** | 对**合并后的整句**套一次；分别套会重复出文 |
| `Text(param)`（`param: String`） | **不查表** | 渲染处 `Text(param.localizedUI)` |
| `"前缀 \(x)"` 直接当 String 用 | **不查表** | `String(localized: "前缀 \(x)")` |

两个反复踩到的坑：

- **插值会改 key**。`String(localized: "\(n) models")` 查的是 `"%lld models"`，不是源码文本；
  String 插值变 `%@`。照源码字面量落词条，等于落了一条永远不触发的死条目。
- **拼接要在合并处包一次**。分别包两半时，译者通常把整句写进了其中一半，界面会把开头念两遍；
  合并后原来的两个片段词条即成死条目，应一并删除。

## 汉化 checklist（同步带来新界面时）

- 新 key 追加到 `Tinycast/zh-Hans.lproj/Localizable.strings` 末尾，新起一节
  `/* Upstream vA → vB: … */`，与既有小节保持一致。
- `Text("字面量")`、`Button("…")`、`TextField("…")` 走 `LocalizedStringKey`，
  **只需加词条，不改源码**。
- 以下走 String 重载、**不查表**，需要 `String(localized:)` 或 `.localizedUI`：
  - `Text(cond ? "A" : "B")` —— 三元表达式是 String；
  - `.help(变量)`、`.accessibilityLabel(变量)`，以及接收 String 参数的自定义视图。
  - `Label("A" + "B")` —— 两段字面量相加就不再是字面量，上游为了排版换行常这么写。
- **词条在表里不等于界面会显示**：上游改一个词（`will be shown` → `are shown`）就让译文静默失效。
  同步后按渲染路径核对，不要只看 `Localizable.strings` 有没有这一条。
- 插值 key 会变成格式串：Int → `%lld`，String → `%@`。
  如 `String(localized: "\(n) characters")` 的词条 key 是 `"%lld characters"`。
- **测试不受影响**：harness 二进制没有 zh bundle，`String(localized:)` 回退英文，
  所以 Model/Service 里包裹是安全的（`notes-test` 断言 `Untitled.md` 依旧通过）。
- 红线：存储路径与目录名（如 Application Support 下的 `Notes` 目录）**绝不本地化**；
  会落成文件名的默认值（`Untitled` → `未命名`）是有意决策，不是遗漏。
- 收尾校验：`plutil -lint` 词条文件；逐 key 与源码字面量交叉核对；
  在构建产物 `Resources/zh-Hans.lproj` 里确认词条真的进了包。

### 汉化会改动搜索的三处

汉化把条目名换成了中文，搜索索引跟着变，这三处是补偿：

- `CommandID.untranslatedName` 保留英文原名，`CommandCatalog` 把它放进 `alternateNames`，
  这样 `clipboard` 仍能搜到「剪贴板历史」；中文与拼音由 name 和 `Pinyin` 覆盖。
- `AppIndex.byCategoryName` 把每个分类词按原文和译文各存一次，`应用` 与 `applications` 都能整段列出。
- emoji 的中文名与关键词来自 CLDR `zh`，由 `Scripts/gen-emoji.js` 一起生成；中文名是记录的第六段，
  `EmojiIndex` 按 name 计分而不是按关键词计分。

## v0.11.3 同步核验

上游再次重写了历史：旧 `v0.10.23` 与新历史中的 `740cbd86` 仅有 `docs/ui.md` 一处差异。
本次以旧发布树为基线做三方合并，保留完整的 `v0.11.3` 树增量；最终合并提交的两个父节点
分别是原 CN main 和真正的 `v0.11.3`，后续同步仍可使用正常祖先关系。

设置编辑器从 Sheet 拆成 Panel 时，必须同步迁移动态标题、说明、占位符和错误的查表入口。
备份分类与 Esc 行为还需核对模型字符串：既要有词条，也要在显示处调用 `.localizedUI`。
本次为用户反馈的备份、Esc 与扩展兼容性文案加入了 `localization-test` 回归检查；继续用
Xcode 抽取核对字面量，并单独核对目录、模型及拼接文案，不能只依赖该测试。

## 防漏检查：区分词条覆盖与渲染覆盖

```sh
./Scripts/check-localization.sh           # 秒级检查，lint.sh 也会运行
./Scripts/check-localization.sh --extract # Xcode 抽取 + 词条差集，首次需要编译
```

检查器自身也运行隔离副本中的反向测试：删除普通及 switch 表达式词条、制造重复键与格式
参数错误、恢复窗口布局的原始漏译，均须被拦截。

快速检查会拒绝重复或空词条、格式参数不一致、已登记目录中的缺失词条，以及可识别的
`Text(计算属性)` 直接接收已有译文的英文分支。新增动态标题目录时，必须更新
`Scripts/check-localization.js` 的目录清单；这不是全 Swift 数据流分析器。

CN 发布工作流在签名和打包前执行完整抽取检查；失败不发布。它只能证明被抽取的词条与
已登记的动态目录完整，不能证明所有运行时路径都查表。发布前还要以简体中文运行 Dev 版，
实际打开受影响页面和编辑器，检查空状态、菜单、提示与错误状态。先完成检查，再派发发布。
第三方扩展及用户命名内容保持原文，不能靠“界面不含英文”判断完整性。
