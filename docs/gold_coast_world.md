# 黃金海岸 3D world

來源：`video/*[Qu4vsKXiRtM]_1080p.mp4`；30:16，1920×1080，60000/1001 fps。

## 本次固定驗收清單

`data/gold_coast_checklist.json` 於 2026-10-22 凍結；分段與參考幀時間固定，`data/gold_coast_sections.json` 的生成配置參數則逐輪修正並留紀錄。24 張原始參考幀的 decoded PTS、時間基準與 SHA-256 在私有的 `video/gold_coast_ref/frames.json`；contact sheet 僅供粗讀，不能代替幀證據。人物、車輛、單車、HUD 與影片文字不屬於輸出的靜態環境。

- S01 0–170s：北段海灣松樹步道；公寓與路旁長椅。
- S02 170–245s：狹窄石護岸；右側高層公寓、低石護岸。
- S03 245–280s：路旁步道與開放沙岸；矮層公寓與白色路燈。
- S04 280–355s：螺旋樹與草地公園；海螺樹及藍色遮陽棚。
- S05 355–400s：露營區林蔭小徑；左側白色露營屋及鐵絲圍欄。
- S06 400–435s：白色小教堂與涼棚；右前方白色斜頂小教堂。
- S07 435–490s：Mitchell Park 船坡；右側船棚、左側船坡。
- S08 490–550s：水岸公園與碼頭；左側碼頭、右側公園草地。
- S09 550–590s：彩色遊樂場與護牆；左側彩色遊樂設施、右側護牆。
- S10 590–675s：主幹道旁柏油步道；右側高層大樓與多車道道路。
- S11 675–750s：跨水橋去程；兩側白色欄杆及彎曲燈桿。
- S12 750–835s：Main Beach 濱水步道；右側公寓、左側泊船碼頭。
- S13 835–900s：折返後河岸步道；左側道路、右側海灣。
- S14 900–970s：跨水橋回程；兩側白色橋欄杆。
- S15 970–1060s：主幹道旁公園回程；左側道路與遠方高樓。
- S16 1060–1130s：遊樂場林蔭回程；右側彩色遮陽帆與遊樂場。
- S17 1130–1180s：咖啡館與南段水岸；左側咖啡館、右側草地水岸。
- S18 1180–1265s：半島砂土與木樁圍欄；左側木樁網圍欄、右側水岸。
- S19 1265–1340s：運動設施與草坪；左側健身架、遠處高樓。
- S20 1340–1405s：小教堂／溪橋回程；小橋欄杆及白色小教堂。
- S21 1405–1500s：北段公園回程；左側公寓、右側水岸長椅。
- S22 1500–1635s：狹窄石護岸回程；左側公寓、右側護岸與水。
- S23 1635–1735s：海灣松樹與公寓回程；松樹成排、左側公寓。
- S24 1735–1816s：北段步道終點；右側涼棚與近水草地。

## 資料與可信範圍

路徑使用 OpenStreetMap 公開步道／自行車道（ODbL）；影片與地圖的時間錨點是人工估計，並非 GPS。海拔使用 DEM 路面剖面；橋面另記估計，不能稱為測量值。相機視高／FOV 需由原生影格比對校正。

