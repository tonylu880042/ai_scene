---
name: video-to-virtual-run
description: Turn a reference running/hiking/riding video into a Godot virtual-run scene and deliver it as a Unity export (glTF tiles + instances). Builds coarse-to-fine (route, terrain, sections, landmarks, details) and stops when every section scores >= 80% on a checklist frozen from the video. Use when the user gives a video (file in video/ or a path) and asks to build a scene like it or convert it for Unity3D. Trigger words - "用這個影片建立場景", "video to scene", "虛擬跑步場景", "轉成 unity", "/video-to-virtual-run".
---

# 影片 → Godot 場景 → Unity 匯出

專案：`/Users/tunghunglu/projects/ai_scene`（Godot 4.7，`godot` 在 PATH；ffmpeg；Python 3 + Pillow/numpy）。
目錄：場景 `scenes/`、程式 `scripts/`、shader `shaders/`、設定 `data/`。

**交付物是 Unity 匯出的 zip**（`export_unity/<name>`）。Unity 端的匯入、渲染、錄影、跑者由別人負責；
Godot 錄影、web player、Blender、Runway 都不做，除非使用者要求。

**完成標準**：每一段都達到 80%（不是整部影片平均），然後停下來，交分段對照表給使用者簽核。

## 模板（從最接近的複製，不從零寫）

| 場景 | 類型 | 分段檔 |
|---|---|---|
| `MainScene.tscn` | 海港步道 | — |
| `MainScene_alpine.tscn` | 高山步道、雲海 | — |
| `MainScene_garda.tscn` | 湖岸、懸崖、隧道 | `data/garda_sections.json` + `real_shore` |
| `MainScene_winter.tscn` | 雪地公路、農舍 | `data/winter_sections.json` |
| `MainScene_weissensee.tscn` | 湖岸林道、木棧道 | `data/weissensee_sections.json` + `real_shore` |

複製成 `scenes/MainScene_<name>.tscn`，不改既有場景。**新需求一律做成共用 script 的新參數**
（`route.gd`、`FoliageSpawner.gd`、`Buildings.gd`、`Boardwalk.gd`、`AlpineProps.gd`…），
不另寫 `<name>_*.gd` 平行管線——那樣修好的東西帶不到下一個場景，Unity 匯出也不一定吃得下。

## 步驟 1：分析影片 → 分段檔 + 檢查表（一次寫完、之後凍結）

1. `ffprobe` 看長度；每 10 秒取一張做 contact sheet（3×6 格、標時間），讀完全片：
   `ffmpeg -i "$V" -vf "fps=1/10,scale=480:-1" <scratch>/f_%04d.jpg`，再用 PIL 拼圖。
2. 依環境明顯變化切段（通常 10~30 段，依影片而定）。寫 `data/<name>_sections.json`，格式同
   `weissensee_sections.json`：`video_km`、`types`（每種路段的參數）、`sections`
   （`[video_km, type, {覆寫}, "影片時間 + 畫面描述"]`）、`landmarks`（`[video_km, kind]`）。
   **一個 sections 條目 = 一個檢查段**，依順序編號 S01、S02…（地圖、截圖、對照表都用這個編號），所以分段控制在 10~30 條。
3. 每段挑一張代表原幀存成 `video/<name>_ref/S01.jpg`…（`video/` 不進 git）。
4. 寫 `data/<name>_checklist.json`：每段每層列出**從該幀看得出來**的檢查項，例如：
   ```json
   {"S05": {"time": "04:30", "ref": "video/<name>_ref/S05.jpg",
     "L0": ["先右彎再左彎"], "L1": ["山谷在右側", "對面有深色林坡"],
     "L2": ["右側金屬護欄", "左側草坡", "疏林"], "L3": ["右側一棟木造農舍"], "L4": ["白色中心虛線"]}}
   ```
   每層 2~5 項就好；看不到的不寫。**寫完給使用者看一眼，之後不能改**（不能為了過關放寬或刪項）。

影片只是私人參考：不出貨影格、不餵給生成器、不抄品牌元素。

## 步驟 2：由大到小建場景，每層過關才往下

| 層 | 內容 | 門檻 | 怎麼檢查（便宜的方式） |
|---|---|---|---|
| L0 路徑骨架 | 段落順序與長度、左右彎順序（坡度跟課表，不檢查） | 90% | `tools/plot_route.py` 俯視路線圖，不渲染 |
| L1 大地形 | 水／山谷在哪側、坡度、遠山、天空開闊或被遮 | 90% | 每段一張灰模截圖（無樹無屋） |
| L2 分段環境 | 路面、路邊（護欄／石牆／岩壁）、植被種類與密度、村落／森林 | 80% | 每段一張完整截圖 |
| L3 地標 | 主要建築與設施：有沒有、哪一側、大概多大 | 80% | 同上 |
| L4 細節 | 標線、花槽、招牌、材質、小道具 | 80% | 同上 |

