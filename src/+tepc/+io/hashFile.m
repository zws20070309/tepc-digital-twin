function h = hashFile(path)
%HASHFILE 文件 SHA-256 (纯 MATLAB 实现 sha256pm, FIPS 180-4, 已对标准向量验证)。
%   选纯实现的真实理由: 不依赖 JVM (matlab -batch/-nojvm 下同样可用), 且已对
%   Python hashlib 的 13 个长度向量逐位核对。
%   MATLAB->Java 传字节是可信的: java.security.MessageDigest 对 'abc' 返回标准
%   ba7816bf...。结果看似不符时错在格式化, 不在传输 —— 有符号 int8 用
%   sprintf('%02x', double(i8)) 输出时, 负字节会先符号扩展成 ffffff80 之类的长串。
fid = fopen(path, 'r');
if fid < 0, error("tepc:io:HashFailed","无法读取 %s", path); end
b = fread(fid, inf, 'uint8=>uint8');
fclose(fid);
h = tepc.io.sha256pm(b);
end
