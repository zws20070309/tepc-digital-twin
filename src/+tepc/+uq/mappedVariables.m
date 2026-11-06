function names = mappedVariables()
%MAPPEDVARIABLES 已实现映射的 UQ 变量名 —— 唯一清单。
%   tepc.uq.propagateMC 的抽样前白名单校验与逐样本 paramMap 共用本函数, 因此
%   "配置里能写哪些扰动变量"只有一处定义。
%
%   返回 1×n string 行向量, 顺序即 paramMap 的填装顺序 (与变量名解析无关, 只影响
%   out.inputs 的列序)。
%
%   加一个名字必须同时做三件事, 否则它就是一个假分量:
%     1) 在 propagateMC 的 oneSample 里把它真的施加到链路上;
%     2) 在 docs/uncertainty_budget.md 里登记它的来源与响应量级;
%     3) 给出它对发布量确有响应的证据 (test_uq_measurement 的 Spearman 判据)。
%   第 2 条由 tests/unit/test_uq_budget_inertness.m 核对: 表里没登记的名字判红,
%   表里登记了却不在这里的名字同样判红。

names = ["W_rel", "fano", "gainScale", "stopScale", "pressure_rel", ...
    "adcCal_rel", "threshold_rel", "noise_rel", "deadTime_rel"];
end
