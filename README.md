# TEPC 数字孪生 —— 解析事件 / 电子学 / 微剂量分析基线

[English](README.en.md) · **简体中文**

> **交付标签：RESEARCH / DEMO。** 本仓库是一个**解析代理模型**：它不是蒙特卡罗输运，也不是
> 任何真实装置的对表复现。仓库内没有参考场标定数据，因此**绝对剂量被红线门禁阻断、不予发布**。
> 这个项目能声称什么，上限由 [`docs/positioning.md`](docs/positioning.md) 决定 —— 该文件由
> [`config/capability_register.json`](config/capability_register.json) 生成，不是手写的。

---

## 这是什么

一个纯 MATLAB 实现的**球形组织等效正比计数器（TEPC）数字孪生**，把「源 → 事件 → 电子学 →
微剂量」串成一条可复现、可追溯、可机检的完整链路：

```
配置 / 源项  →  几何 / 场  →  输运适配器  →  事件构造
      →  电离 / 漂移 / 雪崩  →  前放 / 成形 / ADC  →  微剂量分析
      →  不确定度与验证  →  GUI / HTML 报告
```

给定 seed，每一级都是确定性的，产物带哈希与溯源记录，可以回读重算。输运级是**解析 / 经验适配器**
—— 两体中子弹性散射运动学、Klein–Nishina 康普顿散射、带有效电荷与锚定拼接的 Bethe 阻止本领 ——
刻意不走逐碰撞的蒙特卡罗。

## 这不是什么

| 不作声称 | 原因 |
|---|---|
| 已完成蒙特卡罗输运 | 适配器用固定子流 + 闭式轨道，没有碰撞级步进，也没有中性粒子输运 |
| 复现了某台真实装置 | 尺寸、材料、气体组分取自设计参数与文献；模型从未与任何实体探测器对表 |
| 绝对剂量通过验证 | 无参考场标定数据；`runGate` 对该项恒返回 `NOT_EVALUATED`，发布标志恒为 false |
| 精确的中子 / 伽马响应 | 弹性道截面权重、伽马质量衰减与光电分支都是 ASSUMED 占位值，并在每份产物里如实标注 |

## 项目一览

