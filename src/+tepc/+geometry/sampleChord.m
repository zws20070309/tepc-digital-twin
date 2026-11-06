function [L, P_in, P_out] = sampleChord(geom, N, mode, rs, beamDir)
%SAMPLECHORD 弦长与进出点抽样。
%   mode:
%     "isotropic_external" - 各向同性均匀直线场穿过凸体:
%         方向 Omega 均匀取自球面, 撞击点在垂直于 Omega 的投影轮廓内均匀分布
%         (拒绝抽样), 弦 = 直线与体相交段。均值满足 Cauchy: <L> = 4V/S。
%     "internal_isotropic" - 体内各向同性均匀源: 点均匀于体积, 方向均匀;
%         球体精确弦长 pdf p(L) = (3/(4R^3))(R^2 - L^2/4), 均值 3R/4。
%     "parallel_beam" - 准直平行束, 方向取第 5 个实参 beamDir (缺省 [0;0;1]):
%         撞击点在垂直于 beamDir 的投影圆盘内均匀, 拒绝抽样直到命中;
%         均值弦 = V / S_投影(beamDir), 所以它随方向变 (球例外, 见下)。
%   返回 L [m, Nx1], P_in/P_out [3xN m]。
%   rs: RandStream (Threefry 子流), 可选。
%
%   方向到底在哪一维上可观测 —— 这一段是 parallel_beam 存在的全部理由 (没有它, 下面的数只是散文):
%   球: L = 2*sqrt(R^2 - b^2) 只挂在撞击参数 b 上, 与束方向**完全无关**; 把方向传进来、按方向
%       重排投影盘, 弦长集合与均值 4R/3 都不变 (分布本身没变, 均值层面连统计涨落都不会变)。
%       这就是 source.direction 对发货几何严格零影响的几何理由, 不能靠"反正这里没接线"来解释。
%   有限圆柱 (取 H=2R 那一例): 平行束均值弦 = V/S_投影, 轴向 S_投影=pi*R^2 ⇒ 均值 = H = 2R 且**零方差**
%       (每条被接受的轴向射线都从一端板走到另一端板); 横向 S_投影=2R*H ⇒ 均值 = pi*R/2。
%       两者之比 4/pi ⇒ **+27.3%**, 方向在这条腔上是可观测的。
%   还差的那一层: 发货几何是球 (config/defaults 的 geometry.type="sphere"), 而解析输运的诞生点抽样
%   sampleInVolume 目前也只实现球 ⇒ 弦这一维已经能表达方向, y_F 那一侧要等几何与诞生点先离开球腔。

