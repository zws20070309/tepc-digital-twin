# 不确定度预算（RESEARCH/DEMO）

A 类=重复模拟统计；B 类=文献/规格；模型项=物理假设。
传播入口: `tepc.uq.propagateMC`（LHS + 正态 copula 相关采样 + 每样本全链重算）、
`tepc.uq.bootstrapSpectrum`（事件 bootstrap CI）。

## 预算表

| 来源 | 类型 | 分布/取值 | 影响 | 处置 |
|---|---|---|---|---|
| 事件计数 | A | 泊松/加权 bootstrap | 各 bin、yF/yD | bootstrapSpectrum（CI 已实现并测试） |
| W (TE 气) | B(REFERENCE) | 31.1 eV ±2%（正态） | 离子对数→分辨率/峰位 | propagateMC 变量 W_rel |
| Fano | B(ASSUMED) | 0.15–0.25 均匀 | 小信号方差 | propagateMC 变量 fano |
| 气压 | B | ±0.5% 正态 | 密度→等效位点/沉积 | propagateMC pressure_rel |
| 增益 (Diethorn ΔV) | B(ASSUMED) | ±3% | 电荷→幅度/峰位 | propagateMC gainScale |
| 阻止本领尺度 | B(ASSUMED) | ±5%（≥1 MeV）；<1 MeV 拼接段 ±15%；<80 keV ±30% | 沉积/射程/谱形 | propagateMC stopScale（全谱统一尺度；谱形系统差未含，见限制） |
| ADC 标定 | B | ±1% | 码→能量 | propagateMC adcCal_rel |
| 几何尺寸 | B(ASSUMED) | 公差蒙卡已实现（`tepc.geometry.toleranceMonteCarlo`），但**仓库内不存在任何可引用的数值公差**：蒙卡用的是代码里给定的**假设 σ**（图纸公差未入库），所以这一行现在的输出只是"对假设公差的敏感度"，不是尺寸不确定度 | 弦长/位点/干涉 | 拿到图纸公差后把 σ 换成实测值；在此之前结果只到"公差敏感度"这一层 |
| 模型形式：腔形理想化 | 模型 | 球腔 ↔ 等体积、等径高(H=2r)圆柱腔的平均弦长比 = (2/3)^(1/3) = 0.8736，相对差 **12.64%**（Cauchy 定理 lbar=4V/S 闭式） | 弦长是 y 的分母，直接影响谱形口径 | 由 `tepc.uq.convergence` 的 `model_form` 字段算出并手算可核（回归锁 `tests/unit/test_uq_convergence.m`）。**注意它是弦长口径的模型形式差，不是 y_F 的模型形式差**：换算到 y_F 需要逐事件输运重跑，本仓库不做该外推 |
| 模型形式：作用点在弦上的取法（中子反应点的诞生点度量） | 模型（口径，非抽样量） | **已实测两种取法的差**：各向同性均匀注量下"体积均匀体内点 + 弦过该点"与"解析弦上再沿弦均匀取点"给出不同的发布 y_F —— 订正口径 41.080100 对同批体积均匀参照 39.338475（**+4.427%**），被否定的旧口径 37.758288 对其同批参照 41.331308（**−8.645%**）。两批的参照值本身不同（39.338 与 41.331），**不得把这两个百分比串成一条链**，只能各带批次引用。数值出自仓库外探针，**可复现但当前无归档产物**，故只当量级用；判据本身在库内（tests/unit/test_transport.m 的 test_birth_point_measure_is_volume_uniform）。被否定的理由不是数值不好看，而是边缘分布：沿弦均匀产生的点密度正比 ∫dμ(γ)/L(γ)，实测 P(r>0.9R)=0.3793（2×10⁶ 样本）对闭式体积均匀值 1−0.9³=0.2710 偏 +346 sigma，即把作用点推向腔壁 | 弦上作用点决定逐事件气腔径迹长度分布 → y_F 均值与谱形 | **不入合成预算**：这是口径而不是有分布可抽的扰动量，给它编一个 ±% 就是把修正冒充不确定度。现状是"已修正 + 已被锁"：`tepc.geometry.sampleChord(geom,1,"internal_isotropic")` 给出体积均匀的 Pin 并令 P0=Pin，回归锁同时带正例（P0 与 Pin 逐位相同、经验 P(r>0.9R) 落在闭式 ±5σ 内）与反例腿（沿弦均匀必须比闭式高 >10σ，否则该判据是恒绿装饰）。**残余限制必须随数携带**：该度量只对**各向同性均匀注量**成立；准直束入射时作用点应服从注量的角分布与衰减，现口径不适用，且本仓库没有实测注量谱可标定这一层 |
| 抽样数（LHS 阶梯） | A | 均值标准误 se_rel = sd/(sqrt(N)·\|mean\|) 沿 `Samples` 阶梯服从 1/sqrt(N)；变异系数 u_yF_rel = sd/\|mean\| 与 N 无关（参照 1） | y_F 的 A 类分量 | `tepc.uq.convergence(cfg,'Samples',[64 128 256 512],'NEvPerSample',300)` 产出逐级 u 与 `observed_ratio`/`expected_ratio`。小 N 时**不得把 1/sqrt(N) 当门禁**：标准差自身的相对抽样噪声约 1/sqrt(2(N-1))（N=8 时 ~27%），表内 `noise_ref` 就是这个量 |
| 计算实现（分块与重复实现） | 数值 | **已锁（2026-09-23 实测绿）**：①同一 seed、N=5000 下 `run.chunkSize` 100 与 2000（50 块 vs 3 块）的逐事件 `flags` 与 `weight` 向量逐位相同（`tests/unit/test_false_trigger_rate.m` 契约 6，历史上正是它抓住过块边界把 pile-up 携带量复位的缺陷）；②"续跑 vs 一次跑完"的 y_F/yD 逐位相同；③同一 seed、N=120 下 `chunkSize` 7 与 1000（18 块 vs 1 块）的 `/events` 全部 22 个数据集名字/类型/值逐位相同（2026-09-30 复跑：事件表加入 channelId 道标签后是 23 个数据集，同一判据仍逐位相同），发布值 `yF_keV_um` 逐位相同（`AbsTol 0`），且按权重分段合并与整表值的相对偏差 ≤ 1e-12（`tests/integration/test_run_chunk_invariance.m`，另带一条合成负控：段权取"事件数"时必须对不上，证明该判据会红）；④`propagateMC` 的复刻链在真名义点与发布管线同值——名义样本（normal 的 sd 归零、uniform 的区间塌到该变量物理名义值）的 y_F 彼此逐位相等并与 `execute` 的发布值逐位相等（`tests/unit/test_uq_measurement.m/test_uq_chain_is_the_pipeline_chain`） | y_F 的"计算方式"分量 | 上面四条把"分块"与"重复实现"这两个计算实现分量锁成了逐位相同，所以本项不再是未知；但**仍不给数值份额**：求和次序、能量网格离散、PDE 收敛容差这三类实现自由度未扫描，任何时点都不得据此声称"计算不确定度整体可忽略"。此前评估过一版把链自己复刻一遍的扫描模块，结论是不安装：它的"分块无关"档位在块数不小于事件数时退化成同一计算比三次（空转），而它要证的三件事里有两件已由上面更便宜的锁承担、第三件应由断言而不是诊断工具承担 |
| 核数据/反应道 | 模型 | 截面权重 ASSUMED | 通道占比 | 无法量化，报告声明 |
| 角分布 (C/O CM) | 模型 | 各向同性近似 | 反冲谱形 | ASSUMED，报告声明 |
| 能损涨落 (Bohr 分支) | 模型 | **已实测"关掉它"的代价**：同 seed 配对两腿（默认带涨落 vs `straggle=false`），气腔均值偏移 **+0.72%** @初级 1 MeV（2.2 倍配对标准误）、+0.40% @0.30 MeV（1.1 倍，分辨不出）、**+1.89%** @0.05 MeV（3.8 倍）；两腿气/壁分配不同的事件占 30.75% / 64.0% / 51.45% | 逐事件气腔沉积 → y_F 均值与谱形 | 产物 `docs/test_evidence/straggling_production_mix_20260925T182013Z.json`（+ 同名 .log），N=2000，生成器 `tools/stragglingProductionMixProbe.m`。**这一行给的是"涨落作为建模组件有多大影响"，不是它的份额**：要把 0.72% 当不确定度用，必须拿"真实涨落谱 vs 本处的单高斯+截断 [0,E]"对比，那份数据仓库里没有（与上面两行的核数据缺位同族）。方向要读对：关掉涨落 ⇒ 少了"向下涨落让粒子提前在气腔内停住"那一支 ⇒ 气腔沉积系统性**偏低**，所以 +0.72% 是"这套高斯近似至少值多少"的下界参考而不是误差棒。两个随数限制：0.30 MeV 那档 1.1 倍标准误**不等于无关**，只是本批分辨不出；停在气腔内的径迹两腿沉积恒等（逐步累加+残能就地沉积是恒等式），所以占比判据看的是分配而不是逐位差，纯浮点重结合（本批 5/32/155 条）已单列剔除。另：正因为这条会移动中心量，它**不能做成省钱的档位** —— 档位表的立表前提是所有档中心量逐位相同（见 `docs/performance_tiers.md` §1） |
| 电子学采样时间离散化 | 数值 (模型形式) | **已实测上界，未钉死**：合法最粗档 Ts=2e-8 相对发货 1e-8，同 seed N=43000 两腿上 y_F 相对差 **+0.59%**，两腿合成计数地板 0.64% ⇒ 0.92 倍地板，2σ 判据下**分辨不出**，差值的 95% 区间 **−0.70%…+1.88%**（区间只覆盖**计数抽样**误差，不含任何模型形式差；点值与零不可区分）；先前 N=400 读到的 +1.28% / +2.35% 都落在同批 4.7% 地板内，只能当形状证据，不能当量级引用 | 成形峰 ∝(1-Ts/tau)^2、噪声 PSD 积到 1/(2Ts)、触发时刻按 ipk·Ts 量化 ⇒ 随 Ts→0 收敛的系统偏移，作用在峰位与触发时间上 | 不进 propagateMC（它不是抽样量而是离散化选择，没有分布可抽）；量级已约束在 ≲2%，要钉死需每腿有效样本再放大 5 倍（N≈2.2×10⁵）。config/validate.m 的 TS_TOO_COARSE 是 warn 不是 error，所以“合法”只意味着降级标注而不禁止。产物 `docs/test_evidence/ts_pair_20260925T214543Z.json`（+ 同名 .log），裁决与算式见 `docs/performance_tiers.md` §2 第一行与 §3 第 3 条 |
| 阈值/噪声/死时间 | B(ASSUMED) | 阈值 ±5%、噪声密度 ±10%、死时间 ±5%（均为正点估计带宽，无证书） | 阈下清零、占用窗与活时间 | propagateMC 变量 `threshold_rel` / `noise_rel` / `deadTime_rel`（三者已真正接入链路并计入合成；高率扫描另见 D-20） |
| 壁厚与壁密度 | B | 名义 3 mm A-150（ρ=1.124 g/cm³，常数注册表 `transport.a150.density_g_cm3`） | **只把出腔剩余能量分到"壁内沉积 vs 逸出"两侧，不进入气腔沉积** | **不入合成预算**（实测，不是推断）：同 seed 4000 事件下 ρ×3 与 t×5 时逐事件气腔沉积列、f(y)、y_F=19.4125677197 全部逐位不变，逸出恒为 0。逸出通道要到薄壁才打开：t=100 µm 时 0.012%、30 µm 时 2.86%、10 µm 时 29.7%，且响应只依赖于面密度 ρ·t（t=30 µm@1.124 与 t=100 µm@0.3372 给出同一个 18536.017 keV，末位不差）。锁：`tests/unit/test_wall_effect_negative_control.m`（阶梯过渡真实存在，证明旋钮是活的）与 `tests/unit/test_uq_budget_inertness.m`（名义几何下的零响应 + 面密度简并）。把"±1% 壁厚"塞进 LHS 只会得到一条恒零的预算行，被读成"已评估且可忽略"；真正的壁效应缺项是**壁内产生的反冲核**（这一句只对**中子腿**成立；伽马腿的壁内次级已接入，见下面新增的两行）（`AnalyticAdapter` 的诞生点在气腔体内），先补该物理，壁厚/密度才有可传播的响应。这条前置本身也被一份缺位的核数据挡着，而且是机读可见的：`config/reference_slots.json` 里 `wall_a150_composition` 状态为 ABSENT（只有名义密度有值并已接线，配方没有）。现在壁那一侧的能损/射程是拿**气体**阻止本领表乘 ρ_wall 近似的（`csdaTransport.m` 的 `wallEscape` 收到的 `T` 就是气表），要做壁内产生并按 A-150 逐元素加权就得先有这份配方；手抄一份进来正是 D-07/D-08 一直拒绝的伪造核数据做法 |
| 中子弹性通道份额（占位截面） | B(ASSUMED，数据缺位) | **顶替缺位核数据的就是配置里的三个占位量级值 source.channelSigma_barn（H 4.2 / C 1.5 / O 1.6 barn），它决定 H/C/O 的作用份额，实测对发布量是一等杠杆**：同 seed 12345、N=4000、mono_neutron 初级 1 MeV，只改这三个数 → 基线 y_F=19.41256772（**配方未钉死的那一批，按原句不可复现**：原句没写配置文件、随机流种类、run 种子与 y 的分母口径。现按 `tools/uqBudgetRefreshProbe.m` 钉死配方重测，同一装置同一工况得 **y_F_exact=37.79369890**，产物 `docs/test_evidence/uq_budget_refresh_20261005T072356Z.json`（+ 同名 .log）。两个数**不同批、不同配方，不可串成一条链，也不可用于否证对方**；下面 H/C/O 那几档的百分比只与 19.41 那个基准同批，引用时必须整批带走），H x2 得 21.25837068（+9.51%）、H 除以 2 得 17.05015757（−12.17%）、C x3 得 16.85377331（−13.18%）、O x3 得 17.27498518（−11.01%）；各腿计数地板 1.348–1.660%，故 |Δy_F|/u_floor = 6.70–7.94。单核种腿的 y_F 分别 23.45366685（H）/ 3.631492103（C）/ 2.118620442（O）。**基准不同不可与本表其它行排名**：这里动的是 2–3 倍，而阈值/噪声/涨落那几行是 ±5% 量级扰动。**不入合成预算**：截面没有可抽的分布（槽位 neutron_differential_cross_section 状态 ABSENT，见 config/reference_slots.json），把“±一个因子”编成随机数就是伪造核数据。同批另一条负结论：发货混合内部按次级能量分带（q50=0.38527、q90=0.87784 MeV）只解释 y 方差的 0.62%（带均值 20.2118/19.4369/15.3194），且逐事件核种不能从现有事件列还原 → 信息在**份额**上而不是逐事件归因上；y_F 取真值列 EdepGas/lbar，不是仪器反演的发布值。产物 docs/test_evidence/channel_weight_leverage_20260929T150930Z.log、species_axis_energy_band_20260929T150930Z.log、species_axis_leg_pairing_20260929T150930Z.json |
| 场构型 (cylinder ↔ sphere) | 模型 | **未定**：场类型只由 `geometry.electrodeTopology` 经 `tepc.geometry.electrode` 导出；旧键 `geometry.fieldGeometry` 已被 validate 以 `FIELD_GEOMETRY_FIELD_REMOVED` 拒绝 | 同参数下 G_mean 差 ~1182 倍（700 V: 136 ↔ 1.6e5），并改变收集时间/弹道亏损 | 不再"无网格项"就当零不确定度：这是**结构性**不确定度，需装置实测电极构型才能定；validate 现拒绝球壳场+丝状阳极这类超量程组合 |