| | |
|---|---|
| 语言 | MATLAB（纯 `.m`，无 MEX、无编译产物；SHA-256 为纯 MATLAB 实现，不依赖 Java） |
| 版本 | 在 **R2025a** 上开发并实测；仓库内的代码未在更早版本上跑过，**R2023b+ 只是原项目的目标声明，未经本轮验证** |
| 必需工具箱 | Simulink（电子学对照模型）、Parallel Computing Toolbox（GUI 后台运行 / 进程池）、PDE Toolbox（可选，FEM 场图） |
| 不需要 | Statistics Toolbox —— LHS、泊松、分位数、bootstrap、`norminv` 全部仓库内自实现 |
| 入口 | `tepc_quickstart`、`tepc_gui`、`tepc_3d_workbench` |
| 验证 | 见[验证](#验证)一节：`runAllTests` 是构建门禁，任一用例失败即非零退出 |
| 许可 | 见 [`LICENSE`](LICENSE)；第三方数据条款见[数据来源](#数据来源与第三方数据) |

## 为什么做这个

微剂量学链路的常规验证方式是对着一台实体探测器做端到端对表，这让人很难在没有硬件的条件下扩展它。
本项目选择相反的赌注：把每一级都做成**可核对的闭包** —— 能量账本、权重账本、seed 一致性、
schema 契约、哈希溯源 —— 于是链上任何一处改动，要么逐位复现，要么在某个具名门禁上大声失败。
目的不是预测某台探测器，而是拥有一个研究载体：**离开进程的每一个数，都能追回到产生它的代码、
配置与随机流。**

## 管线

```
┌──────────────────────────────────────────────────────────────────────────┐
├─ 1 配置与源项 ───────────────────────────────────────────────────────────┤
│ config v1 JSON（schema 校验）→ 源类型 / 能量 / 注量 / 方向 / 计数率      │
│                                    ▼                                     │
├─ 2 几何与场 ─────────────────────────────────────────────────────────────┤
│ 球·柱·平板弦长 Cauchy 4V/S · 圆柱或球壳场（解析闭式 或 FEM 图）          │
│                                    ▼                                     │
├─ 3 输运适配器 ───────────────────────────────────────────────────────────┤
│ 两体弹性运动学 · Klein–Nishina · Bethe + 有效电荷 + 锚定拼接             │
│                                    ▼                                     │
├─ 4 事件构造 ─────────────────────────────────────────────────────────────┤
│ 事件批 SoA（23 个数据集）· 逐事件沉积能 / 弦长 / 道标签                  │
│                                    ▼                                     │
├─ 5 探测器 ───────────────────────────────────────────────────────────────┤
│ 电离对涨落 → 漂移 → 雪崩 (Diethorn + Polya) → Shockley–Ramo 感应电流     │
│                                    ▼                                     │
├─ 6 电子学 ───────────────────────────────────────────────────────────────┤
│ 电荷灵敏前放 → PZ / CR-RC 成形 → ADC（双量程 + INL）→ 触发与死时间       │
│                                    ▼                                     │
├─ 7 微剂量分析 ───────────────────────────────────────────────────────────┤
│ 带权 f(y) / d(y) → yF、yD → Q(y) → 三条剂量链 → 仪器反演                 │
│                                    ▼                                     │
├─ 8 验证与交付 ───────────────────────────────────────────────────────────┤
│ 红线门禁 16 项 → 发布标志 → summary / gates / report.html / GUI          │
└──────────────────────────────────────────────────────────────────────────┘
```

## 快速开始

克隆仓库后，在 MATLAB 里**把当前文件夹切到仓库根目录**，然后：

```matlab
tepc_quickstart      % 建路径 → 跑 10000 事件 demo（固定 seed）→ 打印摘要
```

这一次调用就会在 `runs/<时间戳>-<id>/` 下产出完整证据集：

```
runs/<run>/
├── events/events.h5               % 固定 schema 的事件批 + 根属性
├── input/config_resolved.json     % 派生后的生效配置
├── input/config_identity.json     % 配置身份哈希
├── results/spectrum.csv           % 12 列带权微剂量谱
├── results/summary.json           % yF / yD / Qbar / 剂量链 / 标志 / 限制声明
├── results/gates.json             % 16 项门禁，每项带可复算的 value
├── results/provenance.json        % 版本 / seed / 哈希 / 逐参数状态表
├── results/uq.json                % 不确定度传播结果
├── results/artifact_manifest.json % 每个产物的 sha256 清单
├── results/report.html            % 自包含的验证报告
├── logs/STATUS.json               % 运行状态机记录
└── figures/diagnostic.png
```

脚本化调用：

```matlab
project = tepc.Project.open("config/defaults/demo_only.json");
run     = project.execute('N', 1e5);
project.exportReport(run, fullfile(run.runDir.results, 'report.html'));
```

图形界面与三维审计工作台：

```matlab
tepc_gui                  % 9 页签应用：运行 / 暂停 / 取消，谱与剂量，门禁
app = tepc_gui(false);    % 无窗自检（测试套件用的就是这个入口）
tepc_3d_workbench         % 独立三维几何工作台（含显示层剖切）
```

> `tepc_gui` 与 `tepc_3d_workbench` 必须从仓库根目录启动：它们自己补 `src/` + `app/` 路径，
> 而默认配置路径是相对路径。

## 目录结构

| 目录 | 内容 |
|---|---|
| `src/+tepc/` | 全部物理与数据层，MATLAB 包形式（16 个子包） |
| `app/` | GUI：`TEPCApp`（9 页签）、`AppController` 状态机、`AppState`、`Theme`、组件 |
| `config/` | v1 配置 JSON 与 schema、能力登记表、禁语词表、参考数据 |
| `tests/` | 单元 + 集成套件，失败即非零退出 |
| `tests_ui/` | 驱动真实 `uifigure` 与真实回调的 UI 用例 |
| `tools/` | 计数生成、证据索引、定位生成、一次性探针脚本 |
| `workflows/` | `run_demo`：演示工作流入口（不是用例） |
| `docs/` | 需求、VV 计划、不确定度预算、定位、常数注册表、证据日志 |
| `geometry/` | 三维装置清单与材料表 |
| `simulink/` | `TEPC_Electronics.slx` 对照模型（数值由配置注入） |
| `runs/` | 运行产物，执行时生成（已 git 忽略） |

## 验证

测试套件是**构建门禁**而不是一份报告：任一用例失败或未决都会抛错，因此
`matlab -batch runAllTests` 的退出码可以直接用于 CI。

```matlab
cd tests; runAllTests                  % 全量，617 项
cd tests; runAllTests('Quick',true)    % 跳过长跑 GUI 全流程
cd tests; runAllTests('WriteLog',true) % 另由 MATLAB 写一份 UTF-8 用例级日志
cd tests_ui; runUiTests                % UI 用例 2 例（真实 uifigure + 真实回调）
```

套件逐层钉住的东西：

* **闭包** —— 能量账本、权重账、`f(y)`/`d(y)` 的精确矩恒等式、电荷守恒、Ramo 电子/离子份额、
  以及 events.h5 回读重算。
* **可复现性** —— 同 seed 逐 bin 相等；`1000 + 1000` 事件与 `2000` 全跑位精确相同；
  断点续跑位精确，且 seed 或配置哈希不一致时拒绝续跑。
* **分布形状** —— 弦长同时用 KS 与 Anderson–Darling 检验闭式 CDF，p 值由同分布的
  蒙特卡罗参照现场校准。
* **外部锚点** —— NIST PSTAR 液态水质子射程（共程 88 点，10 keV–100 MeV）、
  2 个阻止本领锚点，以及参考表自身的 sha256 自校验。
* **交叉核对** —— MATLAB ↔ Simulink 的 6 工作点矩阵；全树认证要求「磁盘上的用例数」
  与「套件实际收集数」逐文件相等。
* **治理** —— `README.md`、`docs/quickstart.md`、`docs/VV_plan.md` 里引用的每个计数，
  都与 `tools/genCounts.m` 的现算值比对；禁语词表扫描全部交付文本；能力状态在登记表与
  `docs/positioning.md` 之间必须互推。

计数只能**生成**，不能手抄：

```matlab
cd <repo>/tests; matlab -batch "addpath ../src; addpath ../app; addpath ../tools; genCounts"
```

GitHub Actions 的托管机器上没有 MATLAB 许可证，跑不了上面这条命令。仓库因此另外提供一条
不依赖 MATLAB 的自检：`python tools/check_repository.py` —— JSON 可解析、UTF-8 无 BOM、LF 行尾、
禁语词表、README 相对链接。它只是一个**辅助**检查，**权威门禁仍然是 `runAllTests`**；
把它接进 CI 的方法（workflow 片段）见 `CONTRIBUTING.md`。

不确定度传播覆盖 9 个不确定度源，清单在 `tepc.uq.mappedVariables`，逐项由单测核对
（表里登记了却没实现的、实现了却没登记，两个方向都判红）。

## 交付范围与限制（务必阅读）

下面这些是承重的，不是免责声明。复用本项目产出的任何数字之前请先读完。

1. **没有蒙特卡罗输运。** 输运是闭式适配器；凡需要碰撞级物理的通道，要么不存在，要么明确标 ASSUMED。
2. **剂量链内部自洽，未经外部验证。** 三条剂量链（真值 / 仪器反演 / 闭式定义）互相比对，
   没有一条对着标定场比对过。
3. **低能段阻止本领是锚定拼接。** 1 MeV 以下接到锚点，标定 ±15%（80 keV 以下 ±30%）。
4. **雪崩起点半径是常数。** 所有事件共用一个 ASSUMED 半径，因此弹道亏损是一个确定的均值，
   被电荷注入刻度吸收；**不含**真实的「径迹径向位置 → 收集时间分散 → 峰幅展宽」，
   所以发布的分辨率不是一个探测器的分辨率。
5. **发布谱是仪器反演授予能**，不是真值沉积；同事件群的真值谱一并发布，用于交叉核对。
6. **`field.mode="fem_map"` 不承诺逐位可复现。** 节点数、自由度、解数组长度逐次一致，
   但解向量的 sha256 每次调用都不同（来源是多线程归约次序，互差量级 4.44e-16）。
   跨运行的产物哈希只对解析 / 闭式量与计数负责。
7. **demo 配置存在有意的不自洽**（1000 Pa ↔ 2 µm 位点）。系统会检测并以 WARN / 橙色横幅呈现，
   物理计算使用按质量厚度映射导出的等效位点。
8. **Geant4 / FLUKA / MCNP 适配器不存在。** `TransportAdapter` 是一个扩展接口。

更多逐条原因与证据索引见 [`docs/positioning.md`](docs/positioning.md) 与
[`config/capability_register.json`](config/capability_register.json)。

## 数据来源与第三方数据

`config/reference/` 与 `config/quality-factor/` 下的参考表，全部取自公开权威源，或由已发表图件
数字化得到。每个文件在 `#` 注释头里写明来源与方法，并在
[`docs/reference_register.csv`](docs/reference_register.csv) 里登记来源、等级（A/B/C）与取数日期。
这些表**只**作为验证门禁的数值输入随仓库分发。

| 文件 | 来源 | 等级 |
|---|---|---|
| `stopping_anchors.csv` | NIST PSTAR / ESTAR | REFERENCE |
| `pstar_water_proton_range.csv` | NIST PSTAR，液态水，88 点，10 keV–100 MeV | A |
| `icrp103_neutron_wR_branches.csv` | ICRP Publication 103，附录 B，式 (2.8) | A |
| `icrp110_tissue_elemental_composition.csv` | ICRP Publication 110，Annex B，表 B.1 / B.2 | A |
| `icrp116_neutron_skin_lens_coefficients.csv` | ICRP Publication 116，表 C.12 / C.27 / F.3 | A |
| `lhasa_neutron_spectrum*.csv` | 彭超 等，《强激光与粒子束》35:059001 (2023)，doi:10.11884/HPLPB202335.220353，由图 3 矢量顶点数字化 | 数字化 |
| `icrp60_let_on_y.csv` | ICRP Publication 60，Q(L) 分段定义 | A |

再次分发本仓库时请保留这些署名。出版物本身的著作权归各自权利人所有；本仓库不再分发任何原文文档。

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/quickstart.md`](docs/quickstart.md) | 干净会话复现指南，含「故意制造错误」的定位演示 |
| [`docs/requirements.md`](docs/requirements.md) | 需求、范围与验收表 |
| [`docs/VV_plan.md`](docs/VV_plan.md) | 验证计划，容差预注册 |
| [`docs/uncertainty_budget.md`](docs/uncertainty_budget.md) | 不确定度预算 |
| [`docs/positioning.md`](docs/positioning.md) | 由登记表生成：能声称什么、不能声称什么 |
| [`docs/performance_tiers.md`](docs/performance_tiers.md) | 代价 / 保真轴，以及每条被实测否掉的记录 |
| [`docs/reference_register.csv`](docs/reference_register.csv) | 每个常数的来源与状态登记 |
| [`docs/constants.json`](docs/constants.json) | 版本化常数注册表（唯一真相源） |
| [`config/banned_claims.json`](config/banned_claims.json) | 当前口径下禁止出现的表述、理由与替代说法 |

## 如何核对你不是在读一份过时描述

本仓库的每个"当前状态"数字都能当场复算，不必信任本文：

| 你想知道的 | 怎么查 |
|---|---|
| 测试到底有多少项、门禁几项、数据集几个 | `matlab -batch "addpath tools src; genCounts('WriteFile', false)"` |
| 某个能力到底处于什么状态 | `config/capability_register.json` 的 `status` 字段，或读 `docs/positioning.md` |
| 哪些话不许说、为什么 | `config/banned_claims.json` 的 `claim_notes` |
| 一条结论出自哪次运行 | `docs/test_evidence/latest_evidence.json`（环境 + 各日志与清单的 SHA-256） |
| 某个常数的来源 | `docs/reference_register.csv` 与 `docs/constants.json` |

## 引用

学术使用请按 [`CITATION.cff`](CITATION.cff) 的元数据引用。

## 许可

见 [`LICENSE`](LICENSE)。第三方参考数据仍受其原始发布方条款约束（见上表）。

## 贡献与安全

欢迎 issue 与 pull request。基本规矩见 [`CONTRIBUTING.md`](CONTRIBUTING.md)：计数只能生成不能手改；
新增声称必须在登记表里有证据；禁语词表由测试强制执行。安全问题请**不要**开公开 issue，
按 [`SECURITY.md`](SECURITY.md) 的渠道报告。