if nargin < 4, rs = RandStream('Threefry'); end
if nargin < 3, mode = "isotropic_external"; end
if nargin < 5, beamDir = [0; 0; 1]; end
L = zeros(N,1); P_in = zeros(3,N); P_out = zeros(3,N);
switch string(geom.type)
    case "sphere"
        R = geom.R_m;
        switch mode
            case "isotropic_external"
                b = (R*sqrt(rand(rs,N,1))).';        % 撞击参数: 投影圆盘面积均匀
                half = sqrt(max(R^2-b.^2,0));
                [Omega, e1, e2] = isotropicDir(rs, N);
                ang = (2*pi*rand(rs,N,1)).';
                mid = e1.*repmat(b.*cos(ang),3,1) + e2.*repmat(b.*sin(ang),3,1);
                P_in  = mid - Omega.*repmat(half,3,1);
                P_out = mid + Omega.*repmat(half,3,1);
                L = 2*half;
            case "internal_isotropic"
                r = (R*(rand(rs,N,1).^(1/3))).';     % R*u^(1/3): 体积均匀
                th = acos(2*rand(rs,N,1)-1).'; ph = (2*pi*rand(rs,N,1)).';
                P0 = [r.*sin(th).*cos(ph); r.*sin(th).*sin(ph); r.*cos(th)];
                [Omega,~,~] = isotropicDir(rs, N);
                dotx = sum(P0.*Omega,1);
                half = sqrt(max(dotx.^2 + R^2 - sum(P0.^2,1), 0));
                % 沿 +Omega 的前向 exit 根是 half - dotx; half + dotx 是**反向**那一侧的距离。
                % 之前这里取 half + dotx 却又按 +Omega 放 P_out, 于是 dotx>0 的那一半样本
                % P_out 落在球外 (|P_out| > R): L 的分布没错 (±Omega 等概率, 两者同分布),
                % 但"方向-出射点"配对是错的。取前向根后 |P_out| = R 才成立。
                L = half - dotx;                     % 沿 Omega 到边界距离
                P_in = P0;
                P_out = P0 + Omega.*repmat(L,3,1);
            case "parallel_beam"
                % 准直束。球的解析路径 (不走求交): b 是这条分支的**第一次** rand 抽样, 与
                % isotropic_external 的第一次抽样同序同形状, 所以同 seed 下换 beamDir 之后
                % L 必须逐位不变 —— 这把"方向对球腔不可观测"从散文变成可锁的等式。
                [d, u1, u2] = beamBasis(beamDir);
                b = (R*sqrt(rand(rs,N,1))).';
                half = sqrt(max(R^2-b.^2,0));
                ang = (2*pi*rand(rs,N,1)).';
                mid = u1*(b.*cos(ang)) + u2*(b.*sin(ang));
                P_in  = mid - d*half;
                P_out = mid + d*half;
                L = 2*half;
            otherwise
                error("tepc:geometry:BadMode","未知弦抽样模式 %s", mode);
        end
    case {"cylinder_endless","cylinder_finite"}
        R = geom.R_m;
        if string(geom.type)=="cylinder_finite"
            H = 2*sqrt(geom.bboxR_m^2 - R^2);
        else
            H = Inf;
        end
        Rb = sqrt(R^2 + (H/2)^2);            % 投影轮廓外接盘半径(有限圆柱)
        switch mode
            case "isotropic_external"
                got = false(N,1);
                while ~all(got)
                    m = ~got; nm = nnz(m);
                    [Omega,e1,e2] = isotropicDir(rs, nm);
                    bb = (Rb*sqrt(rand(rs,nm,1))).';   % 外接盘面积均匀 (1xnm)
                    ang = (2*pi*rand(rs,nm,1)).';
                    b1 = bb.*cos(ang); b2 = bb.*sin(ang);
                    P0 = e1.*repmat(b1,3,1) + e2.*repmat(b2,3,1);
                    [t1,t2,hit] = intersectLine(geom, P0, Omega);
                    acc = find(hit); acc = acc(:);   % find 空结果为 0x0, 规范化为 0x1
                    okm = find(m); ok = okm(acc); if isempty(ok), continue; end  % 本轮全部拒绝
                    L(ok) = (t2(acc)-t1(acc)).';
                    P_in(:,ok)  = P0(:,acc) + Omega(:,acc).*repmat(t1(acc),3,1);
                    P_out(:,ok) = P0(:,acc) + Omega(:,acc).*repmat(t2(acc),3,1);
                    got(ok) = true;
                end
            case "parallel_beam"
                % 有限圆柱的准直束: 轴向与横向的均值弦不同 (V/S_投影), 这条分支就是
                % "方向可观测"的最小实现。投影轮廓的外接圆盘取 bboxR (轴向时轮廓是半径 R 的
                % 端盘, 命中率 R^2/bboxR^2; 横向时轮廓是 2R x H 的矩形, 内接于同一圆盘)。
                if string(geom.type) ~= "cylinder_finite"
                    % 无限圆柱没有"端板"可截: 横向束的投影轮廓是无界带, 外接圆盘不存在。
                    error("tepc:geometry:BeamUnsupported", ...
                        "parallel_beam 需要有限体, %s 的横向投影无界", geom.type);
                end
                [d, u1, u2] = beamBasis(beamDir);
                [L, P_in, P_out] = beamRejection(geom, N, rs, d, u1, u2, geom.bboxR_m);
            otherwise
                error("tepc:geometry:BadMode","圆柱支持 isotropic_external 与 parallel_beam");
        end
    otherwise
        error("tepc:geometry:UnknownType","未知几何类型 %s", geom.type);
end
L = L(:);
end

function [Omega, e1, e2] = isotropicDir(rs, N)
mu = 2*rand(rs,N,1)-1; phi = 2*pi*rand(rs,N,1);
s = sqrt(max(1-mu.^2,0));
Omega = [s.*cos(phi), s.*sin(phi), mu].';        % 3xN, mu=z 分量
e1 = [-sin(phi), cos(phi), zeros(N,1)].';        % 3xN, 与 Omega 垂直, 单位长
e2 = [-mu.*cos(phi), -mu.*sin(phi), s].';        % 3xN, Omega x e1, 单位长
end

function [d, u1, u2] = beamBasis(beamDir)
%BEAMBASIS 准直束方向 + 与之垂直的一对单位向量 (撞击点在 u1/u2 张成的投影面里取)。
v = double(beamDir(:));
if numel(v) ~= 3 || any(~isfinite(v)) || norm(v) == 0
    error("tepc:geometry:BadBeamDir", "beamDir 必须是非零有限的三维向量, 实得 %s", mat2str(v));
end
d = v/norm(v);
ref = [0;0;1]; if abs(dot(d,ref)) > 0.9, ref = [1;0;0]; end
u1 = cross(d,ref); u1 = u1/norm(u1);
u2 = cross(d,u1);                             % d 与 u1 都是单位且正交 -> u2 自动单位长
end

