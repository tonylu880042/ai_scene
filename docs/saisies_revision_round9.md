# Saisies 第九輪：森林近景與近路高程

日期：2026-10-18。root 分析與原生截圖驗收，三位既有 Luna 實作。第八輪獨立地理場景六張定點圖均未達原片要求；完整報告與凍結來源在 `export/saisies/review/round8_geo_final/`。既有 v2 不升版、不覆寫烘焙。

## 可檢查的問題

S08（315s）：原片兩側夏季密林貼近道路，上方樹冠縮小天空開口，左側短切坡、右側低實體護牆。第八輪卻是大片開闊山谷及高光滑左坡，樹木被坡面遮擋、冠層不足。不能用新增樹木總數代替正確近景。

S13（630s）：原片左側貼路岩壁，路線向左繞過岩角；右側闊葉樹冠遮住大部分近谷，遠方山景只從樹縫露出。第八輪缺岩壁、森林成列、天空與山谷過度開放。

S05（180s）及 S09（360s）：護欄方向雖有三維切線檢查，但高度以壓低的地形為基準，實際渲染相對柏油過低，技術 PASS 不能代表此項完成。

## 任務、依賴與驗收

1. Camera Luna：新增官方 IGN RGE 近路樣本資料工具及兩塊 patch。各以 geo station S08 patch=5275m、S13 patch=10339m 為中心，world XZ 軸 512m 方形、8m 間距、65×65 格點。逐批原始回應、座標、來源、hash、no-data 檢查必須保留。這是取樣網格，不宣稱 8m 代表來源資料的精度或影片 GPS。
2. Terrain Luna：依資料契約接入共用 geography helper；外緣 64m 平滑回既有粗 DEM，全球 datum 固定，路面、坡面、建物／樹根使用同一高度來源。依賴任務 1。不得擴大 25m 道路融合帶或用裁面遮住山谷。
3. Forest Luna：在既有 OSM woodland 範圍重建近路冠層，保留實際路面與建物排除；降低規則行列感，S08／S13 影片支持的路段增加闊葉樹冠與尺度變化。近路較密、遠景較疏，總量／耗時另報，地形接地依賴任務 2。不得將 OSM 林區誤稱逐棵實測。
4. Camera Luna：資料交付後，將護欄梁頂基準改為實際路面邊緣上方約 0.9m；立柱直立、底部埋入實際地形、柱長依坡面改變。驗證實際幾何而非只改 metadata。
5. root：保留第八輪來源及影格，凍結新來源，串行 native Metal 輸出 S08、S13，另抽 S05、S09 驗護欄。比較同一原片及固定相機；記錄是否改善、未符項與新回歸。

資料契約：`data/saisies_geo_nearfield.json` 包含完整 geography_frame，以及每塊 patch 的 center_s_m、center_x/z、min_x/z、spacing_m、grid、blend_margin_m、height_file、height_sha256。f32 為 little endian、ASL 公尺；row 為 z 遞增、column 為 x 遞增。world→latlon 必須符合既有精確 WebMercator frame；不使用度數當公尺。

## 完成條件與限制

技術條件為資料完整、外緣連續、datum／道路 XY 不變、地形不蓋柏油、樹根貼實際網格、立柱接地且護欄相對路面高度正確。視覺條件另外判斷：近路樹冠／坡面包覆是否符合原片，是否仍有人工列植、過大天空與錯誤彎道。原片人物、自行車及遮擋區不列重建目標。

本輪尚未處理的專屬店面、纜椅、石擋牆／岩壁、路牌與全線時間標定，持續保留退修。RGE 小區修正只涵蓋兩個近景，不能稱全線已精密重建。

S08 patch 中心取 5275m，是為同時覆蓋既有固定驗收 station5143.26m 與 HUD 高度約1255m的候選 station5408m（RGE1255.21m）。兩者均在 patch 核心；影片高度與道路位置仍需地標交叉確認，不以高度單獨更改正式時間錨點。S13 station約10339m的 RGE990–992m 與原片HUD991m相近。

## 本輪固定驗收結果

最終來源：`/tmp/saisies_round9_canopy_final`；證據：`export/saisies/review/round9_canopy_final/`。root 完成 S08/S13/S05/S09 四張1920×1080原生 Metal 截圖，逐張與原始影片影格對照，**0/4 達到完整本幀要求，維持退修**。其他14個視點未對本輪版本重新驗收。

七項 headless 驗證通過：route、coarse-geography audit、roadbed、buildings、forest、full769 roadside、nearfield。已知macOS憑證系統訊息另行記錄。GPU實際讀回8941棵樹、1772護欄梁、1781立柱，定位與方向檢查通過；定位點接地不代表整個可見根部 footprint 都已接地。

- S08/S13：近路闊葉樹冠、冠層重疊與路面樹影增加；仍缺實體護牆／岩壁，左坡與彎道投影不符，谷地過度露出。
- S05/S09：梁頂已以柏油邊緣上方0.90m為基準、立柱朝上並依地形延長；原片構圖仍不符。S09原片開闊左草坡出現過密針葉樹，林緣配置退修。
- RGE兩塊patch各4225格點；39個獨立API控制點在核心的bilinear誤差約0.76–1.08m RMS、最大1.90m。patch邊緣路面仍受粗DEM及估算剖面影響，不能宣稱全線高程／時間精準。
- 額外穩態幀率取樣停在QA腳本等待render signal，已中止並保留日誌；改用直接繪圖完成固定截圖。本輪不宣稱已驗證穩態或全線FPS。

測試修正亦留證：粗grid64造成護欄假接地，拒絕負post height／負Y縮放方案，改用完整769網格驗證；generic DEM audit明確停用局部patch，production預設仍載入；CLI統一支援`--`後參數。不以放寬物理幾何來取得PASS。

本輪維持獨立實驗場景，未取代v2展示／烘焙。原18張影片參考及文字保持原樣。下一輪待修規格見 `docs/saisies_revision_round10.md`，其內容尚未實作。
