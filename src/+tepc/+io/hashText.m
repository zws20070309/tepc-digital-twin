function h = hashText(txt)
%HASHTEXT UTF-8 字节序列的 SHA-256 (64 位小写 hex)。
%   与 hashFile 同一纯 MATLAB 实现 (sha256pm), 因此"内存里生成的文本"与
%   "写到盘上再哈希"必然一致 —— 前提是写入用的就是同一份字节
%   (见 writeCanonicalJson: 它先得到文本、算字节、再写, 不做任何再编码)。
b = uint8(unicode2native(char(string(txt)), 'UTF-8'));
h = tepc.io.sha256pm(b);
end