資料來源：[Broadwater Parklands](https://corporate.experiencegoldcoast.com/venues/broadwater-parklands)、[Harley Park](https://experiencegoldcoast.com/places-to-go/northern-gold-coast/things-to-do/harley-park-au0097425)、[OpenStreetMap](https://www.openstreetmap.org/copyright)。

## 最新：自動巡覽坡段與急彎視線修正（r4）

共用地形生成器新增可選 `road_transition_m` 與 `road_max_bank_grade`，將其他路段的高地形漸進銜接至路緣；Gold Coast 設定為 8m、0.25 的地形橫坡包絡。這只限制 P1，沒有修改道路縱坡。共用相機依前方彎度縮短前視距離，避免 8m 固定前視線切入彎內地形。

`route.json` 與全部道路 GLB 與 r3 位元組相同。39,318 個全域路面探針均 clear；路緣外 5cm 的最大高出路面由 2.007m 降至 0m，外側 0.5m 由 2.015m 降至 0.075m。分塊接縫最大 0.978mm。105 項 Python 測試及 Godot 相機回歸測試通過；R12 測試彎的最大視線偏角由 19.12° 降至 7.162°，視高保持 1.65m。27 個坡段／急彎原生視角已渲染檢查。

- [修正前後對照](../export/gold_coast/review/slope_clearance/review.html)
- [啟動 r4 自動巡覽](../export/gold_coast/review/slope_clearance/view_world.command)
- [量測報告](../export/gold_coast/review/slope_clearance/repair_report.json)
- 最新候選包：`export/packages/gold_coast_broadwater_r4/`，2,068 植栽、358 設施、19 共用模型。

P0–P6 資料與 package integrity 通過；完整影片視覺驗收仍為 0/24、blocked，未放寬標準。距路緣較遠的坡面仍以其他實體道路邊緣為優先，不能宣稱所有地形橫坡都小於 25%。

## 前一輪：S18 跨路段地形遮擋已修正

共用 `tools/terrain_clearance.py` 依 P0 道路 footprint 裁切非相鄰路段的 P1 地形。
`route.json` 與全部道路 GLB 的 SHA-256 完全不變。新增全域驗證：39,318 個中心／80% 路寬取樣，
阻擋點 0；S18 原始 8 個失敗位置全數 clear。分塊接縫最大 0.49 mm。104 項測試通過。

植栽與建築改用實際地形三角形，並排除其他路段道路範圍；重建後有 2,068 個植栽實例、358 個設施。
S02 護岸起點避開道路交會的 3m，以 authoring 參數記錄，沒有改驗收清單或路面。

- [本輪修正對照](../export/gold_coast/review/terrain_fix/review.html)
- [本輪巡覽（直接從 S18 開始）](../export/gold_coast/review/terrain_fix/view_world.command)
- [幾何修正報告](../export/gold_coast/review/terrain_fix/repair_report.json)
- 新候選包：`export/packages/gold_coast_broadwater_r3/`；舊候選與截圖保留。

這是可騎行路面問題的修復；影片／路線時間對應、近路道路、岸距、碼頭及部分地標仍需逐段校正。
完整視覺驗收仍是 **0/24 段通過**，`acceptance.json` 保持 blocked，不能宣稱 3D world 全部完成。

## 前一輪候選版：視覺退修

共用生成器的小半徑彎道／相鄰 offset ray 問題已修復；原有 10 項網格錯誤已清除。
估計路線為 **13,104.7827 m**，13,106 samples，53 個分塊。移除地圖錨點導致的非影片折返支路，
保留真正的 Main Beach 折返。路寬、高程、坡度沒有為了消除網格錯誤而被修改；新幾何重新取樣 DEM。

100 項引擎外測試通過；P0–P6 候選資料、2,099 植栽實例、358 建築／設施與 19 共用模型已生成。個別 stage 數值檢查均通過。
但是 **整包驗收仍 INVALID / blocked**：原生畫面揭露了局部 validator 未涵蓋的跨路段地形遮擋。
S18 在 s≈8851m 的路面被回程 s≈9150m 地形蓋住約 0.74m（見 `s18_ground_probe.json`）。
須先修共用地形的非相鄰路段限制，加入回圈 fixture，不能抬高路面或改坡度掩蓋。

完成兩輪完整原生 Metal 1920×1080 渲染，固定清單 **0/24 段通過**。來源路線／時間映射、
相機與岸距仍是估計；缺車道、碼頭、部分地標、局部樹種與材質。依 skill 兩輪退修規則停止第三輪視覺修改。

- [最新本地對照](../export/gold_coast/review/world_round2/review.html)
- [逐段阻擋清單](../export/gold_coast/review/world_round2/blocked_sections.md)
- [巡覽啟動檔](../export/gold_coast/review/world_round2/view_world.command)
- [候選場景包](../export/packages/gold_coast_broadwater/manifest.json)，`acceptance.json` 明列阻擋。
- 新增 prototype 的 `mesh_file` 與整包 acceptance 檢查：候選版不會因各 stage 本身通過而被誤報完成。
- 私有影片幀只存在本地 review，不在場景包。紋理樹的原始圖檔只保存一份，沒有降解析度／重新壓縮。

### 最新重建流程

```bash
python3 tools/build_osm_route.py assets/geography/gold_coast/network.json data/gold_coast_route_alignment.json export/packages/gold_coast_broadwater/route/route.json
python3 tools/build_coastal_layers.py profiles data/gold_coast_sections.json export/packages/gold_coast_broadwater data/gold_coast_terrain.json
python3 tools/road_terrain.py build export/packages/gold_coast_broadwater --tile-m=250 --terrain=data/gold_coast_terrain.json
python3 tools/build_coastal_layers.py semantics data/gold_coast_sections.json export/packages/gold_coast_broadwater
python3 tools/vegetation.py build export/packages/gold_coast_broadwater
python3 tools/structures.py build export/packages/gold_coast_broadwater --hints=export/packages/gold_coast_broadwater/structures/hints.json
python3 tools/environment.py build export/packages/gold_coast_broadwater --hints=data/gold_coast_environment.json
python3 tools/build_package_assets.py export/packages/gold_coast_broadwater data/gold_coast_library.json
# acceptance.json / manifest.acceptance must remain blocked until rendered review passes.
python3 tools/validate_package.py export/packages/gold_coast_broadwater
python3 -m unittest tools/test_osm_route.py tools/test_scene_package.py tools/test_package_assets.py
```

重建 road_terrain 會重寫 manifest，但會保留既有 `acceptance.json` 的引用。
直到完整驗收通過後才能設為 accepted。下方保留先前幾何退修歷史。未 commit。

## 歷史：使用者授權共用生成器修正前（2026-10-22）

**退修；只完成 P0/P1 幾何候選版，尚未完成完整 3D world。**

- 估計路線長 14,722.3858 m，14,724 個 canonical samples，59 個 250m 左右的分塊；route.json VALID。
- 道路／地形仍有 10 項錯誤，涉及 6 個分塊：8 個道路三角形面向錯誤、184 個地形三角形折疊／面向錯誤。
- baseline 44 項問題 → revision1 20 項 → revision2 10 項；兩輪退修後仍未通過，依 skill 停在 P0/P1。P2–P6 未開始，未製作正式交付 ZIP。
- 5 項 OSM 產生器測試與既有 87 項 stage tests 通過。Godot headless 匯入／相機檢查通過；Metal 原生 24/24 張 1920×1080 圖正常輸出。這些結果不代表網格或畫面驗收通過。
- S01 已見道路出口與來源不符；其餘需要在幾何修復後重新校正地圖／相機時間映射。未宣稱任何段落達 80%／90%。

本地證據：[`review.html`](../export/gold_coast/review/p0_p1/review.html)、[`review_record.json`](../export/gold_coast/review/p0_p1/review_record.json)。可雙擊 [`view_world.command`](../export/gold_coast/review/p0_p1/view_world.command)；Tab 切自動／自由模式，WASD + Q/E 飛行，PgUp/PgDn 沿路跳 250m。

### 待修復範圍

- S06, S07／tile 15，s=3750–4000m：tile 15: 1 road triangles face down；tile 15: 33 terrain triangles folded / facing down。
- S12, S13／tile 28，s=7000–7250m：tile 28: 3 road triangles face down；tile 28: 57 terrain triangles folded / facing down。
- S16, S17／tile 37，s=9250–9500m：tile 37: 2 road triangles face down；tile 37: 36 terrain triangles folded / facing down。
- S20／tile 45，s=11250–11500m：tile 45: 7 terrain triangles folded / facing down。
- S21／tile 47，s=11750–12000m：tile 47: 10 terrain triangles folded / facing down。
- S22, S23／tile 54，s=13500–13750m：tile 54: 2 road triangles face down；tile 54: 41 terrain triangles folded / facing down。

下一步先診斷共用 `tools/road_terrain.py` 對小半徑彎道與往返路線的 offset-strip 三角形；用最小失敗 fixture 驗證修正，不能直接反轉面向、縮窄真實路寬或放寬驗證器來消除錯誤。通過 P0/P1 後才能依固定清單生成海岸語意、植被、建物與環境。

### 高程與幾何來源限制

OSM 節點包含數位化折角；目前水平擬合的設定在 `data/gold_coast_route_alignment.json`（2m RDP 容差、8m corner trim、8m fitting window）。Northern Peninsula 未出現在 OSM 步道圖的部分，以獨立的 `estimated_paths` 記錄影片／地圖估計；不冒充 OSM 測量值。相機仍使用初始 1.65m 視高、75° vertical FOV。

高程來自 AWS Terrain Tiles Terrarium z14 的估計剖面；水面／水底混入路徑的 DEM 取樣無法代表橋面。橋面暫估端點 3m／中點 8m；低於 1.5m 的沿海混合取樣採 1.5m 暫估 datum，並在高程剖面明列所有濾波／接合視窗。這不是實測道路坡度，仍需校正；沒有額外視覺高程誇張。無法以目前候選版宣稱真實健身阻力的精確性。

### 重現

```bash
python3 tools/build_osm_route.py assets/geography/gold_coast/network.json data/gold_coast_route_alignment.json export/packages/gold_coast_broadwater/route/route.json
python3 tools/road_terrain.py build export/packages/gold_coast_broadwater --tile-m=250 --hill-amplitude-m=0
# 上一步目前預期 exit 1；保留錯誤，不執行後續生成階段。
godot --path . res://scenes/PackagePreview.tscn -- --package=res://export/packages/gold_coast_broadwater
python3 -m unittest tools/test_osm_route.py tools/test_scene_package.py
```

共用新增工具為 `tools/build_osm_route.py`、`scripts/package_preview.gd`／`scenes/PackagePreview.tscn`；新需求由資料設定，未新增 Gold Coast 專用生成器，當時未改動既有道路／地形生成器或預設場景。未 commit。

## S18 local detail candidate (2026-10-22, Luna 6)

Created `export/packages/gold_coast_broadwater_s18_r5` from frozen r4. The sole scene edit is a P2 fence zone on the source-visible right edge of S18, using the existing `fence_lattice` structure type from `s=8689.8348` through `9013.4632m`. Source identity is fixed at PTS `73200127 / 60000 = 1220.002117s`, frame 73127, SHA-256 `cb349552571ccb0da985f9ff381272f03d6b074b415a22634b21374d4452d819`. The old checklist describes the fence as left; the pixels show the prominent green mesh on the right, so this batch records that discrepancy without editing the frozen checklist.

The source camera-to-route correspondence remains estimated. The candidate leaves canonical `route.json`, grade, all road meshes, terrain and vegetation unchanged. S17/S18/S19 were captured at native 1920×1080 with the existing Godot PackagePreview consumer. S18’s added fence is correctly placed and clears the road, but the shared renderer draws all fences as white rails, which does not match the timber posts and green mesh. Visual review scores: L0 0.5/2, L1 1/2, L2 1/2, L3 0.5/2, L4 0.5/2 (3.5/10); the candidate remains blocked. No global or whole-route acceptance is claimed.

Evidence and hashes are in [`review.html`](../export/gold_coast/review/s18_detail_luna6/review.html), [`repair_report.json`](../export/gold_coast/review/s18_detail_luna6/repair_report.json), and [`hashes.json`](../export/gold_coast/review/s18_detail_luna6/hashes.json). Open the local native review with [`view_world.command`](../export/gold_coast/review/s18_detail_luna6/view_world.command). Focused semantics/structures tests: 28 passed. Whole-package validation passes every stage and integrity check; only frozen acceptance remains blocked. No commit.


### S18 r5a asset-reference correction (2026-10-22)

The r5 review remains preserved, but its tree asset was a procedural fallback: `tools/build_package_assets.py` had been run without the optional `data/gold_coast_library.json` argument. The new `gold_coast_broadwater_s18_r5a` restores both r4 prototype catalog JSON files, all 18 files under `assets/prototypes/`, and all 11 files under `assets/library/` byte-for-byte; it retains r4’s 358 structure records plus the approved S18 fence. The 53 vegetation tile instance files, vegetation zones, route, every road GLB and every terrain GLB match r4. No trees or cameras moved.

The corrected S18 native capture and four-way source/r4/r5/r5a comparison are at [`review.html`](../export/gold_coast/review/s18_tree_restore_luna6/review.html); report and hashes are beside it. The original r5 review page links to this correction and remains intact. Package validation passes all layers and integrity; fixed visual acceptance remains blocked. For future rebuilds, pass `data/gold_coast_library.json` to `tools/build_package_assets.py`. No commit.


### S18 fence adapter candidate r6 (2026-10-22)

The S18 `fence_lattice` prototype now renders in the shared Godot package-preview adapter as timber posts, an upper rail, and a procedural green mesh panel. This is a preview-only style change: `gold_coast_broadwater_s18_r6` retains the r5a route, vegetation assets/instances, structure objects, road and terrain files byte-for-byte; only the manifest package id differs. The r5a S18 before image used the prior adapter with fixed white rails, so the visual difference is attributable to adapter styling, not package geometry.

The native three-view comparison, per-item fence assessment, hashes, launcher and report are in [`s18_fence_luna6/review.html`](../export/gold_coast/review/s18_fence_luna6/review.html). The focused fence style regression passes. Package validation accepts all layers and integrity but the frozen checklist remains blocked; this candidate does not claim full-scene acceptance. The observed source has the fence on viewer-right, while the fixed checklist still says left; that wording was preserved.

### S18 nearshore sand material candidate r9 (2026-10-22)

Starting from frozen `gold_coast_broadwater_s18_r8_retry_luna6`, a material-only P1 pass adds the source-visible sandy strip outside the right road edge. `data/gold_coast_s18_sand.json` limits the estimated appearance to s=8823–8900 m and lateral 1.2–7 m, using the existing owner-terrain XZ triangles. This only regroups terrain material indices; all 53 terrain meshes retain identical positions, normals, route attributes, bounds, and indexed triangle multisets. Route/road bytes, 2068 vegetation instances and prototypes/assets, and all 359 structure records remain byte-identical to r8. The existing coast height/ownership profile and camera are unchanged.

Native Godot PackagePreview captures for S17/S18/S19 and same-view source/r8/r9 comparison are in [`s18_sand_luna6/review.html`](../export/gold_coast/review/s18_sand_luna6/review.html). The fixed S18 view shows a tan band from the outside of the path to the fence; the left verge remains green. This is a local appearance candidate based on video estimate, not surveyed surface classification. The frozen checklist and camera-to-route estimate are unchanged. Stage and package data layers/integrity validate; only frozen visual acceptance remains blocked. The rebuild command and hashes are recorded with the review; no commit.


### S18 left-canopy local candidate r10 (2026-10-22)

From the frozen r9 sand candidate, this package-local P3 override covers only zones `v1100`, `v1104`, `v1108`, `v1112`, `v1116`, and `v1120` (route s=8836.94–9013.46 m, left side; tiles 35–36). The fixed source is S18 at 1220.002117 s / s=8850.958079. In those six 4-tree zones, the 12 procedural palm and 6 broadleaf instances are mapped to the existing Island Tree 02 library mesh under `s18_fine_canopy_candidate`, uniformly scaled to 0.55 of their previous scale. The 6 Norfolk pine instances remain as a comparison/residual. The per-zone mix is recorded as 3 fine-canopy candidates plus 1 Norfolk pine (65 estimated stems/ha total); the world position, yaw, route s/u, count and ground placement of all 24 trees are preserved. The candidate alias inherits the original `assets/library/island_tree_02/island_tree_02_1k.gltf` mesh reference, attribution and material/texture asset bytes. This is only an estimated silhouette proxy; species is not asserted.

The 1920×1080 native same-camera S17/S18/S19 and local s=8848/8856 guard captures, round-1 S18 image, source/r9 comparison, invariant report, hashes and launcher are in [`s18_vegetation_luna6`](../export/gold_coast/review/s18_vegetation_luna6/review.html). The nearest tree at s=8852.608 remains visually large at s=8848 but stays left of the road exit; the fixed S18 view has a clearer upper-left sightline after reducing the local canopy. The pointed Norfolk silhouette remains visibly unlike the source, and the broadleaf proxy still differs from the thin, airy coastal foliage; this is a partial local candidate, not a visual pass. All 2,068 vegetation instances remain, and non-target instances are unchanged. Route, all 53 road and terrain GLBs, environment and 359 structures remain byte-identical to r9. P3 stage validation is valid; package validation accepts all data layers and integrity, with only the frozen acceptance checklist blocked. No global/whole-route visual acceptance is claimed.

Rebuild from the frozen r9 package with `python3 tools/vegetation.py apply-local-overrides export/packages/gold_coast_broadwater_s18_r10_luna6 data/gold_coast_s18_vegetation.json`, then run the vegetation and package validators. No commit.


### S18 local canopy silhouette candidate r11 (2026-10-22)

From frozen `gold_coast_broadwater_s18_r10_luna6`, this opt-in P3 authoring override affects only the six remaining `norfolk_pine` instances in zones `v1100`, `v1104`, `v1108`, `v1112`, `v1116`, and `v1120`. It aliases the unchanged high-detail Island Tree 02 library mesh under `s18_slender_canopy_candidate` and preserves the six instances' world positions, rotations, route s/u, and the full 2,068-instance count. Based on raw mesh AABBs (Norfolk 11.253 × 21.8 × 11.457 m; Island Tree 02 15.147 × 12.264 × 14.655 m), the local XYZ multipliers `[0.55, 1.7773, 0.55]` retain approximately the original height while narrowing the X/Z silhouette. The alias records the inherited Poly Haven CC0 asset lineage; the shape is a local silhouette proxy, not a species identification.

The native fixed S18 view removes the six pointed silhouettes and keeps the road exit/open sky clear. At the s=8848 guard the nearby broadleaf still reads as oversized and low/twisted; the candidate does not reproduce the source's finer airy shoreline foliage, and other Norfolk-like silhouettes outside the six authored instances remain. This is a partial local shape improvement, not a vegetation-fidelity or whole-scene pass. Same-version 1920×1080 captures for S17/S18/S19 and s=8848/8856, the source/r10/r11 comparison, invariant proof, hashes, report, and rebuild command are in [`s18_canopy_luna6`](../export/gold_coast/review/s18_canopy_luna6/review.html). The 3 focused override tests and P3 validator pass; package validation accepts its data layers and integrity, with only frozen visual acceptance blocked. No commit.

## S18 left wetland timber boundary candidate (r12)

A local source review at `video/gold_coast_ref/S18.png` (1220.002117 s; route s=8850.958079 m), with a 1210 s seek frame for context, shows a dark timber boundary on the left. Nearby trunks occlude portions; the 1230 s seek does not establish full-section continuity. No net color or mesh pattern is asserted. The finite video-estimated candidate is `s=8858–8884 m`, left `u=9.5 m`, using the shared `fence_timber_rail` structure prototype and renderer. The first trial range overlapped the P3 exclusion around the tree at s=8852.608/u=5.057 and was rejected; the final line retains vegetation unchanged. Full-world vegetation XZ inspection found no trunk-center intersection; the nearest center is about 2.854 m away at s=8864.116/u=12.41, which is not a canopy-clearance claim.

Candidate `export/packages/gold_coast_broadwater_s18_r12_luna6` is derived from frozen r11 and adds one semantic zone and one structure. The 359 old structure records retain their substantive fields; IDs are mapped in the review evidence because sorted IDs shift. Existing prototype assets, including all old `mesh_file` and `source` lineage, are preserved. Route, road and terrain geometry, vegetation, environment and existing zones remain byte-identical. Native S17/S18/S19 plus s=8848/8856 guard captures and validator evidence live in `export/gold_coast/review/s18_left_fence_luna6/`. Checklist L3 is partial: timber rails are visible but no net is modeled; the global acceptance remains blocked. This local candidate does not claim full S18 or route completion.

## Video, route-s and camera alignment probe

A read-only alignment pass traced all 24 fixed frame PTS values through the existing `preview_views` route-s estimates. Requested and decoded frame times differ by 0.000733–0.015533 s; the rows are monotone and each s lies within its matching route section. This confirms record consistency only. Without GPS or independently located landmarks, all existing s anchors remain estimated and unchanged.

S01 (apartment/bench), S17, S18 and S19 were compared at their existing s values. A shared 8° downward pitch probe moved the S18 rendered horizon toward the source horizon, but road exit, shore geometry and missing skyline remain mismatched. The probe is not an adopted calibration. The automatic camera remains 1.65 m above route, adaptive lookahead and 75° vertical FOV. A capture-only camera override resets before each view; route and package payload are unchanged. Full fixed-checklist acceptance remains 0/24 blocked.

The traceable mapping, all-24 status table, native comparisons, regression output and checksums are in [`alignment_luna6/review.html`](../export/gold_coast/review/alignment_luna6/review.html). No commit.

## S17–S19 compacted-sand PBR preview

An opt-in Godot adapter appearance override uses the existing Poly Haven [Coast Sand 01](https://polyhaven.com/a/coast_sand_01) maps by Rob Tuytel, CC0 under the [Poly Haven license](https://polyhaven.com/license). It affects only `concrete`/`dirt` road surfaces within the estimated S17–S19 route-s interval. The original 1024² maps are kept unchanged; the local preview uses a video-estimated 0.4 m repeat against the asset's stated 15 m texture span plus a subtle 0.035 m UV warp. This scales the visual grains as a proxy, not as a measured ground material. Diffuse is sampled in linear color space; the OpenGL normal map uses tangent-space `hint_normal` with renormalized runtime mipmaps; roughness remains linear data. No global import settings, source pixels, route/surface physics, or package geometry are changed. The PBR appearance is adapter-only and has not been serialized as a portable package material.

Fixed 1920×1080 captures for S17/S18/S19, the S18 close view, previous procedural comparisons, S01 fallback guard, texture attribution/hashes, tests, and launcher are in [`s17_s19_sand_pbr_luna6/review.html`](../export/gold_coast/review/s17_s19_sand_pbr_luna6/review.html). Fine granular texture is now legible at normal distance; mild tile repetition and a coarser-than-source grain remain. Route s/camera are still estimated. This is a partial material appearance candidate; fixed global visual acceptance remains blocked.

## S17–S19 road-sand appearance probe

An opt-in Godot adapter shader in `scripts/package_preview.gd` applies procedural compacted-sand color, mottling and restrained grain/relief to existing `concrete`/`dirt` road surfaces only within the estimated s interval in `data/gold_coast_s17_s19_sand_visual.json`. It does not alter package surface classifications, gameplay friction, route/road/terrain geometry, or camera defaults. This remains adapter-only; the engine-independent package does not yet carry this appearance override. The four 1920×1080 before/after captures use the alignment review's 8° pitch probe at S17/S18/S19 and a close S18 view; route s remains estimated. The result reads warmer and more granular, but fine grain and tire impressions remain subdued at normal distance, so this is partial rather than a material-fidelity pass. The review, launcher, focused-test logs, and checksums are in [`s17_s19_sand_material_luna6/review.html`](../export/gold_coast/review/s17_s19_sand_material_luna6/review.html). No source pixels were used for texture, and the frozen r12 package remains byte-identical.

## S19 missing-building candidate — r13

The fixed S19 source frame (1300.015383 s; existing estimated route anchor s=9461.932611 m) contains a cropped light apartment mass at upper left and a low pale pitched-roof mass ahead-left; r12 had neither, while its nearby open picnic shelter was a different object. Candidate `gold_coast_broadwater_s19_buildings_r13_luna6` appends two high-importance, fixed-anchor video estimates with generic shared apartment-corner and gable-house prototypes. It preserves all 360 existing structure records and all 32 existing prototype records exactly. Route, all 61 existing road and 61 terrain GLBs, vegetation, environment and all other preexisting GLBs remain byte-identical; two new structure prototype meshes are the only new assets. Same-camera native S18/S19/S20 and S19 ±20 m guard comparisons, source comparison, invariants, rebuild/view commands and checksums are in [`s19_buildings_luna6`](../export/gold_coast/review/s19_buildings_luna6/review.html). The apartment balcony bands are visible at S19; the low pale house remains difficult to distinguish behind existing scene clutter and is not made clearer by removing vegetation. Both are estimates, not surveyed landmarks. Structure tests and all package data/integrity stages validate; frozen acceptance remains blocked by the existing checklist. This is a local P4 candidate, not whole-scene acceptance.
## S19 georeference screening (r13 anchors retained)

The reproducible local route-frame map and six-time bearing table are in [`s19_georeference_luna6`](../export/gold_coast/review/s19_alignment_luna6/s19_georeference_luna6/s19_georeference_map.svg). The inputs are the accepted r13 route/structures and the saved OSM API bbox extract (SHA-256 `29f16925aea0f27ef8fe248da2cf4f3be555690f0b1a5c0a99acb16a1772aa8a`, © OpenStreetMap contributors, ODbL 1.0). The report JSON records the route origin, exact route-to-local projection, the frozen 1265–1340 s/time relation, decoded camera timestamps, and every closed building/building-part polygon in the bbox. The route heading is only a tangent proxy because the video camera can pan.

The screen preserves the existing visual estimates and does not establish an OSM match. st0361’s estimated point sits about 25 m from the mapped H2O Broadwater Apartments polygon and about 25 m from a 23-level building part; these are plausible apartment-area candidates but neither footprint is uniquely identified as the cropped video mass. st0362’s estimate is about 52 m from OSM way 1310786950, tagged `amenity=shelter` / `shelter_type=picnic_shelter`; that footprint is small (57.9 m²), and the next `sports_centre` footprint is about 74 m away. The shelter is geometrically near the 1310 station (about 20 m), but the source sequence does not uniquely tie its roof/facade to that footprint. Under the frozen time-to-route mapping, the sports-centre centroid is 134.42° behind/right of the route tangent at decoded 1305.003700s while the white building remains ahead in the source frame; this excludes that candidate only under the current mapping. Camera yaw and exact time-to-position remain uncalibrated. No anchor, route mapping, or package was changed; no candidate is promoted to a landmark.

The closest usable next evidence is an official/public aerial or owner/council image that shows the candidate roof/facade together with the park path and parking edge. Until that ties the source silhouette and approach/pass order to one footprint, retain the r13 video-estimated anchors and leave r15 unbuilt.

### S19 independently identified landmark pair and local time-registration finding (2026-10-23)

Primary public owner/architect references and the named OSM polygons now strongly identify the S19 white gabled building as Rotary Broadwater Chapel (way 1310786945), and the cropped apartment mass as the Sky Broadwater white balcony podium/end wall (ways 958537888, 1115393562, 1115393564). The adjacent Palmerston Tower (way 958537887) is visible with the pair in independent owner/architect context imagery. The Southport Bathing Pavilion is not supported by the compared exterior morphology; its 2015 reference differs, but roof color alone is not decisive because it predates the source video. Evidence URLs, local-review photo hashes, attribution notes and the map/report are recorded in [`s19_georeference_luna6`](../export/gold_coast/review/s19_georeference_luna6/review.html) and `export/gold_coast/review/s19_alignment_luna6/evidence/public_visual_sources_review.json`.

The canonical route has two close passes by the chapel: `s≈3268 m` (16.4 m, heading 157.4° southeast) and `s≈9883 m` (15.8 m, heading 334.7° northwest); Sky Broadwater and Palmerston also have nearby footprints on both passes. The frozen time mapping places decoded 1305.0037 s at `s=9525.8 m`, 327 m from the chapel, and leaves it 226 m away at 1315 despite the observed pass-and-clear sequence. A single local `+294 m` diagnostic offset maps 1305/1310/1315 to about 9820/9884/9948 m and gives the expected chapel ahead → left/pass → behind order, with the tower pair route-left. The alternative southeast pass requires `−6321.925 m`; it puts chapel/towers route-right at source times 1300–1310 and needs much larger unmeasured camera pan to fit the source left-side order. The water-right/rough northbound clue also favors the northwest pass qualitatively. These are bounded diagnostics, not an adopted global mapping; full S17–S20 anchor monotonicity and adjacent-turn timing remain to validate. Review-only 2D OSM projections at source 1300/1305 are in [`projection_1300.png`](../export/gold_coast/review/s19_georeference_luna6/projection_1300.png) and [`projection_1305.png`](../export/gold_coast/review/s19_georeference_luna6/projection_1305.png); they use a route-tangent camera and estimated/tagged heights, not occlusion or a camera fit. The r13 video-estimated anchors are about 310 m (st0362) and 334 m (st0361) from the identified footprints; exact visible facade/subpart and camera yaw still need resolution. No route or package data was changed; no r15 package is justified until timing and P4 clearances are validated. Durable status and next bounded task: [`data/gold_coast_s19_georeference.json`](../data/gold_coast_s19_georeference.json).

### S19 chapel + Sky podium local P4 candidate r15 (2026-10-23)

An independently evidenced landmark pair now links the source's white gable chapel and left-side white podium/tower to Rotary Broadwater Chapel (OSM way 1310786945) and Sky Broadwater (OSM parts 958537888/1115393562/1115393564). Primary chapel, architect and owner joint exterior photos support the identities and their geography; the exact video-visible faces/subparts and camera pose remain estimated. A local +294 m route-station diagnostic orders 1285–1315 chapel approach/pass/clear events better than the frozen mapping, but its boundary rates to S18/S20 and possible 1340–1350 edit prevent adoption. Canonical route and the full-world time map remain untouched.

`gold_coast_broadwater_s19_landmarks_r15_luna6` is a blocked, review-only P4 candidate. It replaces only st0361/st0362 and their tile structure refs, adds two shared prototypes, and preserves all 360 other structure records plus prior prototype assets. The final chapel footprint conflicts with one existing Norfolk pine inside the actual OSM outline. Direct world-space sampling covers all four rigid-envelope corners and all six mesh base vertices; the route-relative missing-ground report is a query discrepancy, while the placed base still differs from the sampled ground by up to about 0.256 m. The Sky OSM outline has four uncovered vertices, and one of four actual model base vertices lacks terrain. No P1/P3 edits were made. Independent evidence is in `export/gold_coast/review/s19_landmarks_luna6/root_review.md` and `root_footprint_probe.json`. Native 1920×1080 same-view r13/r15 renders at 1300/1305/1310/1315, ±20 m local guards, S18 and S20, source provenance/PTS, prototype tests, invariant notes and full validator output are in [`the review panel`](../export/gold_coast/review/s19_landmarks_luna6/review.html). r15 adds a recognizable estimated chapel/podium proxy, but the source apparent placement/scale remains mismatched and P4 validation fails; it is not promoted or globally accepted. Report, exact candidate mapping and reproducible viewer commands are in that review folder. No commit.

## S19 local support-ground candidate r16 (2026-10-23)

A review-only r16 package adds estimated, level P1 support faces beneath the existing Sky podium and Rotary Chapel proxies and removes only the one Norfolk pine whose stem/clearance intersects the named Chapel footprint. Both faces are generated by the shared road/terrain helper, confined to each declared rigid footprint plus a 2 cm edge margin, checked against every canonical road triangle before writing, and emitted in streamed tile 39. Their elevations come from the maximum existing P1 height sampled at 1 m across each footprint plus 5 mm; these are engineered estimated pads, not surveyed terrain. Existing terrain normals and all road meshes remain unchanged. P4 mesh geometry and the time/camera mapping remain unchanged.

`gold_coast_broadwater_s19_ground_r16_luna6` reports 13/13 Sky and 15/15 Chapel actual mesh/grid base samples covered, with 5 mm support gaps and no penetration. P4 validation is valid; P0–P6 validators and package integrity pass. The full package remains blocked only by the frozen 0/24 visual acceptance checklist; this local change does not adopt the diagnostic +294 m time shift or claim S19 visual acceptance. Native same-camera r13/r15/r16 comparisons, fixed-source times, ±20 m guards, S18/S20 guards, hashes and the precise tree-removal record are in [`s19_ground_r16_luna6`](../export/gold_coast/review/s19_ground_r16_luna6/review.html). Rebuild with `python3 export/gold_coast/review/s19_ground_r16_luna6/build_candidate.py`; then run `python3 -m unittest tools.test_scene_package tools.test_package_assets` and `python3 tools/validate_package.py export/packages/gold_coast_broadwater_s19_ground_r16_luna6`.


## S19 preview material repair r26 (2026-10-24)

Luna 6 corrected the shared Godot preview adapter: unrecognized package material names now retain their imported PBR material instead of receiving the generic near-black fallback. This fixes the material mismatch on r25's grass-colored `support_skirt`. The r26 review-only package is byte-identical to r25 except for the manifest package id; every route, road, terrain, structure, vegetation and environment file is unchanged. Prior r13/r15/r16/r25 packages are preserved.

Native Metal 1920×1080 captures cover three identical-camera chapel detail views and four route guards. The support side is now green, but its long straight raised boundary remains conspicuous. The scoped material correction is retained; the edge shape and whole-scene source similarity are not visually accepted. The final Python suite passes 181 tests, and the new material regression plus existing sand/PBR/camera checks pass. Seven package data/integrity stages validate; overall validation remains NOT VALID solely because frozen visual acceptance is blocked (0/24 unchanged).

[New before/after gallery](../export/gold_coast/review/s19_support_edge_r26_luna6/review.html) · [Independent parent review and continuation](../export/gold_coast/review/s19_support_edge_r26_luna6/parent_review.md). Frozen sources, RED/GREEN evidence and test logs are in that local review folder. Next: resolve the visible platform-edge/ground transition while preserving road physics and supported building bases. No commit or external release.


### Sol review decision after r26 (2026-10-24)

Sol retained the local material correction and changed the next priority to S19 time-to-station and camera/landmark calibration. Original 1305/1310 frames still disagree with the render's chapel projection and surrounding spatial structure; the local +294 m mapping is diagnostic and unadopted. Resolve the approach/pass/clear sequence, S18/S20 transitions and suspected edits without changing canonical route/grade or existing geometry, then revisit near-road structure and the platform edge from calibrated source-visible views. This supersedes the earlier immediate platform-edge recommendation. [Sol review](../export/gold_coast/review/s19_support_edge_r26_luna6/sol_review_20261024.md) · [Next bounded task brief](../export/gold_coast/review/s19_support_edge_r26_luna6/next_task_brief.json). Review-only decision; no new development dispatched.


## S19 source segmentation and camera diagnostic r27 (2026-10-24)

Luna 6 prepared a bounded calibration probe; Sol independently verified two hard cuts at source PTS78445367/60000=1307.422783s and80992912/60000=1349.881867s. Original adjacent frames jump from chapel approach to wall-side path, and later from waterfront plaza to another lawn-side path. Source time must be segmented at these edits; it cannot impose continuous travel or camera constraints through them. The physical route remains unchanged.

Nineteen selected native1920×1080 Metal captures compare the +294m/FOV75 baseline, FOV55 control and a shared pre-cut affine6m per source-second/FOV40 diagnostic, with identical S18/S20 guards. Two preliminary post-cut captures are retained as superseded. The width proxy improves but image placement and cupola/facade end ordering still disagree. A projection-only180°heading test reverses the cupola end but shifts actual asymmetric base coverage and does not resolve the full image. Sol retains the cut evidence and rejects calibration adoption; no source speed is treated as physical riding speed.

All prior r13/r15/r16/r25/r26 packages and production inputs are byte-identical. No new scene/package was promoted; whole-scene acceptance remains blocked. Next: establish source-visible chapel end and the actual park path branch for each shot before more time/camera fitting; validate actual grounding/clearance before any later transform change. [Original/native comparison gallery](../export/gold_coast/review/s19_calibration_r27_luna6/review.html) · [Sol review](../export/gold_coast/review/s19_calibration_r27_luna6/sol_review.md) · [Next bounded task](../export/gold_coast/review/s19_calibration_r27_luna6/next_task_brief.json). No commit.


## Autonomous run 1 — r28 cupola end retained (2026-10-24)

Sol now controls Luna 6 under the user's authorization to continue until token/account limits, with brief per-run summaries. r28 moves only the chapel cupola to the end opposite the entrance/ramp through an optional shared asset parameter. The building base and transform, route, road, terrain, physical grade and all other placement remain unchanged. Sol retained the local repair after17 native captures and182 passing Python tests. Full scene visual acceptance is still blocked. [Latest local candidate review](../export/gold_coast/review/s19_chapel_orientation_r28_luna6/review.html).

Run2/r29 is dispatched: source-backed S19 paved/parking foreground, bounded vegetation exclusions if supported, and a separate copied preview surface-override input where necessary. [Autonomous continuation state](gold_coast_autonomous_progress.md) records the active worker, input/candidate paths and independent global source-cut scan. No commit or publication.


## Whole-video edit registry — Sol (2026-10-24)

**2026-10-26 supplement:** [`data/gold_coast_source_transitions.json`](../data/gold_coast_source_transitions.json) adds a full-resolution observed cross-dissolve at1635.000033s and terminal fade-to-black. S22/S23 fall in different filmed segments despite both being inside old hard-cut intervalshot16. Sampled1634/1636frames bound the dissolve;1813is visible,1814fading,1815black. Exact transition endpoints and source-to-world mapping remain unknown. Do not infer riding time from full video duration or interpolate station through this dissolve. Private evidence: `export/gold_coast/review/shore_profile_source_r37_sol/parent_review.md`.

Sol screened the private original at160×90, then reviewed five full-resolution decoded frames around each candidate. Fifteen observed hard edits are confirmed; every before/after pair is adjacent at1001/60000s. The new upstream authoring record [`data/gold_coast_shots.json`](../data/gold_coast_shots.json) records exact PTS, source/frame hashes,16 source intervals and the source-time membership of all24 checklist frames. Evidence and the interval table are in [`global_shot_segmentation_sol/sol_review.md`](../export/gold_coast/review/global_shot_segmentation_sol/sol_review.md).

This is source segmentation, not a new route or camera calibration. The screening may miss other edits; omitted travel distance and individual shot-to-world mapping remain unresolved. Physical canonical route, frozen estimated views and acceptance are unchanged. Private source frames remain review evidence only.


## Autonomous run2 — r29 diagnostic retained, material edge rejected (2026-10-24)

Luna built the bounded S19 parking/service apron and exact8 conflict removals with shared semantic/P3 remapping. Sol independently confirmed all route/road bytes, terrain shape/attributes/triangle coverage and remaining instance transforms are preserved.185 Python tests and7 technical validation stages pass.20 new same-condition native comparisons expose long triangular grass/asphalt fingers from centroid-only material classification, so Sol did not promote the candidate; r28 remains the local retained base. [Native gallery and Sol decision](../export/gold_coast/review/s19_paved_approach_r29_luna6/review.html). Run3/r30 is dispatched for exact material-boundary clipping with original terrain surface preserved.

Sol also rendered24 frozen world views and investigated3 overhead/3 spatial-stream controls. The repeated large P2 gap is missing parallel street/parking corridors. AtS05, a thin road-edge hole vanishes when the geographically adjacent return-pass road is loaded; the station-only preview stream conflicts with all-traversal terrain clipping. Full-spatial scatter duplicates traverse-authored vegetation/buildings and is rejected; a separate geometry-only spatial-neighbor fix is warranted. S22/S23 shore spikes remain an independent issue. [Whole-world inventory and diagnosis](../export/gold_coast/review/world_inventory_r28_sol/sol_review.md). Frozen source calibration and all24 visual acceptance items remain unaccepted. No commit.


## Autonomous run3 — r30b exact apron boundary retained (2026-10-24)

Sol retained r30b after20 new native1920×1080 comparisons,188 passing Python tests and independent frozen-package/instance/surface audits. It removes r29's grass/asphalt fingers using shared opt-in exact clipping; legacy default remains unchanged. All61 existing road GLBs, route/grade, structures, environment and retained object transforms are unchanged. Exactly8 apron conflicts removed. New terrain vertices remain on original faces within2.46e−7m; projected coverage differs by at most0.001137m² per changed tile from serialization. Earlier invalid/lossy r30 variants remain rejected diagnostics. [Latest gallery and audit](../export/gold_coast/review/s19_paved_boundary_r30b_luna6/review.html). Full scene acceptance remains0/24, package overall NOT VALID.

The geometry-only spatial-stream prototype fixes S05's blue gap but overlays S20 asphalt with counterpart concrete; radius defaults0 and the prototype remains unadopted. Next priority is P0 shot12/13 corridor registration using multiple original frames and mapped fixed correspondences. A concrete Luna brief is saved but not dispatched: the goal reported usageLimited at closeout. [Continuation state](gold_coast_autonomous_progress.md). No commit or publication.


## User-triggered run4 — r31 path evidence and r32 ownership repair (2026-10-25)

Sol/Luna resumed after the user's explicit continuation. r31 freezes exact shot13 frames and the surrounding cached OSM map; the Mitchell Park / Marine Parade neighborhood is plausible but the branch, source camera and station remain unregistered. The frozen S20 route is parallel to candidate Marine Parade, while the late original frames approach a transverse road; earlier route bends and shot-local time offsets remain viable. [Evidence gallery](../export/gold_coast/review/s20_corridor_registration_r31_luna6/review.html) · [Sol decision](../export/gold_coast/review/s20_corridor_registration_r31_luna6/parent_review.md). All280 retained package files remain unchanged.

Independent projection finds291m of S20 almost coincident with S05 but with conflicting concrete/asphalt labels. This confirms the separate renderer ownership issue. Luna r32 is dispatched for opt-in geometry-only neighbor loading that preserves active roads and masks only covered same-level extra fragments, including separate-height crossing tests. Default radius remains0 until Sol native review. No physical-route or grade edit, commit or publication.


## r32 rejected; r32b opt-in repair retained (2026-10-25)

Sol inspected52 newr32 native images and rejected it: neighboring terrain coveredS07/S08 water andS20 kept light road fragments. r32b instead loads neighboring roads only, clips in a per-triangle local frame, and interpolates output back into original mesh-local positions. This addresses the measured float32 world-coordinate failure without changing physical package data. The display-only ownership tolerance is explicitly0.35m based on the sampled repeated-profile discrepancy; it does not correct route elevation or identify all physical road levels. Different-height3m crossing fixtures pass.

26 newr32b native images use the same24+2 views, frozen baseline26 and copiedr29 appearance. Sol confirmsS05 edge gap filled, S20 conspicuous central/tail overlay removed, and water preserved.11 clean Godot checks and all280 unchanged package hashes verified. [Latest r32b gallery](../export/gold_coast/review/spatial_road_ownership_r32b_luna6/review.html). Source path/time/camera registration and full scene acceptance remain unresolved.

Default radius stays0: controlled headless S20 jump is still2166ms (r32:4628ms; unchanged membership0.121ms), not an FPS claim. An isolated exact-AABB query probe preserves mesh bytes and improves latency further; Sol authorized its boundedr32c integration/fixture. Native review follows source freeze. No commit/publication or physical grade change.


## r32c integrated renderer retained (2026-10-25)

Sol inspected26 new native1920×1080 views against26 frozenr32b references; S05 edge repair, S20 active asphalt and S07/S08 water survive.11 clean parent Godot checks pass; all280 r30b package files remain identical. Stored exact-AABB filtering removes91.5% of candidates in the fixed tile11/40/41 probe while preserving emitted mesh arrays/attributes/indices exactly there. Controlled headless S20 jump falls4627.811→2166.289→1605.348ms forr32/r32b/r32c; unchanged membership0.130ms. Single jump wall-time is not FPS. Retain opt-in only, default radius0; no physical route/elevation/grade change. [Latest r32c gallery and parent audit](../export/gold_coast/review/spatial_road_ownership_r32c_luna6/review.html).

Full scene acceptance remains0/24 / NOT VALID. Source shot13 path/time/camera identity remains unresolved. Existing Luna6's nextr33 task is a read-only P0 provenance audit of repeated-route profile/material inconsistencies; it does not authorize welding, smoothing or visual elevation adjustment.


## r33 provenance evidence retained (2026-10-25)

The canonical OSM path contains243 consecutive reversed nodes; the S20 tight-XZ overlap is291m with section-estimated asphalt/concrete conflict. The route builder copies video-section labels rather than OSM surface tags. Historical cached OSM concrete tagging is a separate source, not filmed-surface confirmation. The largest0.321282m profile discrepancy occurs before S20; exact S20 normal difference is0.000133m andtail10340 is0.052964m. Raw historical DEM/filter/bridge inputs are absent from the frozen input set. Parent verified14 input hashes,4 deterministic outputs,413 CSV rows, exact projections and all280 unchanged package files. [R33 report](../export/gold_coast/review/revisited_route_provenance_r33_luna6/README.md). No physical grade/material correction or shot13 registration adopted. Luna's boundedr34 followup searches local existing provenance only.


## r34 local recovery and r35 P1 attribution (2026-10-25)

R34 recovers the final alignment-profile→route link:13,106 stored elevations match interpolation/rounding exactly. Historical Terrarium/raw sampling/filter/bridge inputs and full OSM network identity remain missing; partial review OSM covers142/405 unique route nodes. Physical route/grade remains unchanged.

Sol rendered12 native views (4fixedcameras×3modes) to attribute S22/S23 shoreline spikes. The silhouette persists within owning tile46/49 when other terrain is hidden and when materials are replaced with flat tile colors. This establishes a local P1 geometric contribution; the precise generation mechanism still needs a failing fixture. [Controlled shoreline attribution](../export/gold_coast/review/shoreline_owner_r35_sol/review.html). The separate landwardS22 blue hole may be protected nonlocal-road clearance and must not be filled from these observations. Luna's boundedr35 task is source/triangle diagnosis before an opt-in shared terrain fix. All280 base package files and P0 physical data remain unchanged; full source visual acceptance0/24 remains unresolved.


## r35b round closed — technical pass, shoreline boundary gate fails (2026-10-26)

Sol inspected36 new native1920×1080 comparisons against36 frozen references. Shared bounded waterline anchors and exact sand classification remove S22's offshore triangle and S23's central fans. The candidate nevertheless remains unadopted: four boundary guards reveal abrupt waterline-width steps at tile49's legacy neighbors, despite geometric seam gaps below0.205mm. A cross-section seam pass does not establish a continuous waterline silhouette. [Candidate gallery and Sol decision](../export/gold_coast/review/coastal_sampling_r35b_luna6/review.html).

All10,040original grid positions and all route/road/grade/instance data remain unchanged; serialized faces are finite and upward.154relevant Python tests and7technical package stages pass; material/envelope audit reruns byte-identically (44,533centroidchecks,0mismatches).280candidate files/8snapshots verified, native source/package hashes unchanged. Existing64structure ground-support reports reproduce base bytes; point-anchor regression is0/2413, with full-support scope limits documented.

Retained base remainsr30b plus opt-inr32c renderer. Full source acceptance0/24 remains unresolved. Next run must treat the connected shoreline and shared boundary contour consistently while retaining all prior repairs. The user requested finishing this round; next brief is saved, not dispatched. No commit/publication.


## r36 connected shoreline retained locally (2026-10-26)

The new local package base is `gold_coast_broadwater_coastal_sampling_r36_luna6`, retaining r30b's prior repairs. Roots cover11206.2812–13104.7827m across tiles44–52; both copies of each active shared boundary use analytic water-level anchors. Root generation is scoped independently of existing coast-height profiles. All9defaultterrain/roadbytegatespass; originalgrid/reach/P0data and every instance remain unchanged.

Sol inspected45newnativepairs against45base references, including all9affected boundaries, profile transitions and endpoint, plus directr35b→r36proof. The rectangular48|49/49|50steps are removed and not shifted downstream. Measuredone-metrewaterlinevariation falls3.360→.0038099m and4.832→.0062075m.42,280originalgridrecords retain exactpositions;0nonpositivefaces;156relevantPythonchecks/7technicalstagespass.658changed-ownerpointanchors among2413storedanchors show0supportchange>.1mm; currentrigid/linearvalidationreports reproducebasevalues. Source/packagehashesunchangedduringnativecapture. [Latest gallery and Sol review](../export/gold_coast/review/coastal_sampling_r36_luna6/review.html).

Fullscenevisualacceptance remains0/24 / NOT VALID. Existing authoredprofilecorners and a smallterminalspur/wateropening remain separate work; no measured shoreline or source registration was newly adopted. Radiusdefault0 and generator opt-in defaults remain unchanged. No commit/publication.


## r37 attribution and r38 capped-waterline repair retained (2026-10-26)

最新局部版本為 `gold_coast_broadwater_capped_waterline_r38_luna6`。原生可見性控制與固定像素射線確認終點白色尖角屬於第52塊岸沙，而非交會道路；完整生成流程證明它已存在於最初的單邊水線網格，並非道路裁切或地形限制處理新增。新共用選項在原範圍內把水線接到收縮邊界，修正第49/52塊共6處過渡，保留全部原始網格、道路、坡度、水位及既有物件。

Sol 審核20組原生固定視角，終點長尖角與第49塊細小白色突刺消失，檢查視角未見既有道路或跨塊銜接退步。159項Python測試及7個技術驗證階段通過；42,280個原始網格記錄位置完全一致，2,413個物件錨點檢查未見支撐高度退步。套件僅清單與49/52地形共3檔變動，r36完整保留。[修正前後與Sol審核](../export/gold_coast/review/capped_waterline_r38_luna6/review.html)。

藍色開口仍是重複XZ路廊的地形覆蓋／歸屬問題；目前證據不足以直接載入起點舊地形填補。影片1635秒淡化轉場與結尾黑畫面已另存來源證據，不據此更改物理路線。整體來源驗收仍為0/24 / NOT VALID；不宣告場景完成，未提交或發布。

## r39 覆蓋診斷（2026-10-26 晚間）

保留 r38，本輪沒有場景修改。Sol / 同一 Luna6 的八個取樣射線及全 53 塊序列化 P1 掃描，區分出兩類問題：終點開口有未載入的第 00 塊地形；第 49 塊的兩個水面 XZ 取樣點，在整包 P1 中皆沒有水平覆蓋。3/5/8 m 路緣窄帶不能完整修復，未採用部分填補。正常 Godot 環境重播 byte-identical，兩個 280 檔案場景包與五個生產來源雜湊未變。

審核與圖像：`export/gold_coast/review/shore_coverage_r39_luna6/parent_review.html`。另取得目前公開 OSM 海岸資料並保留授權、來源時間與原始回應；四個取樣點的局部陸側關係只作補充證據，不能視為影片日期／潮位／相機配準。後續 r40 追查第 49 塊缺口出現的生成階段。整體驗收仍 0/24 / NOT VALID，未提交或發布。


## r40 初始地形範圍追因完成（2026-10-26 晚間）

第49塊用完整r38參數重建的GLB位元組一致，兩個缺口取樣點在最初依曲率限制的地形帶即無覆蓋。Sol獨立重建5249頂點／9452面的初始網格再次確認，未歸因於後續材質切割。審核：`export/gold_coast/review/shore_domain_r40_luna6/parent_review.html`。失效探測版本與有歧義的後期bank-call列表保留但排除；14個worker artifact/input雜湊及五個生產來源一致，兩包各280檔案未變。r41僅試驗局部補集、真實邊界與高度支持，尚未修改生產程式或場景包；保留r38，整體驗收仍0/24。


### 2026-10-27 — R42 local infill returned for correction

R38 remains the retained package. R42 appends estimated tile49 land over the two bounded sampled gaps; original P0/P1 attributes and faces are preserved,161Python tests pass, and Sol temp replay reproduces280files exactly. Native22matched views show the large holes reduced but oblique arcs/lines/arrow remain. Whole-package temp validation fails251terrain vertices inside road band; lower stages are gated, not accepted. The initial R42b trace points to local S/U metadata at clipped road edges; original-world affine inversion versus nearest-edge snapping remains under review. Seven raw/native rays also distinguish unloaded foreign03 coverage and raw/import discrepancy. No physical route/grade change, no whole-scene acceptance, no commit/publication. Evidence: `export/gold_coast/review/shore_infill_r42_luna6/parent_review.md`.


### 2026-10-27 — R42c retained as a partial P1 improvement; R44 dispatched

Local base is now `export/packages/gold_coast_broadwater_shore_metadata_r42c_luna6` (manifest79d448bf…/49b6147616…). Parent temp replay reproduces280files exactly. All originalR38attrs/faces/route/P0 remain; corrected297newterrainS/U pairs clear251road-band warnings without moving geometry or relaxing validation.163Python tests,7technicalstages, precision fixture and3parentnativechecks pass. Sol inspected22matchedForward+1920×1080views and2full-resobliques: large openings reduce, onefine line disappears after precision-preservingP0/P1import, butbluearcs/arrow/otherholes remain. Partialretention is not whole-shoreline orsource acceptance; scene0/24NOT VALID. ExactR42geometryidentity permits reuse ofitsintersection/anchor diagnostics, with nonzeroquantizationledger retained. CpreviewSHA90faa94d… preservesrawP0/P1coordinates moreclosely; otherassets/radiusdefault unchanged. Allsources/280candidatefiles stableacrosscapture, frozen snapshots saved. Gallery: `export/gold_coast/review/shore_metadata_r42c_luna6/parent_review.html`.

SameLuna6 proceeds to R44: same2ROIs and immutableR38 baseline, optional explicitselectedP1owners47–52, all53P0still excluded, currentP1support ratherthanforeign03P1boundaries, noforeignS orROIexpansion. ExpectedextraP1duplication.660616m² isexplicit, notglobalterrainloading. Newpackage/authoring/reviewfolder only; Cretainedpendingnativeacceptance. No commit/publication or physicalroute/grade edit.


### 2026-10-27 R44 partial shore continuity retained

Sol retained `export/packages/gold_coast_broadwater_visit_shore_r44_luna6` after166Python tests,7technical stages,280-file exact replay and22matched native pairs. Same2ROIs, selected current-visit P1/all-package P0; originalroad/grade unchanged. Upper sampled arc closes and lower traces shrink; fine traces/arrow, later49 andterminal openings remain. Whole-scene acceptance stays0/24NOT VALID. Frozen decision/gallery: `export/gold_coast/review/visit_shore_r44_luna6/parent_review.md` and `parent_review.html`. Same Luna6 now maps R45 residuals read-only before another bounded repair.


### 2026-10-27 R47 late shoreline partial repair retained

Two late tile49 holes are filled in24 matched native views, including2 close obliques. R47 preserves existing terrain prefixes, P0 road/route/grade and adds bounded estimated land supported by interpolated source-edge samples;145 scene tests and7technical stages pass,280-file independent replay matches. Fine blue traces, the prior arrow seam and terminal opening remain. Whole-scene acceptance remains0/24 NOT VALID. `export/gold_coast/review/edge_support_r47_luna6/parent_review.html` is the before/after gallery; same Luna6 is diagnosing residual seams in R48.


R52 follow-up: R47 remains provisional. Of95 pre-emission IDW vertices,11 use samples spanning at least5m station, with maximum mixed-sample Y spread0.941m. This is an indicator requiring branch-aware review, not proof of wrong height. Details: `export/gold_coast/review/shore_idw_r52_sol/parent_review.md`.
