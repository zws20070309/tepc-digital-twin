function P = sampleInVolume(geom, N, rs)
%SAMPLEINVOLUME 球内体均匀点 (3xN)。圆柱/平板演示不支持。
%   从 AnalyticAdapter 的局部函数**原样搬来** (公式与抽样次数一字未改), 因为
%   tepc.transport.birthPoint 也要用它: 反冲核诞生点有"体均匀"与"落在弦上"两条路径,
%   两条都要能抽, 而复制一份球抽样器会变成两个真相源。搬动本身不改任何随机数消耗顺序。
switch string(geom.type)
    case "sphere"
        r = (geom.R_m*(rand(rs,N,1).^(1/3))).';
        th = acos(2*rand(rs,N,1)-1).'; ph = (2*pi*rand(rs,N,1)).';
        P = [r.*sin(th).*cos(ph); r.*sin(th).*sin(ph); r.*cos(th)];
    otherwise
        error("tepc:transport:Geom","体均匀点抽样仅实现 sphere(演示)");
end
end
