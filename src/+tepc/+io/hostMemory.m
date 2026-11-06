function h = hostMemory
%HOSTMEMORY 本机空闲内存与并发 MATLAB 进程数 (测量工具的环境量来源)。
%   h = hostMemory()  返回 struct:
%     free_mb / total_mb          主机物理内存 (MB)
%     matlab_processes            matlab.exe / MATLAB.exe 的镜像行数 (本机实测: 一条
%                                 -batch 链自己就占 **2** 行 —— 包装 matlab.exe +
%                                 win64\MATLAB.exe; 套件里的并行用例再 +1)。所以
%                                 "读数 > 2" 才是"机器上有第二个 MATLAB", 不是 "> 1"。
%                                 tasklist 的 IMAGENAME 比较不区分大小写, 两个名字一起中。
%     source                      'win32_os_query' | 'memory_fallback' | 'none'
%
%   为什么不用 memory(): 本机 memory 的返回结构里没有 MemMaxAvailable (实测),
%   而记录环境量的代码把取数包在裸 catch 里 —— 于是"空闲内存"这一列在归档产物里
%   整列是 null, 而墙钟数字又只有靠它才判读得动。取不到必须说出来 (source 字段),
%   不许静默交一个 NaN 当测量。

h = struct('free_mb', NaN, 'total_mb', NaN, 'matlab_processes', NaN, 'source', 'none');

% 问操作系统: 两个独立的单次调用, 每次只回一个数, 解析面最小。
freeKb = queryKb('(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory');
totalKb = queryKb('(Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize');
if ~isnan(freeKb) || ~isnan(totalKb)
    h.free_mb = freeKb / 1024;
    h.total_mb = totalKb / 1024;
    h.source = 'win32_os_query';
else
    % 退回 MATLAB 自己的 heap 口径: 字段名随版本变, 所以按"像可用内存的那个字段"找,
    % 而不是硬写一个当年猜过的名字。
    try
        m = memory;
        fn = fieldnames(m);
        pick = fn(~cellfun(@isempty, regexpi(fn, 'free|avail', 'once')));
        if ~isempty(pick)
            h.free_mb = double(m.(pick{1})) / 2^20;
            h.source = 'memory_fallback';
        end
    catch
        % 取不到就是取不到: source 留在 'none', 产物里看得见这句话。
    end
end

n = NaN;
try
    [st, out] = system('tasklist /FI "IMAGENAME eq matlab.exe" /NH');
    if st == 0
        lines = strsplit(strtrim(out), newline);
        hits = cellfun(@(s) ~isempty(strfind(lower(s), 'matlab.exe')), lines);
        n = sum(hits);
    end
catch
end
h.matlab_processes = n;
end

function kb = queryKb(expr)
kb = NaN;
try
    [st, out] = system(sprintf('powershell -NoProfile -Command "%s"', expr));
    if st == 0
        v = sscanf(strtrim(out), '%f', 1);
        if ~isempty(v) && isfinite(v) && v > 0
            kb = double(v);
        end
    end
catch
end
end
