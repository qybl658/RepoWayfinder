# RepoWayfinder

找到一个 GitHub 项目以后，接下来该装什么、填什么、怎么运行？RepoWayfinder 把检索、环境准备、项目配置、运行和失败恢复串在一起，为 Windows 用户提供中文入口。

也可以看看 [RepoWayfinder-MB](https://github.com/qybl658/RepoWayfinder-MB)：MoonBit 实现，以及面向 MoonBit 库的离线体验包与 Python 原库接入。

## 开始使用

1. 下载仓库 ZIP 并解压，或用 Git 克隆。
2. 双击 **点我启动RepoWayfinder.bat**。首次运行会检查 Python、Git 和本项目依赖，按提示完成环境准备。
3. 输入 GitHub 地址、`owner/repo` 或关键词。关键词搜索会显示候选项目供你选择。
4. 查看运行结果、使用指南和报告；需要等待环境时，准备好后使用生成的继续入口。

## 搜索与每周热门

输入用途或关键词后，已配置的 AI 会先用一次短请求整理搜索词，再查找项目；界面会显示改写结果。超时、返回格式不正确或没有配置 Key 时使用原输入，改写后没有结果也会尝试原输入。直接输入仓库地址或 GitHub 查询条件时不改写。

主菜单 **7 本周热门 Top 10** 展示 [GitHub Trending 周榜](https://github.com/trending?since=weekly)前十项，包括本周新增 Star、简介、链接和获取时间。选编号即可继续部署，直接回车返回。命令行也可运行 `python main.py --weekly-trending`。榜单保留 GitHub 原始顺序，读取失败会提示重试。

## 选择部署路线

项目明确提供多条能启动同一应用的路线时，优先采用本机环境已经就绪的路线，并检查所需运行时版本与 Docker 引擎状态。目前支持核对 Dockerfile 与 README 中的 npm/pnpm/yarn 启动指令或 Procfile 入口。

如果都需要准备环境，会说明各条路线的用途、缺少什么和准备差异，再让你选。Docker 会明确提示 Docker Desktop/WSL2、虚拟化、许可及可能重启等额外步骤。暂不选择会保存进度，可从报告继续。通过 `--plan-file` 指定的受审方案保持原路线。

## 接入已有软件

有些 GitHub 仓库不是独立程序，而是装进别的软件的内容。RepoWayfinder 会识别仓库中的 Agent Skill、浏览器扩展和 VS Code 扩展，再检测本机是否有兼容的目标软件。

- Skill：支持接入已安装的 Codex、Grok、Claude Code、Cursor、DSH、CodeBuddy 和 Qoder。写入前会检查同名目录；不同内容不会覆盖。Grok 还会通过 `grok inspect` 检查是否发现了新 Skill。热门合集可在提示中选一个，或用 `--integration-skill <名称或仓库内目录>` 指定。
- Chrome/Edge 扩展：显示项目源码目录、申请的权限和扩展管理页。浏览器要求由用户在管理页开启开发者模式并加载未打包扩展；报告会保留待完成状态，不会把源码已下载误写成已安装。缺少构建文件时会提示先构建。
- VS Code 扩展：检测 VSIX 包或扩展源码。对经过审查的 VSIX，可由用户在交互提示中选择安装，或显式使用 `--install-vsix`；安装后回查扩展 ID。只有源码、没有 VSIX 时不会擅自运行构建脚本。

使用 RepoWayfinder 制作的 DSH 便携包时，在 **设置 → DSH 便携版位置** 指定解压目录，Skill 会写入该包自己的数据目录。命令行也可加 `--dsh-bundle "D:\你的DSH目录"`。普通安装版从 PATH 或常见安装位置识别。

这些接入结果和普通项目的启动验证分开记录。Skill 写入发现目录后，仍应在目标软件的新会话里确认它可用。
Skill 若另有 `requirements.txt` 或 `package.json` 声明的运行包，报告会标为“依赖待配置”，不会仅凭目录复制宣称完全可用。

未配置 AI Key 时仍可搜索仓库并使用本地规则分析；配置后可使用模型辅助选项。双击 **点我配置或更换API Key.bat** 管理助手配置。

目标项目有自己的配置引导，按用途显示推荐项和配置状态。使用者填写自己的 Key；助手的凭据不会直接交给第三方项目。语言、部署模式和搜索历史设置集中在 **点我打开设置.bat**。

## 把已验证的项目做成可分享的包

主菜单 **6 打包已验证项目**，或使用命令：

```powershell
python main.py --export-report reports/example/deployment_result.json --bundle-profile bundle-profile.json --bundle-output dist/example.zip
```

目前支持经过审阅的 Windows x64 Python 项目。打包配置指定精确源码提交、启动入口、Python 嵌入运行时及校验值、与运行时匹配的依赖目录和许可证。导出器读取已经成功运行的报告，不会在打包阶段执行目标项目。

包内包含固定版本的项目源码、部署方案、依赖及许可、来源清单和启动入口。可选择直接使用内置环境，或先双击 **1-首次配置环境.bat**，再双击 **2-启动项目.bat**。项目配置模板和推荐说明可随包带上，接收者自行填写密钥。

发布者仍需准备该项目的打包配置，核对分发许可，并在新目录解压后完成实际任务验证。Docker 项目、需要系统服务的项目和其他语言目前不属于这个 Python 导出器的支持范围。

接口与配置字段见 [bundle_profile.py](bundle_profile.py) 和 [portable_bundle.py](portable_bundle.py)。如需替换自动方案，可用 `--plan-file` 传入绑定仓库与精确提交的本地审阅方案；仍经过正常的命令检查和执行流程。

## 使用范围

RepoWayfinder 不保证任意仓库都能自动安装运行。默认使用防护部署，依赖安装仍可能执行第三方代码；需要管理员权限、服务账号或系统重启的步骤会保留对应的人机交互。

## 许可证

RepoWayfinder 使用 [Apache-2.0](LICENSE)。第三方项目和随包依赖按各自许可证分发。
