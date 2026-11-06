function id = backendId()
%BACKENDID 后端标识: 本交付的输运与电子学链是解析代理模型 (Fast Surrogate)。
%   它不是蒙特卡罗输运, 也不是任何真实装置的对表复现; summary / gates /
%   HTML 报告 / provenance / GUI 标题带共用这一个字符串, 避免四个产物各写一份
%   而互相分叉 (称谓一旦被某处漏掉, 读者就会把代理模型当成装置模型)。
%   与 docs/constants.json 无关: 该表只登记数值常数, 字符串标识刻意不进去。
id = 'analytic_surrogate_v1';
end
