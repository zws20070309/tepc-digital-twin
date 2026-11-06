function rd = layoutRunDirs(rd)
%LAYOUDIRSDIRS 建立/补全一个 run 目录的**唯一**布局函数。
%   布局刻意分成三区 (发布集要走事务提交, 状态区与工作区不能一起搬):
%     <run>/logs/                     状态区, t=0 就存在于 run 根
%                                     (STATUS.json / PROGRESS.json / error.json)
%     <run>/raw/                      工作区: chunk_*.mat + checkpoint.json。
%                                     必须留在 run 根: 续跑靠它, 而且既有承诺是
%                                     "取消后已完成 chunk 保留在 raw/" —— 把它
%                                     事务化会让 Resume 找不到 checkpoint。
%     <run>/_work/{input,events,results,figures,partial}   待发布的发布集
%     <run>/{input,events,results,figures,partial}         提交后才存在
%   为什么发布集不在 t=0 建: movefile(a,b) 当 b 已存在时是**移入**而不是改名,
%   预建目标目录会让提交造出 results/results 这样的嵌套。
%   rd 字段: 发布集字段 (input/events/results/figures/partial) 一律指向**提交后**
%   的位置; 运行期写文件请用 rd.work.<name> (见 publishDirs/activePath 辅助)。
if ~isfolder(rd.root), mkdir(rd.root); end
names = {'logs','raw'};
for i = 1:numel(names)
    p = fullfile(rd.root, names{i});
    if ~isfolder(p), mkdir(p); end
    rd.(names{i}) = p;
end
pub = {'input','events','results','figures','partial'};
work = struct();
for i = 1:numel(pub)
    w = fullfile(rd.root, '_work', pub{i});
    if ~isfolder(w), mkdir(w); end
    work.(pub{i}) = w;
    rd.(pub{i}) = fullfile(rd.root, pub{i});    % 提交后的最终位置
end
rd.work = work;
rd.workRoot = fullfile(rd.root, '_work');
rd.publish = pub;
rd.committed = false;
end
