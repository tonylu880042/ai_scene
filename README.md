# Coastal Virtual Run (Godot 4)

First-person virtual-run scene for treadmill sessions: a generated coastal harbour path at a fixed pace
(6:00 min/km), with the route's elevation following one of 12 treadmill programs (`programs.json`).

## Run
1. Fetch the CC0 assets (Poly Haven models and textures, ~100 MB): `python3 tools/download_assets.py`
2. Open the folder in Godot 4.3+ (developed on 4.7) and let it import, or from a terminal:

```bash
godot --path . -- --course=speed_lab
```

Options after `--`: `--course=<name>` (see `programs.json`), `--start-min=N`, `--quit-at-end`, `--no-hud`
(scene only: no text, minimap or gate banner text).

Keys: Tab auto/manual run, WASD + mouse in manual mode, F1 hide HUD, F11 fullscreen, Esc release mouse.

## Layout
- `scenes/` - `MainScene.tscn` (coastal harbour), `MainScene_alpine.tscn`, `MainScene_garda.tscn` (Lake Garda), `Player.tscn`;
  `scenes/legacy/` holds the earlier prototype stages (kept for reference, no longer maintained).
- `scripts/` - `route.gd` builds the route, terrain and road from a program; `course_setup.gd` applies the scene template
  and time of day; `FoliageSpawner.gd`, `Boardwalk.gd`, `Buildings.gd`, `AlpineProps.gd`, `Pedestrians.gd`, `Gates.gd`
  dress the route; `hud.gd`, `minimap.gd` are the HUD.
- `shaders/` - terrain, trail, grass, water, sky and cloud shaders.
- `data/` - `programs.json` (treadmill programs), `courses*.json` (scene template per course), `garda_sections.json`
  (Garda scene sections and landmarks along the reference video).
- `tools/` - asset/terrain fetchers, Unity export (`export_unity.gd`, `unity/`), course recording and older experiments.
- `assets/`, `video/` (private references) and the outputs `export/`, `export_unity/` are not in git.

Assets: Poly Haven (CC0).

## Alpine scene extras
- Real backdrop terrain: `python3 tools/fetch_real_terrain.py` (default: Jungfrau region, 24 km). Attribution
  required: elevation from AWS Terrain Tiles (https://registry.opendata.aws/terrain-tiles/, see its source
  attributions); orthophoto (c) swisstopo (SWISSIMAGE).
- HDRI sky: Poly Haven `kloofendal_48d_partly_cloudy_puresky` (CC0), 8K `.hdr` in `assets/hdri/` (fetched by `tools/download_assets.py`).
- Film-quality recording: `EXPORT_EXTRA=--hq tools/export_course.sh alpine summit 10 2`.

## Col des Saisies — 影片重建環境

**當前進度：R36全路線本地候選版。** 已完成約14.615公里巡覽、起終點標示與自由創作山村收尾，原生接地／GPU／巡覽／快取一致性檢查通過。雙擊[固定版巡覽](export/saisies/review/round36_release/run_review.command)或[直接看終點](export/saisies/review/round36_release/view_finish.command)。見[全線原片與實機對照](export/saisies/review/round36_release/review.html)、[本輪結果與限制](docs/saisies_release_progress.md)。S04–S18的整體地形、道路投影與冠層仍待修正，不宣稱正式發行或全線80%。下方逐項S03／S04內容為歷史紀錄。

**S01已依使用者決定接受並封版。** 最後一棟中景木屋於stage15完成原生驗收；[S01封版對照與固定來源](export/saisies/review/round15_s01/s01_final_review.html)。每次只完成一項，維持約80%相似目標。 **S02也已由使用者接受並封版**，見[S02實拍與接受紀錄](export/saisies/review/round16_s02/review.html)。S03本輪路口展寬與弧形護欄已完成單項驗收，見[S03原片／實拍對照](export/saisies/review/round17_s03/review.html)；完整S03仍待逐項改善；[R18左側咖啡館下沉修正](export/saisies/review/round18_s03_cafe/review.html)已完成原生驗收。 [R19草坡與地表](export/saisies/review/round19_s03_ground/review.html)單項完成，S01/S02像素回歸一致。[R20纜車設施](export/saisies/review/round20_s03_lift/review.html)單項完成，含雙纜線、三張空吊椅及支柱；[R21路口方向牌](export/saisies/review/round21_s03_signs/review.html)已完成本輪實作與原生檢查，位置比例仍有差異；[R22右側路邊花槽](export/saisies/review/round22_s03_flowers/review.html)本輪實作與原生檢查完成；[R23左側林緣](export/saisies/review/round23_s03_forest/review.html)改善保留，已完成原生GPU、樹根抽查及S01/S02回歸；仍有密度與色調差異。標線依使用者指示略過，不再排入後續工作。[R24右坡林帶](export/saisies/review/round24_s03_right_forest/review.html)本輪改善保留，S01/S02與S03左側區域像素回歸一致。右坡遠景屋群也依使用者指示略過。[R25咖啡館旁兩棵針葉樹](export/saisies/review/round25_s03_cafe_trees/review.html)本輪改善保留，主圖／側移／近景完成；S01像素一致，S02僅低幅差異，細節見[本輪紀錄](docs/saisies_s03_cafe_trees.md)。[R26咖啡館露台橘紅遮陽傘](export/saisies/review/round26_s03_cafe_parasol/review.html)本輪改善保留，原生主圖／側移／近景及接地檢查完成，S01/S02像素完全相同。使用者改以整體場景優先。[R27路口鋪面與出口漸縮](export/saisies/review/round27_s03_junction_shape/review.html)已消除右側大草楔、完成原生與S01/S02像素回歸；道路中心仍偏左。遠山亦依使用者指示略過。後續整體候選為道路材質灰度、顆粒與裂紋尺度。S01樹林與餐廳保持固定，不再追加細節。

