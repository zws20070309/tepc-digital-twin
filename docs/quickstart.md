# Quickstart（干净会话复现指南）

1. 启动 MATLAB R2025a（或 R2023b+）。
2. 命令行:

```matlab
% 在 MATLAB 里 cd 到本仓库根目录 (克隆/解压到哪就指到哪, 不要写死绝对路径)
cd('<本仓库根目录>')
tepc_quickstart
```

3. 预期输出:
   - `runs/<uuid>/` 下生成 events.h5 / spectrum.csv / summary.json /
     provenance.json / gates.json / report.html / figures/diagnostic.png
   - 控制台摘要: yF≈8, yD≈14.6 keV/µm（1000 Pa, 0.53 µm 等效位点, 1 MeV 中子）
   - 门禁: VALID(FOR DEMO)（含 2 项 WARN: 位点矛盾与参数域守卫, 属预期）

4. 测试（可选）:

```matlab
cd tests
parpool('Processes', 2)   % 低内存机器先把池起小: 默认配置会起 8 个 worker(实测 MATLAB 家族 7.4 GB); gcp() 复用同一个池, 判据与用例数不变
runAllTests      % 617 项, 本机实测 21-77 分钟（Simulink 门禁与 GUI 端到端占大头; 内存吃紧或并行池争用时会成倍变长, 历次耗时见 docs/test_evidence/）
runUiTests       % 需先 cd tests_ui; UI 用例 2 例 (真 uifigure + 真回调), 不在主套件采集面内, 计数是 docs/counts.json 的独立键
run_demo         % 需先 addpath workflows; 演示工作流入口 (固定 seed 10000 事件 → events.h5/spectrum.csv/summary.json/诊断图), 不是用例, 不进计数
```

5. GUI（可选）:

```matlab
cd ..; addpath('app'); app = TEPCApp();
% 项目页 → [载入配置] → [校验配置]（观察橙色位点矛盾警报）
% → 运行页 [▶ 运行] → 谱与剂量页查看 y d(y)
```

## 故意制造错误定位演示

```matlab
cfg = tepc.config.load('config/defaults/demo_only.json');
cfg.gas.composition_molfrac.CH4 = 0.90;      % 组分和 = 1.26
tepc.run.execute(cfg, 'N', 100);
% → 错误 tepc:run:ConfigInvalid: 配置校验失败: 组分摩尔分数和 = 1.260000 (要求 1)
```

事件文件 schema 损坏演示:

```matlab
E = tepc.io.readEventsH5('runs/<uuid>/events/events.h5');
E.ev.EdepGas_keV(5) = -3;                    % 注入负能量
tepc.io.writeEventsH5('bad.h5', E, struct());
% → 错误 tepc:events:Schema: EdepGas_keV 存在负值/NaN
```
