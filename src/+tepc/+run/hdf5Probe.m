function cap = hdf5Probe()
%HDF5PROBE 在**当前工作进程里**实测 HDF5 与 v7.3 MAT 是否可用。
%   为什么必须实测而不是内省: backgroundPool 是线程池, 线程池里 HDF5 与 v7.3
%   都不支持 (本机 R2025a 实测过), 而 `license('test',...)` 只回答授权有没有买到、
%   `class(pool)` 只回答池类型 —— 两者都不能证明"这一个 worker 写得出文件"。
%   本函数在 worker 内自己跑一遍真实读写, 返回能力位; 任何一步失败即 UNSUPPORTED。
cap = struct('hdf5', "NOT_EVALUATED", 'v73', "NOT_EVALUATED", ...
    'detail', "", 'identifier', "");
tmp = tempdir;
tag = sprintf('%08x', mod(floor(now*86400e3), 2^31));   % 不用 Java (线程池无 JVM)
h5 = fullfile(tmp, ['tepc_probe_' tag '.h5']);
m7 = fullfile(tmp, ['tepc_probe_' tag '.mat']);
try
    if exist(h5, 'file'), delete(h5); end
    % 数据集尺寸必须与写入数据的**形状**一致: 曾创建 [1 3] 再写 (1:3)' 这个 3×1 列,
    % 于是 h5write 抛 MATLAB:imagesci:h5write:fullDatasetDimsMismatch, 被下面 catch
    % 记成 UNSUPPORTED —— **能力探针自己写错, 结果是永远回答"这台机器不行"**,
    % GUI 后台 Run 因此被长期误禁 (探针给出永远为假的"实测证据", 比没有证据更危险)。
    h5create(h5, '/x', [3 1]);
    h5write(h5, '/x', (1:3)');
    h5writeatt(h5, '/', 'probe', 'tepc');
    v = h5read(h5, '/x');
    assert(isequal(v(:), (1:3)'), 'h5 回读不一致');
    cap.hdf5 = "OK";
catch e
    cap.hdf5 = "UNSUPPORTED";
    cap.identifier = char(string(e.identifier));
    cap.detail = string(e.message);
end
try
    if exist(m7, 'file'), delete(m7); end
    save(m7, 'cap', '-v7.3');
    S = load(m7);
    assert(isfield(S, 'cap'), 'v7.3 回读不一致');
    cap.v73 = "OK";
catch e
    cap.v73 = "UNSUPPORTED";
    if cap.detail == "", cap.identifier = char(string(e.identifier)); end
    cap.detail = cap.detail + " | v7.3: " + string(e.message);
end
try, if exist(h5, 'file'), delete(h5); end, catch, end
try, if exist(m7, 'file'), delete(m7); end, catch, end
end
