function fp = fieldMapFingerprint(a_m, b_m, hv_V, gridLevel, geometry)
%FIELDMAPFINGERPRINT 场图几何指纹: sha256(规范化身份元组)。
%   fp = fieldMapFingerprint(a_m, b_m, hv_V, gridLevel, geometry)
%   身份元组 = (阳极半径, 阴极半径, 高压, 网格层级, 子午面几何)。指纹在
%   solveElectrostatic 里随场图一起产出, 消费方 (tepc.detector.fieldOf) 在读取时
%   重算并比对 —— 场图与它声称的几何一旦脱钩就报错, 不静默用错场。
%   哈希实现: tepc.io.hashText = 纯 MATLAB SHA-256 (FIPS 180-4, 已对标准向量核对),
%   与 provenance 里 config/constants 文件哈希同一实现, 因此"内存文本"与"盘上字节"
%   同值, 场图落 .mat 再读回来指纹不变。
%
%   数值用 %.17g 打印: 这是 double 的完全可分辨序列化 —— 任何一位被改都会换指纹
%   (判别力落在 1 ulp 上), 而同一个 double 经 .mat / JSON 往返后打印结果不变,
%   所以不会把"重新序列化"误判成"几何被改"。
%   geometry 参与指纹: 'coax' 与 'sphereWire' 的两组 (a,b,V,lev) 完全相同的场图
%   是两道不同的边值问题, 必须可区分。
%
%   返回 64 位小写十六进制 char。

if nargin < 4 || isempty(gridLevel), gridLevel = 2; end
if nargin < 5 || isempty(geometry),  geometry  = 'coax'; end
g = strtrim(char(string(geometry)));
txt = sprintf('tepc-fieldmap-v1|a=%.17g|b=%.17g|hv=%.17g|gridLevel=%d|geometry=%s', ...
    double(a_m), double(b_m), double(hv_V), double(gridLevel), g);
fp = tepc.io.hashText(txt);
end