第十四輪已補建路口低商店、纜車旁小咖啡館並修正木屋接地位置。新增 **[固定R14快速啟動器](tools/run_saisies_geo_fast.command)**：雙擊或執行 `tools/run_saisies_geo_fast.command`，以30km/h巡覽完整景物。原生首張完整畫面量測3.39秒（既有匯入／OS快取；不含引擎初始化），6487棵樹完整保留；從頭程序生成的純運算優化另由139.6秒降至95.5秒。啟動器還原持久固定來源，不混用尚未驗收的R12映射。

**視覺仍退修：本輪村落0/3通過，既有geo五視點仍0/5。** [8張原片／完整場景對照](export/saisies/review/round14_final/review.html)、[本輪修正、量測與限制](docs/saisies_revision_round14.md)、[技術驗證結果](export/saisies/review/round14_final/technical_results.json)。以下保留各輪與v2的歷史重現方式。


第十三輪已修正geo版未整合既有村莊的退步：恢復餐廳、旅館、店面與花槽，改進路口木屋及背景多面外牆。固定版4張完整場景實拍、2項房屋幾何檢查完成；影片完整畫面仍0/3通過（另T0為0/1），保留修正並繼續退修。見[房屋修正紀錄](docs/saisies_revision_round13_houses.md)、[起點對照](export/saisies/review/round13_houses_refined/S01_comparison.png)及[路口對照](export/saisies/review/round13_houses_refined/S02_comparison.png)。本輪固定版採R11基底，未混入工作區尚待驗證的R12時間映射。

第七輪保留起點街景／花槽／估算車道視點修正，已做6個原生視點與8項技術檢查，完整畫面仍未通過；遠山候選退修並撤回。見[第七輪紀錄](docs/saisies_revision_round7.md)及[最新起點對照](export/saisies/review/round7_retained/S01_comparison.png)。既有烘焙檔仍是all18_v7，尚未包含本輪街景；目前修改請以以下來源場景檢視。

舊版v2開發入口為 `scenes/MainScene_saisies_v2.tscn`。這是獨立的純 3D 環境場景，以 `video/Descending Col des Saisies _ French Alps #3_1080p.mp4`
為視覺依據。重點為夏季草甸、混合樹林、山坡與谷地、村鎮房屋、柏油道路、石砌擋土牆、
公路護欄及遠山；不需要人物或車輛。相機沿道路巡覽，方便檢視全線景觀。

```bash
# 開啟場景；亦可在 Godot 開啟此場景後按 F6
godot --path . res://scenes/MainScene_saisies_v2.tscn

# 從草甸、石牆、密林、岩壁、山谷村落檢查
# --start-km 可使用任意 0–14.8 的數值
godot --path . res://scenes/MainScene_saisies_v2.tscn -- --start-km=2.3

# 產生巡覽截圖後退出
godot --path . res://scenes/MainScene_saisies_v2.tscn -- --start-km=8.8 --capture=/tmp/saisies_forest.png --capture-after=2 --quit-after=3
```

路線資料：`data/saisies_route_v2.json` 覆寫共用 `data/saisies_route.json`；18 個驗收視點由 `data/saisies_scene_map.json` 對應。影片分析與可信範圍：
[`docs/saisies_reconstruction.md`](docs/saisies_reconstruction.md)。v2 全長約 14.8 km，起點估算 1,608 m、末段約 689 m，淨落差約 919 m；數字來自
影片速度及海拔 HUD 的推估；彎道平面、建物配置與山形是視覺重建，沒有 GPS/DEM 校正。
舊有場景與專案預設啟動場景保持不變。

路段預覽里程：0.1 km 山頂村鎮、2.3 km 草甸與遠山、5.8 km 擋土牆與護欄、
8.8 km 混合森林、10.4 km 岩壁、14.4 km 山谷村落。

若要直接在 Godot 3D 編輯器中檢視、調整物件，先把程序環境烘焙成一般場景：

