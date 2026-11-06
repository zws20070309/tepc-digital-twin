function ok = setH5RunStatus(f, status)
%SETH5RUNSTATUS 就地更新 events.h5 的根属性 run_status。
%   事务式提交里这个属性必须跟着改口: 暂存期写 PENDING_COMMIT, 提交后若仍留着
%   PENDING_COMMIT, 落盘数据就在自称"未提交", 与 logs/STATUS.json 互相矛盾
%   (审计发现: 提交之后没有任何代码更新它, 于是每个 run 的 h5 属性都是过期的)。
%   返回 false 表示更新失败 —— 调用方必须**如实记账**, 不要静默忽略。
ok = false;
try
    if ~isfile(f), return; end
    h5writeatt(f, '/', 'run_status', char(string(status)));
    % 读回核对: h5writeatt 静默不生效是本类"记账代码"最常见的失败模式。
    v = h5readatt(f, '/', 'run_status');
    ok = strcmp(char(string(v)), char(string(status)));
catch
    ok = false;
end
end
