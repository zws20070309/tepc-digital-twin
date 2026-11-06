function [Qfun, meta] = qualityFactor(qcfg, projectRoot)
%QUALITYFACTOR 版本化 Q(y) 配置 (不硬编码, 未配置时输出 NA)。
%   qcfg.version:
%     "none"             -> Q = NaN (Qbar=NA)
%     "icrp60_let_on_y"  -> ICRP 60 的 Q(L) 分段式代入 y (近似, 带标志)
%     "table"            -> 读 qcfg.file 的版本化 CSV (跳过 # 注释行)
%   meta 记录: 版本、来源、近似标志、表域。

if nargin < 2
    projectRoot = fileparts(fileparts(fileparts(mfilename('fullpath'))));
    % src/+tepc/+analysis -> 项目根 = 上三级
end
meta = struct('version',"none",'approx',"",'source',"",'domain',[]);
switch lower(string(qcfg.version))
    case "none"
        Qfun = @(y) nan(size(y));
        meta.version = "none";
        meta.source = "未配置 Q(y): Qbar 输出为 NA";
    case "icrp60_let_on_y"
        Qfun = @(y) icrp60Q(y);
        meta.version = "icrp60_let_on_y";
        meta.approx = "QF_APPROX_Y_AS_LET";
        meta.source = "ICRP Publication 60 (1991) Q(L) 分段: 1 | 0.32L-2.2 | 300/sqrt(L)";
        meta.domain = [0 1e6];
    case "table"
        f = fullfile(projectRoot, qcfg.file);
        if ~isfile(f)
            error("tepc:qf:MissingFile","Q(y) 表不存在: %s", f);
        end
        raw = fileread(f);
        lines = regexp(raw, '\r?\n', 'split');
        M = [];
        for ii = 1:numel(lines)
            ln = strtrim(lines{ii});
            if isempty(ln) || ln(1) == '#', continue; end
            v = sscanf(ln, '%f,%f');
            if numel(v) == 2
                M = [M; v.']; %#ok<AGROW>
            end
        end
        if size(M,1) < 2
            error("tepc:qf:BadTable","Q(y) 表有效数值行不足: %s", f);
        end
        M = sortrows(M, 1);
        meta.version = string(qcfg.version);
        meta.approx = "QF_FROM_TABLE";
        meta.source = sprintf("表文件 %s (%d 点)", qcfg.file, size(M,1));
        meta.domain = [M(1,1) M(end,1)];
        Qfun = @(y) interp1(M(:,1), M(:,2), y, 'linear', NaN);
    otherwise
        error("tepc:qf:UnknownVersion","未知 Q(y) 版本 %s", char(string(qcfg.version)));
end
end

function Q = icrp60Q(y)
%ICRP60Q ICRP 60 (1991) Q(L): L<10: 1; 10<=L<=100: 0.32L-2.2; L>100: 300/sqrt(L)。
Q = ones(size(y));
mid = y >= 10 & y <= 100;
Q(mid) = 0.32*y(mid) - 2.2;
hi = y > 100;
Q(hi) = 300 ./ sqrt(y(hi));
Q(y < 0) = NaN;
end