```bash
godot --path . --script res://tools/bake_saisies.gd -- --scene=res://scenes/MainScene_saisies_v2.tscn --output=res://export/saisies/SaisiesEnvironment_v2.scn
```

烘焙請使用原生渲染；工具會拒絕 headless／Dummy 模式，避免 MultiMesh 樹木實例資料在存檔時遺失。已用原生讀回圖片確認目前烘焙檔保留森林。

再開啟 `export/saisies/SaisiesEnvironment_v2.scn`（原生壓縮場景，可直接於 Godot 編輯）。這份烘焙場景包含實際道路網格、樹木
MultiMesh、建築、護欄和山體，不依賴執行期生成器；`export/` 沿用既有 git 忽略設定。
原始 `MainScene_saisies_v2.tscn` 則會按資料重新生成環境。

```bash
# 驗證路線、環境物件、護欄方向與長度
godot --headless --path . --script res://tools/verify_saisies.gd

# 驗證樹木資產與全路靜態地形
godot --headless --path . --script res://tools/verify_saisies_trees.gd
godot --headless --path . --script res://tools/verify_saisies_landscape.gd
```


**驗收狀態（2026-10-17）：退修，尚未達到影片相符標準。** 開發者測試通過僅代表場景可建立與巡覽，不能當作視覺驗收通過。

上一個涵蓋全18視點的固定版本為 `all18_v7`：18/18原生圖片正常輸出，0/18達到完整影格要求。相機巡覽採相同驗收pose插值；[第六輪發包與退修紀錄](docs/saisies_revision_round6.md)保存逐次檢查與撤回的岩面方案。

- [18 段場景文字與原片影格](docs/saisies_acceptance_frames.md)
- [主代理的圖片對照、退修項目與判定](docs/saisies_visual_acceptance.md)
- [完整分鏡與段落補充](docs/saisies_scene_storyboard.md)

重現固定驗收視點（原生視窗輸出 1920×1080；`--dry-run` 僅檢查載入，不輸出圖）：

```bash
godot --path . --script res://tools/capture_saisies_scene.gd -- --scene-id=S01 --output=/tmp/saisies_S01.png
```

### 舊版全路線空照與高程

以下是 v1 留存的全線檢視；不代表 v2 最新場景或視覺驗收通過。

`export/saisies/previews/` 保存斜向空照、俯視圖、原始無高亮空照，以及影片估算的高程剖面。
空照中的橙線為檢視路徑用的暫時輔助標示，不會寫入正式環境場景。

```bash
godot --path . --script res://tools/capture_saisies_aerial.gd -- --view=oblique --highlight-route --output=res://export/saisies/previews/aerial_oblique.png
godot --path . --script res://tools/capture_saisies_aerial.gd -- --view=top --highlight-route --output=res://export/saisies/previews/aerial_top.png
```

省略 `--highlight-route` 可輸出沒有輔助線的原始空照。工具使用已烘焙的環境，會暫時關閉距離裁切與霧，
讓全路線和樹木在高空視角可見；不修改源場景或烘焙場景。

### 獨立地理場景（實驗版，尚未視覺驗收）

`scenes/MainScene_saisies_geo.tscn` 使用公開道路、地形及林區資料建立空間基底；時間與道路里程對應仍為估算。與既有 v2 分別保留，未取代預設展示或 v2 烘焙。

- [最新地理場景原片對照與退修](docs/saisies_visual_acceptance.md)
- [全線斜向空照](export/saisies/review/round8_geo_final/aerial_oblique.png)
- [第九輪：近路高程、森林與護欄](docs/saisies_revision_round9.md)

第八輪六個抽驗視點均未達原片要求；建物白模、近路森林、岩壁／石牆與專屬設施仍需重建。

第九輪已完成近路RGE高程、近路森林與護欄高度修正；[最新四張原片對照](export/saisies/review/round9_canopy_final/four_view_comparisons.jpg)仍0/4視覺通過。[第十輪紀錄](docs/saisies_revision_round10.md)已新增局部岩壁、樹根接地、林緣與候選相機；[最新五張對照](export/saisies/review/round10_integrated/five_view_comparisons.jpg)仍0/5視覺通過，9/9技術檢查不能取代畫面驗收。[第十一輪](docs/saisies_revision_round11.md)已補S09低石牆、草坡細節與右林遮擋；[最新五張對照](export/saisies/review/round11_reviewed/five_view_comparisons.jpg)仍0/5通過，另補326／334秒亦退修。本輪4/4技術檢查與原生GPU檢查通過；[後續工作](docs/saisies_revision_round12.md)優先診斷連續彎序與道路投影。

影片轉場景請用 [`video-to-ai-scene`](.claude/skills/video-to-ai-scene/SKILL.md)（舊的 `video-scene-reconstruction` 與 `video-to-virtual-run` 已退役，教訓併入其 references）。