| 场来源：解析闭式 ↔ FEM 场图（模型形式差） | 模型 | **2026-09-24 套件内实测**（数值出自 `runtests('tests/unit/test_field_fem_map.m')` 的 `[tepc_wp2]` 打印行：**可复现但当前无归档产物**，故只当量级用）。只有 sphereWire 口径才是模型形式差：增益区电位降 intE(a→10a) 层级 2 的相对偏差 **4.63e-2**，而同例量到的层级 1→2 线积分相对变化 9.39e-5 是它的离散误差地板（即 4.63e-2 不是网格没收敛造成的）。**coax 那组 4.66e-5 / 2.35e-5 / 1.89e-5 不是模型形式差**：`tepc.detector.fieldConvergence` 头部就写明同轴极限几何的闭式解是该边值问题的精确解，所以 coax 对闭式的偏离只能当求解器误差 | Diethorn 形式 G=exp(ln2·intE/δV) 给出 dlnG/dln(intE) = ln2·intE/δV = 0.693×258.6/36.5 ≈ **4.91**（发货点 a=50 µm、b=25.4 mm、700 V、rStartFactor=10），故 4.63e-2 的场形式差 ≈ 对 G_mean 的 **0.23 系统偏移**，不可忽略；coax 离散项 1.89e-5 放大后 9.3e-5，低于计数统计地板约 560 倍可当零。地板按 `u_yF = sqrt(yD/yF - 1)/sqrt(n_eff)` 从**同一个 run** 现算：run `20260924_184817010-8403898ae6ae` 的 summary 给 yF=25.7791、yD=42.2662、n_eff=233 ⇒ CV=0.7997、**u_yF=5.2%**。两条禁令：propagateMC 报的 ~14% 是**合成**值不是计数值，不可混用；**不得把不同 run 的 CV 与 n_eff 拼成一对**（本行早先写过 0.823/√1476=2.1%，那正是拼出来的，已废）。**这是偏置，只能线性并入，不得按方差平方和**。另：发货配置 field.mode 全为 analytic，本行描述的是"未走的分支"若走上的代价 | 产出者：`tepc.detector.fieldConvergence(a_m, b_m, hv_V, struct('geometry','sphereWire'))` 的 levels(end).intE_a_10a 与 `tepc.detector.fieldModel` 同口径相减（变量名一律不加反引号，避免被 `test_uq_budget_inertness` 的幽灵变量锁误判为已映射 UQ 变量）。下界判据在 `tests/unit/test_field_fem_map.m`（断言其绝对值 >1e-3 且 >20× coax 最细层同类偏差）。**两项限制必须随数携带**：①该量不在收敛门禁内（C.gate 只覆盖 fluxAnode/lineIntEmag/phiwDiff）；②sphereWire 的阳极丝半长取 wireHalfLenFactor=0.9 且缺省 ASSUMED，抽样路径 z 与 coax 也不同，故应视作 0.6–0.95 区间内的括注值而非点值。那里的 RelTol 0.01 是人为选的**验收阈值**而不是测得偏差 |
| FEM 收敛数字该怎么读 | 数值 | 预注册阈值 0.05（层间相对差）与 0.005（远离阳极处 E 偏差）来自 `docs/constants.json` 的 field.fem.* 且 status=ASSUMED；判据对象只有 fluxAnode / lineIntEmag / phiwDiff，anodePeakEmag 因 E 正比 1/r 在丝面发散**不入判据**；而 converged=false 与 1.19e-2 / 6.61e-3 / 9.81e-3、0.00188335 那组数出自**非生产链**的 `tepc.field.solveElectrostatic`（GCI 只在那边实现） | 防两种误读：把"未收敛"当成场不可用（生产链另有精度门禁），或把 FEM 产物当逐位可复现（解向量哈希每次调用都变，是多线程归约次序而非算法不确定性） | FEM 场图身份只由 `tepc.detector.fieldMapFingerprint`（几何+层级+电压，不含解向量）标识，派生读数按容差核对；覆盖在 `tests/unit/test_field_electrostatic_gate.m` 与 `test_field_fem_map.m` |

