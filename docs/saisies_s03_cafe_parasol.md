# S03 咖啡館露台橘紅遮陽傘 · R26

本輪只新增一把遮陽傘，Luna實作、root分析與原生驗收。約80%為人工工作目標；單項改善保留，交使用者驗收，完整S03仍未通過。

來源為未修改的S03_f001798.png：frame1798、PTS1799798/24000、74.991583秒，SHA256見本輪brief.json。原片橘紅色低斜傘面在咖啡館右端、大針葉樹前方。本包固定station930m、FOV77°、1920×1080、Metal Forward+，延續既有咖啡館和相機。

扁八角傘沿店面寬4.6m、向外深1.5m、傘沿2.20m、頂2.65m；尺寸皆為推估。細深色杆、八根肋骨和配重底座隨傘組顯示。底座位於既有R18露台一端，避開中央樓梯；四角以實際露台Mesh三角形核對，clearance皆0m。實際傘面頂點到正面店牆最小距離0.30005m，未穿牆。420m相機範圍控制本組，S01/S02關閉，renderer end=0。

主圖、真實2m側移和3D近景完成。第一候選偏小、偏尖且鮮紅，保留於candidate_phase1；最終加寬／降低頂點／改沉橘紅後重新渲染。傘仍較原片小、偏靠店牆，採簡化傘骨和布面；本輪沒有搬動咖啡館、平台、兩棵樹或相機追求完全一致。

314個固定來源／48個資產雜湊通過，R25的309個來源保持一致。最終原生ON/OFF日誌無腳本錯誤；S01及S02各2073600像素完全相同。headless僅用於幾何／建置，dummy renderer不能出圖，最終影像全部來自Metal原生渲染。沒有測量FPS、載入時間或全程巡覽。

對照：`export/saisies/review/round26_s03_cafe_parasol/review.html`；判定`acceptance.json`；固定來源`source_bundle/source_snapshot.json`；重驗`python3 export/saisies/review/round26_s03_cafe_parasol/verify_evidence.py`。啟動`tools/run_saisies_s03_cafe_parasol_review.command`，加`--s03-cafe-parasol-off`看關閉基準。

道路標線與右坡遠景屋群已依使用者指示略過。後續候選為咖啡館露台木欄杆，本輪未執行。
