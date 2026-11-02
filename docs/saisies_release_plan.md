# 全路線發行候選版（2026-10-20）

使用者明確要求加大跨度、朝發行前進；原本「每次一小項／10秒／60秒」拆法已由最新指示取代。整合範圍為原片全長約15分20秒，實際Godot路線14615.087922m，30km/h巡覽約29分14秒。不得把原片時長當作30km/h巡覽時長。

本包以R35固定346來源／48資產為base；S01/S02已接受，S03依使用者豁免結案，不重做。R35已補S04後段林帶/護欄，實際399新樹、3MultiMesh、後段護欄1855–1942m；完整920m巡覽110.557秒、單調、到終點停止，S01–S03切換pixel exact。S04 80–95秒草坡與近林仍不相符，不能標整段通過。

## 整包分工

- `/root/luna_s03_parasol`：整合owner，release controller/localmapping、專用scene、launcher、靜態cache/native bake與快啟動流程。
- `/root/luna_release_forest`：全線針闊葉林、冠層/草甸/谷地開口、空間tile/MultiMesh/實際地形接地。
- `/root/luna_release_roadside`：低實體護牆、石牆/金屬欄側別、岩切/岩角、主要屋棚/牌群與地面支持。
- root：來源分析、全18 baseline/final native對照、集中幾何/連續性/效能驗證，不逐段等使用者批准。

三worker各擁有不同新prefix檔案，不回退/修改346個固定base來源。實機凍結時採base快照加所有新檔，不能默默使用live舊data的歷史差異。

## 交付門檻

1. 0至14615m連續道路能跑到底，人物/車輛/HUD/debug路線不出現在環境。
2. 18個source視點集中比對；森林廊道、開闊草谷、岩切、聚落/路口具有各自主要空間辨識，不把整線均勻鋪林。
3. 新根部/柱腳/主要牆與房舍有actual visible mesh支持，沒有浮空、穿路、護欄橫封出入口；worldY直立及route方向一致。
4. 停掉歷史review相機寫入者，release可用30km/h連續巡覽，另提供快速驗收速度及18視點定位。
5. 專屬場景與launcher可重現；快取/烘焙必須native保存完整MultiMesh GPU transforms，禁止Dummy bake偽造空森林。量測啟動/代表視點效能，不能由樹量推FPS。
6. 各視點獨立記錄可執行、幾何與視覺結果；約80%為定性目標，不虛構相似度數字。不滿足整段要求時保持候選狀態。

暫緩逐窗、招牌文字、花草、標線與精確雲色，集中處理阻擋使用/發行的主要缺口。這是本地發行候選版建置，不代表已外部發布。

來源規格：`export/saisies/review/round36_release/release_brief.json`、`source_manifest.json`。18張baseline已於R35固定版以原生Metal集中擷取，`baseline/capture.json`保存實際station與相機資料，source_board/baseline_board共三組供批次分析。

## 最新補充（2026-10-20）

使用者要求起點與終點有明確標示，並授權終點自由創作，補滿最後停格畫面。新增獨立 `ReleaseTerminals` 模組：路側出發標誌、終點門架、山村抵達區與近中遠景。必須檢查連續巡覽實際0m、終點前80m／35m及14615.087922m停車位置，不能只用S18來源視點代替。標示為3D世界物件，不增加HUD或人物車輛。

整合開發owner為 `/root/luna_release_integrate`（先前名稱為舊交接記錄）。新增終點創作不代表S04–S18原片相似度通過。新牆基與房舍接地以實際可見網格頂點檢查；合理基礎埋入與浮空分開記錄。