| 不确定度传播深度（为省墙钟而接受的统计功效损失） | 数值（非物理分量） | **这一行不是份额，是"要不要花墙钟去给出不确定度陈述"这一层的代价**：三档 screening/standard/publish 只改 uq 的传播深度，所有已发布中心量逐位相同——活体锁 tests/unit/test_uncertainty_depth_tiers.m 的 tiersBitHarmless 用 N=120、同 seed 比 screening↔standard 的 y_F/y_D/nEff/D_gas_Gy/D_gas_per_event_Gy 五个量（AbsTol 0），publish 的同一性质**两边都有锁**：归档对账（同文件 ladderRunsMatchTheirGroups 与 tableDistinct 读 docs/test_evidence/uncertainty_depth_ladder_*.json，那份产物每腿 N 远小于发货 nEvents，只当量级）与活体第四条腿（同用例 tiersBitHarmless 现跑 未设档/standard/screening/publish 四条腿，N=120 同 seed，五个中心量逐位相同，并核 publish 的 u_nSamples 严格大于 standard、config_resolved.json 里 uq.nSamples=128）。选 screening 后发布量不再带 u_yF/u_yF_CI95、uq_status=DISABLED，报告侧由 depthLine 写明"不得进报告结论"。代价的可算口径是本仓库自己的 noise_ref = 1/sqrt(2*(n-1))（src/+tepc/+uq/convergence.m）：它是"报告出来的那个不确定度数值自身"的相对噪声，**与计数地板 u_yF 无关，加大 nSamples 也不改善 u_yF 本身**。n=32 时 12.7%，n=128（publish 档）6.3%，n=500 3.2% ⇒ 正式不确定度评定建议 nSamples>=500；发货演示取 32 只为秒级出结果 | 报告的不确定度陈述与墙钟；不影响任何中心量 | 非传播项，不进 propagateMC；档位定义与实测代价见 config/uncertainty_depth_tiers.json 与 docs/performance_tiers.md |

