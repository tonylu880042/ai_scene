# Saisies R36 全線候選版

2026-10-20。維持Luna開發、主代理分析與原生驗收。全線約14.615公里；此為本地候選版，未外部發布。

## 本輪完成

- 起點路側DÉPART／START標示。
- 終點ARRIVÉE／FINISH門架；實際停車後仍留在前方。
- 延伸柏油路、承台與山村抵達區，包含木屋、花園、長椅與68棵近中遠景針葉樹。此區依使用者授權自由創作。
- 全線森林、護牆、岩壁、農舍與路標整合；護牆、切坡、岩壁腳線、房舍基礎及橋欄柱腳改以實際可見地形網格接地。
- 固定374個來源檔、184個資產；R35的346個base來源hash完整保留。原始18張影片影格未修改。

## 原生驗證

- 1920×1080，Metal／Forward+；18個來源視點OFF/ON共36張，加實際0m、終點前80m／35m、14615.087922m停車點四張。
- 30km/h控制器以0.25秒步長模擬全線：單調、到終點停止；不是FPS測試。
- 原生600km/h加速巡覽：87.69秒，完成全線，站點單調。正常30km/h約29分14秒。
- 森林新增2834棵／190個MultiMesh群；GPU origin最大誤差0.000000m；獨立抽查512棵真實根部，漏採樣0。
- 路側2582個實際支撐頂點：漏採樣0、浮空0、不合理過埋0、fallback 0。594段護牆、5段岩體、4個下段地標、切坡及2群橋欄柱腳修正通過；沿用9段base護欄，避免重複。
- 起終點文字朝向／視框與最後鏡頭高於實際路面檢查通過；地面不能覆蓋新增路面。
- 原生烘焙與重新載入：3480個MultiMesh實例保留，22張視點與生成版最大平均通道差0.00000466/255（門檻0.02）。這證明快取一致性，不代表原片視覺相似度。
- 本機場景就緒時間：程序生成213.0秒；快取66.9秒。快取仍包含既有S01–S04 builder運算。

固定視點量測（1920×1080，30 warmup＋120 frames，非全線最低FPS）：

- S04：平均6.90ms，P95 7.39ms，約145.0fps。
- S11：平均6.90ms，P95 7.54ms，約144.9fps。
- S17：平均6.90ms，P95 7.43ms，約145.0fps。

## 視覺狀態與限制

S01/S02保留接受紀錄，S03保留使用者豁免。創作收尾的構圖與技術檢查通過；外側原始地形仍偏淡。S04–S18整體仍有地形／相機投影／林冠與來源的差異，S16限速牌與S17路牌可讀性也仍待校正，不宣稱全線80%。森林helper另列起訖覆蓋缺口，與根部／GPU幾何證據分開；終點另有創作林帶，不用樹量替代原片驗收。

下一包應集中修正S05–S18道路投影、坡谷形狀與近路冠層，不重開S01–S03或切回10秒小輪次。完整靜態世界烘焙可在視覺穩定後再消除舊builder啟動時間。

## 啟動與證據

- 雙擊 `export/saisies/review/round36_release/run_review.command`：固定版全線30km/h巡覽，自動使用已驗證快取。
- 雙擊 `export/saisies/review/round36_release/view_finish.command`：直接查看真正終點停車畫面。
- `python3 export/saisies/review/round36_release/run_review.py --source S18`：來源視點。
- `--generated` 可改用同一固定版程序生成；`--prepare-only`只檢查還原／指令。
- 對照頁：`export/saisies/review/round36_release/review.html`。
- 判定／證據：`acceptance.json`、`release_result.json`、`cache_verification.json`、`verification.json`、`source_bundle/source_snapshot.json`。
- 原生截圖：`on/`、`off/`、`terminals/`、`cached/`。被拒版本保留於`pre_*`與`terminal_preview/pre_*`，不當作新版本結果。

工程備註：終點門架淨寬metadata的13.18m待同步；依本版柱距13.3m與柱寬0.72m計算，實際淨寬12.58m，仍足夠容納8m車道。下次程式修訂時同步這個數值欄位。
