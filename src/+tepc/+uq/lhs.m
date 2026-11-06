function X = lhs(N, d, rs)
%LHS 拉丁超立方抽样 (自实现, 无 Statistics Toolbox 依赖)。
%   N 样本 x d 维, 每维分层 [0,1]^N 每层一个样本, 层内均匀 + 维间随机置换。

U = zeros(N, d);
for j = 1:d
    strata = ((randperm(rs, N)' - 1) + rand(rs, N, 1)) / N;
    U(:, j) = strata;
end
X = U;
end
