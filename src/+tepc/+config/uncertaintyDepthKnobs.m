function names = uncertaintyDepthKnobs()
%UNCERTAINTYDEPTHKNOBS 档位允许覆写的配置路径白名单 (来自代码, 不来自档位表)。
%   白名单必须由代码给出: 若它只是档位表里的一个字段, 表就能自证任何旋钮合法,
%   "表里有、代码没读"的装饰档位又会出现。
names = ["uq.enabled", "uq.nSamples"];
end