function [L, P_in, P_out] = beamRejection(geom, N, rs, d, u1, u2, Rb)
%BEAMREJECTION 在投影面的外接圆盘内面积均匀取撞击点, 拒绝未命中者 (凸体的投影轮廓内才命中)。
L = zeros(N,1); P_in = zeros(3,N); P_out = zeros(3,N);
got = false(N,1);
tries = 0;
while ~all(got)
    m = ~got; nm = nnz(m);
    bb = (Rb*sqrt(rand(rs,nm,1))).';
    ang = (2*pi*rand(rs,nm,1)).';
    P0 = u1*(bb.*cos(ang)) + u2*(bb.*sin(ang));
    D  = repmat(d,1,nm);
    [t1,t2,hit] = intersectLine(geom, P0, D);
    acc = find(hit); acc = acc(:);            % find 空结果为 0x0, 规范化成 0x1 才能索引
    if isempty(acc)
        % 外接圆盘不真的包含轮廓时, 命中率会是 0 —— 没有这个上限就是一个没有报错的挂死。
        tries = tries + 1;
        if tries > 200
            error("tepc:geometry:BeamNoHits", ...
                "连续 %d 轮在半径 %g 的投影圆盘内一个命中都取不到 (type=%s, beamDir=%s)", ...
                tries, Rb, geom.type, mat2str(d'));
        end
        continue
    end
    ok = find(m); ok = ok(acc);
    L(ok) = (t2(acc)-t1(acc)).';
    P_in(:,ok)  = P0(:,acc) + D(:,acc).*repmat(t1(acc),3,1);
    P_out(:,ok) = P0(:,acc) + D(:,acc).*repmat(t2(acc),3,1);
    got(ok) = true;
end
L = L(:);
end

function [t1, t2, hit] = intersectLine(geom, P0, D)
%INTERSECTLINE 直线 P0 + t*D 与体的交点参数(t1<t2 行向量; 无交 hit=false)。
t1 = zeros(1,size(P0,2)); t2 = t1; hit = false(size(t1));
switch string(geom.type)
    case "sphere"
        R = geom.R_m;
        a = sum(D.^2,1);
        b = 2*sum(P0.*D,1);
        c = sum(P0.^2,1) - R^2;
        disc = b.^2 - 4*a.*c;
        ok = disc > 0;
        sq = sqrt(disc(ok));
        t1(ok) = (-b(ok)-sq)./(2*a(ok)); t2(ok) = (-b(ok)+sq)./(2*a(ok));
        hit = ok;
    case {"cylinder_endless","cylinder_finite"}
        R = geom.R_m;
        if string(geom.type)=="cylinder_finite"
            H = 2*sqrt(geom.bboxR_m^2 - R^2);
        else
            H = Inf;
        end
        dx = D(1,:); dy = D(2,:); px = P0(1,:); py = P0(2,:);
        a = dx.^2 + dy.^2; b = 2*(px.*dx + py.*dy); c = px.^2 + py.^2 - R^2;
        tside1 = NaN(size(a)); tside2 = NaN(size(a)); sideHit = false(size(a));
        nz = a > 1e-300;                          % 非轴向平行
        disc = b(nz).^2 - 4*a(nz).*c(nz);
        oks = disc > 0; sq = sqrt(disc(oks));
        idx = find(nz);
        tside1(idx(oks)) = (-b(idx(oks))-sq)./(2*a(idx(oks)));
        tside2(idx(oks)) = (-b(idx(oks))+sq)./(2*a(idx(oks)));
        sideHit(idx(oks)) = true;
        dz = D(3,:); pz = P0(3,:);
        if isinf(H)
            t1 = tside1; t2 = tside2; hit = sideHit;
        else
            % 与轴平行的射线 (a≈0) 与侧面**无实交点**, 可只要它落在半径内就确实穿体,
            % 弦由两端板截出。不给这一支, 轴向准直束会 0 命中, 把 beamRejection 的
            % 拒绝抽样循环卡死; 侧面区间取 (-Inf,Inf) 后下面的 ∩ 板层区间即得该弦。
            par = ~nz & (px.^2 + py.^2 < R^2);
            tside1(par) = -Inf; tside2(par) = Inf; sideHit(par) = true;
            % 侧面区间 ∩ 板层区间
            validDz = abs(dz) > 1e-300;
            zlow  = (-H/2 - pz)./dz;
            zhigh = ( H/2 - pz)./dz;
            zlo = min(zlow, zhigh); zhi = max(zlow, zhigh);
            zlo(~validDz) = -Inf; zhi(~validDz) = Inf;
            % dz=0 的射线与板层平行: 只有当它本来就落在 |z|<=H/2 里才穿得到体。
            % 少了这一条, 横向准直束 (dz 恰为 0) 会把板层外的射线也算成命中,
            % 于是"命中区域"从 2R x H 的矩形涨成整条带, 均值弦被系统性抬高
            % (各向同性方向几乎不为 0 —— 要 rand 恰好给出 0.5 才会, 单次抽样概率 2^-53;
            %  所以这条缺陷只在准直束下才成为系统偏差, 而不是在随机方向下暴露)。
            sideHit(~validDz & abs(pz) > H/2) = false;
            tA = max(tside1, zlo); tB = min(tside2, zhi);
            hit = sideHit & (tB > tA);
            t1(hit) = tA(hit); t2(hit) = tB(hit);
        end
end
end
