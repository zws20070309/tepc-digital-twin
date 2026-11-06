function out = writeCanonicalJson(path, x, dropFields)
%WRITECANONICALJSON 写 canonical JSON 并返回其 SHA-256 —— 文本、字节、哈希同源。
%   纪律: 必须**先**得到 canonical 文本, 由它生成字节, 再把同一批字节
%   写盘。若改用 jsonencode 写盘却对内存文本算哈希, "哈希=盘上内容"就破了,
%   config_sha256 与续跑守卫随之失去意义。
%   返回 out = struct(path, text, bytes, sha256, nBytes)。
if nargin < 3, dropFields = {}; end
txt = tepc.io.canonicalJson(x, dropFields);
b = uint8(unicode2native(txt, 'UTF-8'));
fid = fopen(path, 'w', 'n', 'latin1');       % 字节级写入: 不再做二次编码
if fid < 0
    error("tepc:io:WriteFailed", "无法写入 %s (目录不存在或只读)", path);
end
cleanup = onCleanup(@() fclose(fid));
nb = fwrite(fid, b, 'uint8');
clear cleanup
if nb ~= numel(b)
    error("tepc:io:ShortWrite", "%s 应写 %d 字节, 实得 %d (磁盘/权限?)", ...
        path, numel(b), nb);
end
out = struct('path', path, 'text', txt, 'bytes', {b}, ...
    'sha256', tepc.io.sha256pm(b), 'nBytes', numel(b));
end
