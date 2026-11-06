classdef Project
%PROJECT 一键运行 API:
%   project = tepc.Project.open("config/local.json");
%   run = project.execute('N', 1e5, 'Mode', 'full_matlab');
%   project.exportReport(run, "results/report.html");

properties (SetAccess = private)
    cfg
    meta
end

methods (Static)
    function P = open(configPath)
        if nargin < 1 || isempty(configPath)
            configPath = fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json');
        end
        if ~isfile(configPath)
            configPath = fullfile(tepc.io.projectRoot(), configPath);
        end
        [cfg, meta] = tepc.config.load(configPath);
        P = tepc.Project();
        P.cfg = cfg; P.meta = meta;
    end
end

methods
    function R = execute(P, varargin)
        args = varargin;
        if ~isempty(P.meta.demoBanner)
            args = [args, {'Progress'}, {@(f,m) fprintf('[%5.1f%%] %s\n', 100*f, m)}]; %#ok<AGROW>
        end
        R = tepc.run.execute(P.cfg, args{:});
    end

    function exportReport(P, R, outPath)
        if nargin < 3, outPath = fullfile(R.runDir.results, 'report.html'); end
        tepc.report.htmlReport(R, outPath);
    end
end
end
