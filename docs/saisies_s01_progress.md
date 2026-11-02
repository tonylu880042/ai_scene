# 最新狀態：S01已接受並封版

使用者已明確表示S01可以接受，要求完成當前中景木屋後轉S02。stage15單棟修改已原生驗收保留；S01不再追加細節。固定來源：`export/saisies/review/round15_s01/source_bundle_s01_final`，接受紀錄：`s01_final_acceptance.json`。以下保留歷史需求與逐項紀錄，以本段最新決定為準。

# S01 固定版與下一個改善工作

2026-10-19。root 分析／原生驗收，Luna 實作；先完成 S01，再進 S02。目標約80～85%人工視覺相似，不是自動像素分數。

## 最新驗收

**stage14餐廳三項已完成並保留。** 按本次約80%目標，遮棚前緣接近水平、店窗加高下移、厚棕色石基座改薄淺色踢腳；已做原生同視角檢視。小字型／布料與服飾細節不再追加。新對照：`export/saisies/review/round15_s01/restaurant_review.html`。

**背景樹林已由使用者接受。** 使用者指出樹木異常後，root 展示 stage12 原生圖；使用者回覆「可以接受了」。此接受記為背景樹林這一項，固定本版，不繼續微調樹形。餐廳三項接續完成；不自動擴大成S02／全線通過。

- 對照頁：`export/saisies/review/round15_s01/review.html`
- 實拍：`stage12_integrated/C_sun148.png`
- 接受紀錄：`accepted_forest.json`
- 固定來源：`source_bundle/source_snapshot.json`（253個來源、4個資產雜湊）

## 本輪保留的改善

1. Camera C 的道路投影、局部 Sun yaw148°，道路出口位置較接近原片。
2. 餐廳店面明確 UV 四邊形解決整張立面重複與左右鏡像，保留真正3D框架、窗體與深度。材質是AI衍生建模資產，不是驗收來源。
3. 右木屋改長屋脊、窄側山牆，調整本地量體、可見面窗與門廊；保留地面接觸。
4. 路邊花槽保留細緻花冠，改風化交叉圓木支腳。
5. 遠林改為不規則多團林冠，移除遠距白點卡片。主要規律排列根因是直接正規化 String.hash：相鄰值接近線性，尺寸的兩個 salt 相關係數1.0；改為32-bit混合後降為0.028。使用者接受的是此 stage12 版本。
6. 林下白區是舊地形露出與局部補面背面不可見共同造成；已對實際命中區域補綠地並修正本地材質可見性。CPU ray hit 不能替代 GPU 實拍。

## 本包完成：S01 左餐廳

- 遮棚前緣原生投影約y321～326，接近原片約y330。
- 店窗開口由1.98m加高至2.28m並下移，入口／下緣接近人行道。
- 厚棕色石牆視覺移除，改薄淺色踢腳；接地幾何保留。
- 只變更餐廳function與相關參數，樹林、其他建物、相機、路線與光線固定。
- 原生圖與人工判定：`restaurant_acceptance.json`；技術結果：`restaurant_technical.json`。stage12固定來源另存於`source_bundle_stage12_accepted_forest`。

本包以約80%為止，不追求100%或細小字體／窗框。S02暫不動；R14的3.39秒載入數字不代表本版局部生成成本。

## 技術檢查與重現

- 原生1920×1080主圖及兩張真正側移圖完成，相機實際相距5m，姿態與請求一致。
- 30km/h原生短跑約2.013秒推進16.366m；精確時間步進驗證0→10→210→220m並截止，未進S02。短跑不是全路完整巡覽或FPS測量。
- 原R14森林6487棵保留；S01樹記錄4009（遠林4003／近闊葉6）。封閉樹冠是同樹的顯示幾何，不另算新樹。
- 原生727個MultiMesh、18052個instance transforms全部有限且非零。來源／資產重新雜湊一致。
- Headless僅有macOS憑證查詢警告，沒有場景／腳本錯誤；GPU驗證由原生完成。
- 完整結果：`export/saisies/review/round15_s01/final_technical_results.json`。

執行 `tools/run_saisies_s01_review.command` 固定在S01；加 `--tour` 以30km/h巡覽0～220m。啟動器先校驗持久來源與資產，再還原隔離專案，不混用工作區未驗收的路線資料。`--prepare-only` 只還原並輸出 `work_project.json`。R14全路快速啟動器保持原版。

## 來源與歷史

原幀 `video/saisies_analysis/acceptance/S01_f000120.png`：frame120、PTS120120、time_base1/24000、實際5.005秒；SHA256 `b25ceb90f56481c1c5f1a4ae2d4e4afdf111673e2374b7ec2123d8dbd3bd65d3`。

退修候選、來源清單與圖均保留在round15_s01。stage10/11來源另存為 `source_bundle_stage10_rejected_forest`／`source_bundle_stage11_rejected_rows`。錯誤的第一次樹冠開關探針標記為 `canopy_probe_invalid_no_toggle/INVALID.txt`，不作開關比較證據；後續探針確認實際切換三組樹冠後才比較。
