function writeJson(path, S)
%WRITEJSON 结构体 -> JSON (统一缩进, 文本 UTF-8)。
txt = jsonencode(S, 'PrettyPrint', true);
fid = fopen(path, 'w', 'n', 'UTF-8');
if fid < 0, error("tepc:io:WriteFailed","无法写入 %s", path); end
fwrite(fid, txt, 'char');
fclose(fid);
end
