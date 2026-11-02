# S03 咖啡館旁兩棵高針葉樹 · R25

本輪只處理兩棵樹，Luna實作、root原片分析與原生視覺驗收。約80%為人工工作目標，不生成自動相似度分數。改善保留，交使用者驗收；完整S03仍未通過。

來源為未修改S03_f001798.png，frame1798、PTS1799798/24000、74.991583秒。固定station930m/FOV77°、1920×1080、Metal Forward+。來源SHA256見本輪brief.json。

A固定XZ(172,-902)，實際高13.24m；B固定XZ(179.507645,-872.002808)，高21.68m。A位於咖啡館後方，大部分樹身由屋頂遮擋；B於右側保留較寬的完整錐形。店窗、入口、樓梯、牌群與道路出口保持可見。主圖、實際2m側移與3D近景均已檢查。B仍比原片高大，葉材質偏暗／有卡片感；原先12..18m為估計而非測量，沒有以更動咖啡館或相機追求精確像素。

兩個MeshInstance3D使用本地複製材質，沿世界Y直立。8個實際surface0最低木質頂點，以渲染地形／overlay與鋪面三角形最高表面核對，木根位於表面下0.040..0.149m，無懸空。拒絕nearest-vertex fallback。420m相機範圍控制顯示，Mesh renderer end=0；S01/S02均關閉本輪樹組。

309個固定來源、48個資產雜湊通過；前輪304個來源保持一致。最終ON/OFF原生日誌無腳本錯誤。S01共2073600像素完全相同。S02為777像素低幅差異（0.0375%，最大通道差6/255），位於既有近景樹／石塊陰影區域；鏡頭一致、本輪樹組關閉，差異原因未確證，不宣稱完全一致。沒有測量效能或全程巡覽。

保留退修證據：phase1 A露出太多；phase2 A仍偏右且pair帶動B；phase3 typed array runtime錯誤。最終固定兩點並修正型別後重新渲染。

對照：`export/saisies/review/round25_s03_cafe_trees/review.html`。完整判定：同目錄`acceptance.json`；像素與雜湊：`regression.json`；重驗：`python3 export/saisies/review/round25_s03_cafe_trees/verify_evidence.py`。啟動：`tools/run_saisies_s03_cafe_trees_review.command`，關閉基準旗標`--s03-cafe-trees-off`。

使用者已略過道路標線及右坡遠景屋群，均不再排入。後續候選為咖啡館露台橘紅遮陽傘；本輪沒有執行下一項。
