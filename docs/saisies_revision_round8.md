# Saisies 第八輪：以真實道路與高程重建幾何

root 分析、Luna實作；驗收基準 `round7_retained`。本輪優先道路／山體／街區的空間關係，既有v2及烘焙不直接覆寫。原18張影片參考及文字不變。

## 目前證據與轉向

放大原片可讀到起點為「La Table de l'Olympe」及「RESTAURANT SAVOYARD」，先前Alpage／Ravoula文字判讀有誤。OpenStreetMap起點小區資料包含L'Olympe及Avenue des Jeux Olympiques（D218B）的建物與道路。原影片來源為 [SAFA Brian](https://www.youtube.com/watch?v=QzW3tZyGqRk)。

root下載公開OSM道路折線並做只讀路徑分析：起點候選(45.7577436,6.5378919)，谷底候選(45.7268413,6.5458104)，沿D218B鏈約14,583m、773個點，與影片速度／時間估算14.8km接近。這是地圖與畫面位置推定，不是影片GPS。原始ref道路中有約10–23m的roundabout/link缺口，須補取完整連接道路，不能把端點直連當精確道路。

地景診斷確定舊系統是「單一全線grade平面＋nearest-route分支＋獨立山帽＋820/1250m裁面保護」，會產生跨谷錯層和灰斜牆；不是繼續增加樹木或改Gaussian峰高就能解決。

## 本輪交付

建立獨立 `MainScene_saisies_geo.tscn`：OSM道路平面位置＋公開DEM真實山谷＋IGN正射影像作地形材質。地形仍為真正3D網格，不把影片影格貼作背景。先確認S01/S03/S05山稜／路徑及村屋關係，再增加近景細節。

### 共用座標契約

- Geographic frame metadata包含 `origin_lat/lon`、`forward_east/north`、`right_east/north`。以起點第一段道路的地理方向為forward；世界local前方為-Z、右方為+X。
- 地理ENU公尺到Godot：`x=dot(EN,right)`、`z=-dot(EN,forward)`；right=(forward_north,-forward_east)。Y以起點DEM或起點HUD標高為datum，明確記錄，不混用。
- route dataset保留每點真實累積arc length；不可為硬湊14.8km而縮放平面。原影片時間錨點先按總長比例映射，標示估算，之後用可辨識彎道／街口校正。
- DEM metadata是north-up方形，中心45.72/6.57、24km、grid769、height float32小端、影像4096。取樣用地理WebMercator座標一致映射，不能把南北翻轉或以度直接當公尺。
- 兩個元件共用 `SaisiesGeography` helper：`world_from_latlon(lat,lon)`、`latlon_from_world(xz)`、`raw_height_world(xz)`、`height_world(xz)`。第一版使用DEM本身的road altitude，HUD差異作報告，不把整個遠山拉成單一grade。
- 路面只在道路近側約8–25m做連續地形融合，禁止再次使用820/1250m寬的壓平／裁面保護去抹掉山谷。未被遮擋的地形faces必須連續，山腳不得出現天空洞。

### 分工與驗收順序

1. 資料Luna：下載工具、DEM/正射影像/來源metadata與cache。驗有限高程、tile非空、座標、hashes、出處授權。
2. Route/Camera Luna：地圖鏈整理、地理route subclass及同側polyline相機擬合診斷。保留既有API供場景模組用，不能把未配對的pixel點硬指定route s。先交可獨立檢查道路／標高／時間連續性的版本。
3. Terrain Luna：共用geography helper、DEM mesh及staging場景。先接route／terrain，不引用原片圖作材質。道路和地形使用同一高度函式；實際接地及法線/切線要驗證。
4. root：核對資料／來源／原片地標，串行native截圖。至少S01/S03/S05/S08/S09，依圖判斷，不用count宣稱視覺通過。

三位Luna共用目錄，檔案所有權另由訊息確認；不得覆寫其他代理修改。原生GPU只有root使用。headless必須指定唯一/tmp/log，完整掃描日誌並分開記錄既有macOS CA錯誤。

資料來源：[OpenStreetMap](https://www.openstreetmap.org/copyright)（ODbL）、[Terrain Tiles](https://registry.opendata.aws/terrain-tiles/)（依Tilezen各來源attribution）、[IGN BD ORTHO](https://www.data.gouv.fr/datasets/bd-ortho-r)（Licence Ouverte2.0）。採用前保存實際請求與版本，影像年份可能與原片不同。

## 固定交付與驗收結果（2026-10-18 補記）

最終道路已補入兩段實際 OSM roundabout 連接，總長 14,615.088m、1,863 個來源點。24km 地形與正射影像、240 棟 OSM footprint 白模、11,026 棵林區配置樹木及估算護欄均已串入獨立地理場景。地形包含約149萬三角形；不是視覺完成度指標。

固定來源 `/tmp/saisies_round8_geo_final` 的 S01/S03/S05/S08/S09/S13 六張與全線斜向空照均原生輸出成功；六項 headless 檢查通過。原生額外讀回驗證 11,026 個樹木 instance 及 1,772 梁／1,781 柱，確認實際 GPU transform，避免以 Dummy headless 零矩陣誤判位置。

**六張皆退修（0/6）**。起點／纜椅設施缺專屬細節；森林路段過度開闊、近路坡面過高、林木成列；石牆與岩壁缺失，護欄相對路面過低。完整六幀判定保存在 `export/saisies/review/round8_geo_final/visual_review.json`。既有 v2 烘焙 hash 維持 `70f78c4092e02fc94a1ad1093aa5c049569461a858c150a7d80f03a47dfa0142`，本輪未取代 v2。

路面目前是粗 DEM 的估算平滑／坡度限制剖面，保持 XY 與端點；這不是影片 GPS。另已下載官方 RGE 的全路中心線 1,863 點作審計，但尚未全線採用。第九輪先以兩個近路高程 patch 處理 S08／S13，避免單獨降低路面造成更大的切坡。
