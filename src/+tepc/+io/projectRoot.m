function root = projectRoot()
%PROJECTROOT 项目根目录 (src/+tepc/+io/projectRoot.m 上溯四级)。
root = fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
end
