---
name: install-dz-plugins
description: 把项目 dsh-plugins 目录里的 DSH 宿主插件（dsh-gas-plan / dsh-robot）安装进本机 DSH Web profile：备份 package.json → 物理拷贝进 node_modules → 幂等登记 file: 依赖与 bundles → 指引重启与验证。当需要"新机器安装 DSH 插件""改了 dsh-plugins 源码后让它生效""重装/回滚某个 DSH 插件""插件加载失败排查"时使用。新机器执行前需确认项目（含 dsh-plugins）已在本机。
tags:
  - dsh
  - plugin
  - install
  - dzproject
---

# install-dz-plugins — 从项目 dsh-plugins 安装 DSH 插件

权威文档是 `dsh-plugins\安装指南.md`（含排错与回滚全表）。本技能是它的可执行化：路径探测、安装、登记全部由 `Tools\install-dz-plugin.ps1` 完成，与指南冲突时以指南为准。

## 1. 识别能装什么

DSH Web 只认**宿主插件**（目录内同时有 `package.json` + `index.js`）。`dsh-plugins` 下当前只有：

| 插件 | 说明 |
| --- | --- |
| `dsh-gas-plan` | `/plan-gas` 命令、dz-gas-split 技能、GAS 知识库约定 |
| `dsh-robot` | 机器人插件（装完有专属后续，见第 5 节） |

`dsh-sync`（脚本基础设施）、`dz-robot-local`（本地敏感记忆）、`dz-robot-plugin`（GitHub 仓库克隆）**不是插件**，脚本会拒绝安装它们。

## 2. 路径自动探测

脚本按以下顺序解析，全部可省略：

- `PluginsDir`（dsh-plugins 目录）：参数 → 从本技能目录逐级向上找名为 `dsh-plugins` 的子目录 → 报错让用户指定。
- `ProfileDir`（DSH profile）：参数 → `%LOCALAPPDATA%\DSH Web\dsh-home.path` → 缺省 `%LOCALAPPDATA%\DSH Web\dsh-home\profiles\web`。要求其下存在 `package.json`。

前置检查：`dsh-plugins` 已在本机（没有 → 让用户先拷贝整个 `dsh-plugins\` 目录到本机任意路径）；profile 的 `package.json` 存在。

## 3. 安装流程

**【问用户】** 先确认要装哪个：`dsh-gas-plan` / `dsh-robot` / 两个都装。然后逐个执行：

```powershell
pwsh -File <技能目录>\Tools\install-dz-plugin.ps1 -Name dsh-gas-plan
pwsh -File <技能目录>\Tools\install-dz-plugin.ps1 -Name dsh-robot
```

脚本单次完成（幂等，可重复跑）：

1. 备份 profile 的 `package.json` 为 `package.json.backup-<时间戳>`（仅在需要改清单时）。
2. 物理拷贝插件 → `node_modules\<name>`（先清空旧拷贝；排除 `.git`）。
3. 幂等登记：`dependencies` 加 `file:` 路径、`dsh.profile.bundles` 加插件名；`ConvertFrom-Json` 校验通过才落盘（UTF-8 无 BOM）。
4. 校验拷贝结果（`package.json`/`index.js` 必须在；`dsh-robot` 额外检查 `bootstrap/`）。

## 4. 重启生效（必需，【问用户】）

**【勿做】未经用户确认直接重启 DSH——会让 Web 离线约 1 分钟（已开会话可恢复）。** 用户确认后：

- 优先用 `dsh-plugins\dsh-sync\restart-dsh-web.ps1`（带日志与取消旗标）；
- 没有就按安装指南第 2 节的手动块：按 13085 端口找到进程 `taskkill`，再启动 `DSH Web.exe --port 13085`，从 `web.log` 取新的带 token 地址。

## 5. dsh-robot 专属后续（装完必做）

插件首次加载会自动生成 `dsh-sync\` 脚本、`robot-settings.json`、`dz-robot-local\` 骨架（缺什么补什么，永不覆盖）。人工步骤（引导用户完成，【问用户】涉及浏览器登录与权限）：

1. 设置界面 → Robot 设置，确认组织 / 维护人 / 提交关键字（`sync:`）/ slug 前缀。
2. 双击 `dsh-sync\安装-初始化.cmd`：登录 GitHub（需 keyi-chengdu 写权限）→ clone → 注册每日计划任务。
3. `localMemoryDir` 保持默认 `dsh-plugins\dz-robot-local`（**永不放进任何仓库**）；真实凭据只进 `feishu\secrets.local.yaml`（**永不提交、永不输出到对话**）。

## 6. 验证

- 设置界面出现「Robot 设置」页；会话内 `/robot` 输出统一设置与上传边界。
- 同步空跑：`powershell -File <syncDir>\sync-to-github.ps1 -Silent -ConfigPath <syncDir>\config-dz-robot-plugin.json`，应报"无需同步"。
- `dsh-gas-plan`：新开会话后技能目录出现 `dz-gas-split`，`/plan-gas` 可用。

## 7. 红线（继承自安装指南第 7 节，违反即事故）

- 【勿做】**用 junction/symlink 链接插件目录**：Node 按真实路径解析模块，junction 会让裸导入（如 `@deepseek-ai/schemastery`）从源码位置向上找不到 `node_modules` → `ERR_MODULE_NOT_FOUND`，曾导致插件静默加载失败、设置页消失。必须物理拷贝。
- 【勿做】`git add -f dz-robot-local`、把 `dz-robot-local` 复制进任何仓库。
- 【勿做】把 `robots.yaml`、`secrets.local.yaml`、飞书配置的真实内容写入入库文件或对话输出。
- 【问用户】所有浏览器登录、组织权限、重启时机。

## 8. 排错与回滚

- 启动失败 / "required plugins did not activate"：看 `web.err.log`，多半是插件 patch 与 DSH 版本不兼容 → 回滚该插件。
- 设置页字段改了不生效：重启 DSH；仍不行看 `web.err.log`。
- 回滚单个插件：删 `node_modules\<name>` → 用最近 `package.json.backup-*` 还原清单（去掉对应条目）→ 重启 DSH。
- 完整排错表见 `dsh-plugins\安装指南.md` 第 5、6 节。
