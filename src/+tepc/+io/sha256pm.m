function h = sha256pm(bytes)
%SHA256PM 纯 MATLAB SHA-256 (FIPS 180-4), 无 Java/工具箱依赖。
%   输入 uint8 向量, 输出 64 字符小写 hex。
%   要点: MATLAB 无符号整数加法饱和而非回绕, 加法一律经 add32 (模 2^32);
%   循环右移用 "低 n 位取出 + double 精确左移" 实现 (bitshift 左移会饱和)。
H = uint32([hex2dec('6a09e667'), hex2dec('bb67ae85'), hex2dec('3c6ef372'), ...
    hex2dec('a54ff53a'), hex2dec('510e527f'), hex2dec('9b05688c'), ...
    hex2dec('1f83d9ab'), hex2dec('5be0cd19')]);
K = uint32(hex2dec({'428a2f98','71374491','b5c0fbcf','e9b5dba5','3956c25b', ...
    '59f111f1','923f82a4','ab1c5ed5','d807aa98','12835b01','243185be','550c7dc3', ...
    '72be5d74','80deb1fe','9bdc06a7','c19bf174','e49b69c1','efbe4786','0fc19dc6', ...
    '240ca1cc','2de92c6f','4a7484aa','5cb0a9dc','76f988da','983e5152','a831c66d', ...
    'b00327c8','bf597fc7','c6e00bf3','d5a79147','06ca6351','14292967','27b70a85', ...
    '2e1b2138','4d2c6dfc','53380d13','650a7354','766a0abb','81c2c92e','92722c85', ...
    'a2bfe8a1','a81a664b','c24b8b70','c76c51a3','d192e819','d6990624','f40e3585', ...
    '106aa070','19a4c116','1e376c08','2748774c','34b0bcb5','391c0cb3','4ed8aa4a', ...
    '5b9cca4f','682e6ff3','748f82ee','78a5636f','84c87814','8cc70208','90befffa', ...
    'a4506ceb','bef9a3f7','c67178f2'}));
bytes = bytes(:);
len = numel(bytes);
padLen = mod(55 - len, 64);
lenBytes = uint8(mod(floor(double(len)*8 ./ 2.^(56:-8:0)), 256)).';  % 64 位大端
msg = [bytes; uint8(128); zeros(padLen, 1, 'uint8'); lenBytes];
nBlk = size(msg, 1) / 64;

for blk = 1:nBlk
    wi = (blk-1)*64 + (1:64);
    w = zeros(1, 64, 'uint32');
    for t = 1:16
        b4 = msg(wi(4*(t-1)+(1:4)));
        w(t) = uint32(b4(1))*2^24 + uint32(b4(2))*2^16 + uint32(b4(3))*2^8 + uint32(b4(4));
    end
    for t = 17:64
        s0 = bitxor(bitxor(rotr(w(t-15), 7), rotr(w(t-15), 18)), bitshift(w(t-15), -3));
        s1 = bitxor(bitxor(rotr(w(t-2), 17), rotr(w(t-2), 19)), bitshift(w(t-2), -10));
        w(t) = add32(add32(w(t-16), s0), add32(w(t-7), s1));
    end
    a = H(1); b = H(2); c = H(3); d = H(4);
    e = H(5); f = H(6); g = H(7); hh = H(8);
    for t = 1:64
        S1 = bitxor(bitxor(rotr(e, 6), rotr(e, 11)), rotr(e, 25));
        ch = bitxor(bitand(e, f), bitand(bitcmp(e), g));
        temp1 = add32(add32(add32(hh, S1), ch), add32(K(t), w(t)));
        S0 = bitxor(bitxor(rotr(a, 2), rotr(a, 13)), rotr(a, 22));
        maj = bitxor(bitxor(bitand(a, b), bitand(a, c)), bitand(b, c));
        temp2 = add32(S0, maj);
        hh = g; g = f; f = e;
        e = add32(d, temp1);
        d = c; c = b; b = a;
        a = add32(temp1, temp2);
    end
    H = uint32(mod(double(H) + double([a, b, c, d, e, f, g, hh]), 2^32));
end
h = lower(reshape(dec2hex(H).', 1, []));   % 先转置再列优先拼接 = 逐字顺序
end

function y = add32(x, y)
y = uint32(mod(double(x) + double(y), 2^32));
end

function y = rotr(x, n)
% rotr(x,n) = (x >> n) | (x << (32-n) mod 2^32)
low = bitand(x, uint32(2^n - 1));
y = bitor(bitshift(x, -n), uint32(mod(double(low) * 2^(32-n), 2^32)));
end
