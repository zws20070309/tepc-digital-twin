# 需求记录（阶段 0 冻结）

## 对象与范围

- 探测器: 球形 TEPC（主 demo; 圆柱/平板几何框架已建, 物理链演示 sphere）
- 辐射场: 单能中子（默认 1 MeV）/ 单能伽马（默认 662 keV）/ 混合（classPrior）
- 能区: 10 keV–100 MeV（阻止本领表域）; 中子弹道弹性道
- 目标量: f(y), d(y), yF, yD, Q(y)→Qbar, D_gas, D_tissue, H_micro,
  y_track(诊断), n/γ 模板分离
- 计数率: demo 100 cps（死时间/堆积模型全链路）
- 绝对剂量: **不发布**（RESEARCH/DEMO; 无参考场标定）

## 环境需求

- MATLAB R2023b+（本交付 R2025a 实测）
- Simulink（对照模型）; Parallel Computing Toolbox（GUI 后台运行, 进程池）
- Statistics Toolbox **不需要**（LHS/Poisson/分位数/gamma 均自实现）
- HDF5（base 自带）; 无 Java 依赖（SHA-256 纯 MATLAB）

## 验收

| 交付物 | 状态 |
|---|---|
| events.h5 固定 schema | ✅ (23 数据集+根属性+gzip 分块) |
| spectrum.csv | ✅ (12 列: bin_low/high/center_keV_um, dy, counts_raw, sum_w, sum_w2, f_y, sigma_f, d_y, f_in, d_in) |
| summary.json | ✅ (yF/yD/Qbar/D/活时间/标志/限制声明) |
| config_resolved.json | ✅ (含派生量与位点一致性核算) |
| provenance.json | ✅ (版本/seed/哈希/参数状态表) |
| validation_report (HTML) | ✅ (首页固定字段+门禁+诊断图内嵌) |
| GUI | ✅ (9 页签, 全链路, 渲染审查+自动化测试) |
| 红线门禁 | ✅ (16 项, 失败→INVALID 水印) |
| 参考场验证 | ❌ NOT_EVALUATED (无数据; 不阻碍 RESEARCH/DEMO 交付) |
