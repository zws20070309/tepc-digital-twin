function out = separateFields(Smix, Sn, Sg)
%SEPARATEFIELDS n/gamma 模板似然分离。
%   模板: 纯中子 Sn 与纯 gamma Sg 的 f(y) (同 bin); 混合谱 Smix 按泊松似然
%   拟合系数 (alpha_n, alpha_g)。零计数 bin 用精确泊松似然 (gammaln)。
%   无模板时调用方必须降级为 HEURISTIC_SEPARATION (本函数不提供经验阈值)。

edges = Smix.edges;
if ~isequal(Sn.edges, edges) || ~isequal(Sg.edges, edges)
    error("tepc:separate:Edges","模板与混合谱 bin 边界必须一致");
end
k = Smix.counts_raw(:);
mu_n = Sn.counts_weight(:) / max(sum(Sn.counts_weight), eps) * sum(k);
mu_g = Sg.counts_weight(:) / max(sum(Sg.counts_weight), eps) * sum(k);

% 泊松似然: k ~ Poisson(a*mu_n + b*mu_g); 网格搜索 + 精修 (Nelder-Mead 需优化箱,
% 用二维网格+局部细化, 演示级且可复现)
best = struct('a', NaN, 'b', NaN, 'logL', -Inf);
for a = linspace(0, 1.5, 151)
    for b = linspace(0, 1.5, 151)
        mu = a*mu_n + b*mu_g;
        ll = sum(k .* log(max(mu, 1e-300)) - mu - gammaln(k + 1));
        if ll > best.logL
            best = struct('a', a, 'b', b, 'logL', ll);
        end
    end
end
% 局部细化
da = 1.5/150;
for it = 1:5
    cand = [];
    for a = best.a + (-1:1)*da
        for b = best.b + (-1:1)*da
            if a < 0 || b < 0, continue; end
            mu = a*mu_n + b*mu_g;
            ll = sum(k .* log(max(mu, 1e-300)) - mu - gammaln(k + 1));
            cand = [cand; a, b, ll]; %#ok<AGROW>
        end
    end
    [~, im] = max(cand(:,3));
    best = struct('a', cand(im,1), 'b', cand(im,2), 'logL', cand(im,3));
    da = da / 3;
end
% 不确定度: 似然曲面的 0.5 logL 等高线近似(按 a 方向扫描)
logL_at = @(a) max(arrayfun(@(bb) sum(k .* log(max(a*mu_n + bb*mu_g, 1e-300)) ...
    - (a*mu_n + bb*mu_g) - gammaln(k + 1)), linspace(0, 1.5, 400)));
ll0 = best.logL - 0.5;
aHi = best.a;
while aHi < 1.5 && logL_at(aHi + 0.005) > ll0, aHi = aHi + 0.005; end
out = struct('alpha_n', best.a, 'alpha_g', best.b, 'logL', best.logL, ...
    'sigma_alpha_n', abs(aHi - best.a), ...
    'nFractions', best.a/(best.a + best.b + eps), ...
    'method', 'poisson_template_likelihood (zero-bin exact via gammaln)');
end