- 計分：每項「符合 1／部分 0.5／不符 0」，一段一層的分數 = 得分 ÷ 項數。
- **這一層所有段都過門檻，才做下一層。** 下一層的修改若讓上一層掉分，先修回來。
- **同一層最多 2 輪修正。** 2 輪後還有段沒過：停下來，列出卡住的段和項目問使用者，不要自己繼續試。
- 遠山：`python3 tools/fetch_real_terrain.py <name> <lat> <lon> <km>` + `RealTerrain`，或湖岸用
  `tools/real_shore.py`。地理資料（OSM/DEM）只用在遠景，不拿來定近景位置——影片沒有 GPS。
- 天空：Poly Haven HDRI（`hdri_sky.gdshader`，設 `hdri_sun_u/elev`）；新 CC0 素材加進 `tools/download_assets.py`。

**L0 的彎道**：每段在 sections 寫 `"turn"`，為該段的方向變化（度，+ 左、- 右）；一段有好幾個彎就寫陣列，
例如 `{"turn": [-40, 60]}`，該段會平均切成幾個彎，每個彎頭尾曲率為 0，接得順。直路寫 0 或不寫。
只要有一段寫了 `turn`，整條路就改由 turn 決定（原本的正弦彎道停用）；完全不寫則和舊場景一樣。
載入時會印出最急的彎道半徑：小於約 150 m 時，彎內側的近景地形會摺疊，要把髮夾彎分到較長的段落。
**坡度不跟影片**，維持跑步機課表（`data/programs.json`），所以 L0 不檢查上下坡。
自我檢查：`godot --headless --path . --script tools/check_route_turns.gd`。

L0 地圖（不建地形，約 1 秒）：`python3 tools/plot_route.py res://scenes/MainScene_<name>.tscn <scratch>/route.png [course]`
——路線依段上色、標 S01…、地標 ◆，下方列出每段**實測**的方向變化（← 左 / → 右），直接對影片的彎道順序打 L0 分。
各段的起訖 s（截圖用）：`godot --headless --path . --script tools/dump_route.gd -- <scene> "" <scratch>/route.json`
的 `sections[].s0/s1`。

## 步驟 3：匯出 Unity、截圖、分段對照表

1. 匯出：`godot --path . --script tools/export_unity.gd -- --course=<c> --out=export_unity/<name>`
   （視窗模式，不用 headless；可選 `--from-m --to-m --tile-m --grass --flowers`）。
2. 每段在該段中點 s（`(s0+s1)/2`）截一張（截的是匯出結果本身，順便驗匯出完整）：
   `godot --path . --script tools/verify_unity_export.gd -- export_unity/<name> <scratch>/S05.png <s_metres>`
3. 打分寫進 `<scratch>/scores.json`：`{"S01": {"L0": [1], "L1": [1, 0.5], ...}}`，每項一個分數、順序同檢查表；
   還沒做到的層不寫。然後產生對照表：
   `python3 tools/section_sheet.py data/<name>_checklist.json <shots_dir> <scratch>/scores.json <out_dir>`
   ——每段一列：原幀｜場景截圖（`<shots_dir>/S01.png`…）｜各層分數與 ○△× 項目；印出摘要，有層沒過門檻就 exit 1。
   分數和檢查表項數對不上會直接報錯。全部段 PASS 才把 `sheet_*.png` 交給使用者簽核。
4. 打包：`cd export_unity && zip -r -q VirtualRun_<Name>_Unity.zip <name> -x "*.DS_Store"`，給使用者路徑。
   提醒 Unity 那邊：glTFast 匯入、`VirtualRunScatter.cs`（NegateX vs NegateZ）、天空盒旋轉、
   保留 `README_UNITY.md` 的 attribution。

## 已解決的坑（別再犯）

- Path3D 之後才放讀路線曲線的節點；`CourseSetup` 放第一個。typed Node export 在 instanced 場景會變 null → 用 `NodePath` + `get_node`。
- 植物、石頭離開行走面（`route.half_left/right(s)`），大石頭 2 m 以上。
- 接地取**實際顯示的地形三角形**，不是 DEM 插值；樹看根部範圍，不只看 origin。
- 離道路的距離用水平最近段（y 歸零前先確認不會選到別段道路）。
- heading 用 `atan2(-x, -z)` 時正值是左轉；用 `future_tangent.dot(current_left) > 0` 交叉確認。
- 護欄橫梁沿完整 3D 端點方向，立柱 local Y 朝上；上坡、下坡、彎道各抽查一處。
- HDRI 太陽漏進環境光 → `hdri_sky.gdshader` 的 `ambient_clamp`；HDR 貼圖要無損匯入（`compress_to=0`）。
- 相機不要 head-bob（會暈）；只留極小的 `wander_amp`/`breathe_amp`。
- macOS `sed -i` 要 `''`，改檔優先用 Python。使用者要求才 commit；不推 `assets/`、`export*/`、`video/`、`runway/`。
