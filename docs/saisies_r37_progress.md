# R37 Godot 續作 — 2026-10-21

本輪輸出目標依使用者指示維持 **Godot**。接續早上的 S06／S10／S12 代表段落，完成 v8 未完成的同版檢查，再交付 `geometry_candidate_v9`。R36 全線及創作起終點仍保留；本輪沒有將局部道路估計合併為全線或 canonical package。下方 v9 驗證紀錄保留為前一增量，最新屋群修正見下一節。

## 屋群地基修正（同日後續）

使用者指出屋群漂浮後，以固定 v9 原生重現：木屋底座最大懸空 **2.641 m**，部分靠山側反而埋入地形。原本只將四組屋群的中心點接地，不能代表組內每棟房屋及石基的 footprint 有支持。

目前 **S06 已切換至 v10**；S10／S12 保持原先驗證過的 v9。啟動器依 `selected_candidate.json` 的逐段版本還原，不需要改原本的 `.command` 入口。固定全線 R36 未改。

修正沿用共用 chalet factory 與既有 visible-triangle fitter：逐棟決定水平樓板高度，石基與擋土石塊底面以約 0.5 m 網格貼合實際地形並埋入約 8 cm。這是可選的地形接地步驟，其他場景的 prefab 預設造型不變。沒有抬升地形或改動道路、坡度、相機。

v10 以原生 Metal 重拍 S06 全部 9 個視點。8 棟房屋、56 個支撐網格共 **19,408** 個實際底部頂點、底面三角形中心和邊中點採樣，正向懸空最大值 **0 m**、採樣漏失 **0**；最深埋入 12.6 cm（底面三角形內插，頂點目標為 8 cm）。新增樹根、GPU、巡覽及路面檢查沒有回歸。旋轉／縮放後放在斜坡上的 chalet 回歸測試通過；該測試在修正前因缺少逐棟接地而失敗。

[修正前後對照](../export/saisies/review/round37_route_diagnosis/geometry_candidate_v10/foundation_before_after_228.jpg) · [驗證紀錄](../export/saisies/review/round37_route_diagnosis/geometry_candidate_v10/foundation_verification.json)。樓板依斜坡分層，部分房屋現在可見較高石基；這是真實支持體，不是懸空薄板。原片視覺相似度仍維持候選判定。

## 查看

- [原片／Godot 對照頁](../export/saisies/review/round37_route_diagnosis/review.html)：27 張 1920×1080 對照與三段連續序列。
- [S06 村落](../export/saisies/review/round37_route_diagnosis/view_S06.command)、[S10 岩切林道](../export/saisies/review/round37_route_diagnosis/view_S10.command)、[S12 連續彎](../export/saisies/review/round37_route_diagnosis/view_S12.command)：雙擊開啟固定版本的 Godot 循環預覽，空白鍵暫停／繼續。
- 開發場景：`scenes/saisies_r37_representative.tscn`，F6 後保持巡覽、不自動退出。固定驗收請以上述啟動器為準；它還原固定源碼、編譯後的局部擬合資料及已驗證的 R36 快取，不使用日後可能改動的 live 配置。

## 本次變更

- 共用 `SaisiesTrees.broadleaf_variants(round_crown)` 加入可選圓冠：樹冠頂部收束、外緣有不規則大輪廓。R37 新增林木選用圓冠；預設仍為舊形狀。幾何／LOD 預算不增加，也沒有修改快取中的既有森林。
- R37 dressing 從資料讀取冠型並記錄在報告；維持以實際可見地形三角形接地、樹幹直立與原有道路淨空規則。
- 固定啟動器要求明確的 `selected_candidate.json`，不再於缺失時默默開啟舊 v5。凍結工具明記共用生成器 overlay 及修改前後 hash。
- Godot 場景直接執行時改為持續循環巡覽；此項 scene 預設值另有檢查，固定版啟動器仍以明確的 `--interactive` 參數運行。

## 驗證

同一 v9 固定版本以 Godot 4.7.2、Metal／Forward+、1920×1080 拍攝三段各 9 張；所有 native log 沒有 ERROR。

| 段落 | 新增林木 | 木屋組 | 路面／route 核心最大高度差 | 碰撞面／route 核心最大高度差 |
|---|---:|---:|---:|---:|
| S06 | 45 | 4 | 1.61 cm | 1.18 cm |
| S10 | 94 | 0 | 0.86 cm | 0.86 cm |
| S12 | 94 | 0 | 1.20 cm | 0.82 cm |

- 27 張的相機 pose、station 與 grade 與早上 v8 逐項一致；本次未調整道路／高程資料。
- 三段修改窗口外抽查道路位置誤差皆為 0 m。
- 新增樹木共 233 棵；實際 instance origin 與 GPU transform 誤差皆為 0，樹幹直立誤差 0；根部地形採樣漏失 0，採樣高度誤差 < 0.1 mm。
- 三段循環及空白鍵暫停測試通過。這是連續 pose／操作檢查，不是 FPS 測試。
- 共用冠型幾何測試通過：確定性、頂部收束及 8,640 vertices 的既有預算。修改前 v8 與修改後 v9 的預設舊冠型 arrays SHA256 相同：`63998a66533f16c665692ff38fd98f966a725818da163a1578416b80b204f95e`。
- Python package 測試 87／87 通過；固定預覽的來源、資產與快取還原檢查通過。

詳細證據：[continuation_verification.json](../export/saisies/review/round37_route_diagnosis/geometry_candidate_v9/continuation_verification.json)、[固定來源](../export/saisies/review/round37_route_diagnosis/geometry_candidate_v9/source_bundle/source_snapshot.json)、[人工畫面判定](../export/saisies/review/round37_route_diagnosis/geometry_candidate_v9/decisions.json)。原片影格 hash 保持不變。

## 尚待修正

岩坡仍偏規則層面；S06 草坡過於平滑，屋群與遠山的投影比例仍有差距。S10／S12 的林冠開口、林下層、右側針闊葉比例與來源仍不完全一致。技術通過不代表原片視覺通過，尚不宣稱三段或全線達到 80%。

早上留下的道路擬合仍是來源估計的隔離實驗，時間／里程與相機未由 GPS 精確校正。後續優先收斂岩坡自然輪廓、林下層與 S06 草坡／屋群比例；實際道路高程不得為畫面效果任意改動。根部驗證限 origin，尚未證明每一個外張根部頂點接地。S01／S02 接受紀錄與 S03 豁免均保留。
