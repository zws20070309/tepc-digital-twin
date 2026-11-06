function [z, w] = gaussHermiteNodes(n)
%GAUSSHERMITENODES 归一化 Gauss-Hermite 求积节点: sum_i w_i f(z_i) = E[f(Z)], Z~N(0,1)。
%   为什么要从 simulate 的局部函数提成公开函数: 位置展宽的均值条件化因子
%   完全建立在这套节点上, 而"测试自己再实现一遍同样的公式"是无法失效的断言 ——
%   它只证明测试抄写员没抄错, 不证明链上用的是同一套节点 (这类断言永远不会失败)。
%   现在 simulate 与本文件是同一实现, 测试直接对**生产代码**核对矩条件。
%
%   数学: Golub-Welsch, base MATLAB (无统计工具箱)。物理 Hermite 的 monic 三项递推
%   beta_k = k/2 => 对称三对角矩阵的非对角元 sqrt(k/2); 特征向量第一个分量给权重
%   w0_k = sqrt(pi)*V(1,k)^2 (对应权函数 e^{-x^2})。变量替换 z = sqrt(2)*x 把
%   e^{-x^2}dx 口径换成标准正态口径, 再除以 sum(w0) 使权重和为 1。
if ~(isnumeric(n) && isscalar(n) && n >= 2 && n == round(n))
    error("tepc:elec:BadGHOrder", "求积阶数必须是 >=2 的整数, 实得 %s", mat2str(n));
end
b = sqrt((1:n-1)/2);
J = diag(b, 1) + diag(b, -1);
[V, D] = eig(J);
x = diag(D).';
w0 = sqrt(pi) * V(1, :).^2;
z = sqrt(2) * x;
w = w0 / sum(w0);
end