| 伽马腿的壁密度与壁厚（**新增 10-05**） | B(ASSUMED，值可传播) | 光子作用点按「入射壁 → 气腔 → 出射壁」整条线路的累积光学厚度抽样，所以 rho_wall 与 t_wall **既进产额也进输运**：同流种子 91007、N=1500 下 rho_wall 覆盖项 x1/x2/x3 的壁内次级计数 = **120 / 226 / 323**（严格增），气腔有沉积事件数 = 20 / 15 / 18 | 伽马道的计数分配与 y_F 均值 | **可传播但不可当真值**：mu/rho=0.08 cm2/g 与光电份额都是 ASSUMED 占位，所以这一行给的是「响应方向与量级」而不是不确定度份额。曾经的缺陷是采样侧直读注册表常数、输运侧吃覆盖项（产额对 rho_wall 恒为 120 不动 = 只传播了半个物理），已合一到 `tepc.transport.wallDensity(xopts)`；判据在 `tests/unit/test_transport.m`（同源逐位相等 + 严格增 + 名义计数>20 三条，反例实测回撤即红 `[120 120 120]`）；数值出处 `uq_budget_refresh_20261005T072356Z.log` |
| 引用一个预算数所需的**配方完整性** | 元规则（非物理分量） | 本表历史上多处只写「同 seed、N 事件、某工况」，缺 config 路径 / 随机流种类 / run 种子 / y 的分母口径（组织等效弦 vs 气腔弦）/ 是否过仪器链 —— 于是同一句话能跑出两个数而无从判别谁错 | 全部引用型数值 | `tools/uqBudgetRefreshProbe.m` 把上述项写进产物抬头，并自检「同配方两次逐位相同」，不满足即抛 `tepc:probe:NotReproducible` 且不出产物；今后新增引用数值必须带配方与产物指针，否则只能在表内标「不可复现」 |

## 实测敏感度（propagateMC 单变量扰动 ±5%，N=10000 事件的 y_F 相对展宽）

| 输入 | y_F 相对响应 | 备注 |
|---|---|---|
| gainScale (Diethorn ΔV) | 30% | 最强项，与解析一致（G 对 ΔV 指数敏感） |
| W_rel | 8.0% | 近线性 |
| adcCal_rel | 7.5% | **旧实现此项完全惰性**（扰动没进到刻度链），本轮修好才有响应 |
| stopScale | 5.3% | 旧实现同样惰性 |
| pressure_rel | 2.3% | 经密度→等效位点 |
| fano | 0.29% | 只影响涨落，不影响峰位（符合预期） |

单变量扰动时 |Spearman| ≈ 1；合成后 y_F 相对标准不确定度实测 0.1426。

## 相关性

- 压强—气体密度: **确定性物理关系**（理想气体定律），不作为独立输入对。
- 增益—HV: 通过 Diethorn 模型确定性耦合。
- 标定斜率/截距: copula 相关接口已实现（cfg.uq.correlations），demo 未启用
  （无标定证书数据）。

## 报告要求落实

- summary.json 给出 yF/yD/Qbar/D_t 的点估计；propagateMC 输出
  mean/sd/95% 分位区间（MC, JCGM 101 风格）与 tornado（Spearman 秩相关）。
- 谱为多变量结果: 每个 bin 保存 sum_w/sum_w2 → sigma_f；bin 间协方差
  由 bootstrap 路径提供（未默认输出全协方差矩阵，列为待办）。
- 失败样本不删除: propagateMC 按异常分类记录（id/message）。
