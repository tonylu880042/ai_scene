# Saisies 實作與視覺驗收紀錄

建立：2026-10-16；最新驗收：2026-10-17。驗收者：主代理；開發者：Luna。此文件與原始參考清單分開，避免把開發者自行通過的技術測試當成影像相符。


**最近一次全18點判定：退修。all18_v7 的 18/18 個原生 Godot 截圖正常輸出，0/18 個達到「符合本幀要求」。** 這代表已完成固定視點審查；環境還原尚未完成。鏡頭尚未精密標定，未宣稱全片逐幀對位或像素相符率。

[最新18點逐項判定](#latest-v7)。

最新圖片：上方／左側為原片、右側為 Godot；[起點對照](../export/saisies/review/all18_v7/S01_comparison.png) · [森林岩壁對照](../export/saisies/review/all18_v7/S13_comparison.png) · [末段對照](../export/saisies/review/all18_v7/S18_comparison.png)。


<a id="latest-round7"></a>
## 第七輪局部提交：round7_retained

2026-10-17：本輪保留街景／相機／路緣花槽修改，六個視點 S01/S02/S03/S05/S08/S09 全部完成1920×1080原生截圖，八項來源技術檢查通過（macOS CA錯誤獨立記錄）。主代理已看六張三欄圖，**六張仍為需修正，沒有新增完整單幀通過**。最近一次全18點審查仍為下方的 all18_v7，沒有重新宣稱全片逐幀驗收。

S01局部改善包括旅館低坡頂／陽台、招牌、透明店面與展示、屋面細格、沿路圓木花箱／照片花葉冠體，以及估算右側車道視點。餐廳比例、街道幾何、村屋密度、林山與整體細緻度仍不足。遠山候選在S05出現突兀切山，最終撤回至v7；撤回檔案hash已確認一致，候選證據保留。

[S01原片／新圖](../export/saisies/review/round7_retained/S01_comparison.png) · [原片／v7／新圖](../export/saisies/review/round7_retained/S01_progress.jpg) · [第七輪發包與退修紀錄](saisies_revision_round7.md)。既有烘焙檔仍為all18_v7，未包含本輪街景；本輪未更新烘焙與效能量測。

## 本輪發包

- 主 Luna：共用路線、鏡頭時間對應、確定性截圖、場景整合；S01–S03 的主街、植栽島與纜椅設施。
- 地景 Luna：S04–S09 草甸、農舍、林緣、石牆／護欄；連續世界的山谷與遠山。
- 樹林 Luna：S10–S18 樹冠層次、岩切、下段護欄與聚落、片尾道路；樹木模型。
- 主代理：原片內容、文字依據、同視角圖片審查、退修清單與最終結論。實作代理不得自行改寫原片參考或宣告視覺驗收通過。

## 判定方式

逐一使用 [18 張驗收卡](saisies_acceptance_frames.md) 與 `data/saisies_acceptance_frames.json` 的固定原片影格。每次記錄 Godot 實際截圖、入口與鏡頭參數。要求同視角、同解析度，禁止照片背景、影像扭曲或截圖後補景替代真實 3D。

檢查順序：道路與鏡頭 → 建築／岩面量體 → 樹冠與護欄 → 山稜及視野開口 → 材質與光照。先處理大輪廓與位置，不能用細節數量抵銷錯誤配置。人物、車輛、車把及 HUD 排除；其遮擋區域列為未知，不能判通過。

狀態僅使用：待提交、需修正、局部符合、符合本幀要求。單幀符合不代表完整時間段或測繪精度通過。相機仍未校準時，必須指出，不能聲稱已取得精準像素誤差。

## 初始狀態

舊版 `export/saisies/previews/village.png` 為約 0.1km 的未對位預覽。與影片起點的內容比較顯示：大型餐廳、後方多層旅館、緊密街面、人行道及專屬路口缺失；現有稀疏木屋與草坡不符。此圖僅作拒收基線，不能拿來量測同幀投影誤差。

| ID | 主驗收圖時間 | 本輪 Godot 截圖 | 狀態 |
|---|---|---|---|
| S01 | 00:05.005 | [原片／Godot](../export/saisies/review/all18_v5/S01_comparison.png) | 需修正 |
| S02 | 00:29.988 | [原片／Godot](../export/saisies/review/all18_v5/S02_comparison.png) | 需修正 |
| S03 | 01:14.992 | [原片／Godot](../export/saisies/review/all18_v5/S03_comparison.png) | 需修正 |
| S04 | 01:59.995 | [原片／Godot](../export/saisies/review/all18_v5/S04_comparison.png) | 需修正 |
| S05 | 03:00.013 | [原片／Godot](../export/saisies/review/all18_v5/S05_comparison.png) | 需修正 |
| S06 | 03:45.016 | [原片／Godot](../export/saisies/review/all18_v5/S06_comparison.png) | 需修正 |
| S07 | 04:30.020 | [原片／Godot](../export/saisies/review/all18_v5/S07_comparison.png) | 需修正 |
| S08 | 05:14.981 | [原片／Godot](../export/saisies/review/all18_v5/S08_comparison.png) | 需修正 |
| S09 | 05:29.996 | [原片／Godot](../export/saisies/review/all18_v5/S09_comparison.png) | 需修正 |
| S10 | 06:44.988 | [原片／Godot](../export/saisies/review/all18_v5/S10_comparison.png) | 需修正 |
| S11 | 08:30.010 | [原片／Godot](../export/saisies/review/all18_v5/S11_comparison.png) | 需修正 |
| S12 | 09:29.986 | [原片／Godot](../export/saisies/review/all18_v5/S12_comparison.png) | 需修正 |
| S13 | 10:30.004 | [原片／Godot](../export/saisies/review/all18_v5/S13_comparison.png) | 需修正 |
| S14 | 11:15.008 | [原片／Godot](../export/saisies/review/all18_v5/S14_comparison.png) | 需修正 |
| S15 | 12:45.014 | [原片／Godot](../export/saisies/review/all18_v5/S15_comparison.png) | 需修正 |
| S16 | 14:00.006 | [原片／Godot](../export/saisies/review/all18_v5/S16_comparison.png) | 需修正 |
| S17 | 14:29.994 | [原片／Godot](../export/saisies/review/all18_v5/S17_comparison.png) | 需修正 |
| S18 | 14:59.982 | [原片／Godot](../export/saisies/review/all18_v5/S18_comparison.png) | 需修正 |

## 實際審查

已完成第一批代表段的實際 Metal 渲染與退修。尚無任何場景列為符合本幀要求。

### 第一批代表段：需要修正

原片在左、Godot 提交在右，均保持原始 1920×1080，僅在圖外增加標題列。

- [S01 原片／Godot 對照](../export/saisies/review/checkpoint_01/S01_comparison.png)：大型量體與店面已有新增，但餐廳屋頂旋轉未交換平面尺寸，造成巨型屋頂伸入道路上方；原片下坡透視、街面密度、貼街鋪面與前後建物比例尚不符。已退回主 Luna。
- [S05 原片／Godot 對照](../export/saisies/review/checkpoint_01/S05_comparison.png)：右側護欄在第二輪補上，但道路仍過於平直、山谷落差不足，對面森林山體的位置與輪廓不符，場景有明顯平坦空白。已退回地景 Luna，並要求主 Luna 修正局部曲率。
- [S13 原片／Godot 對照](../export/saisies/review/checkpoint_01/S13_comparison.png)：第一輪巨型平灰牆已移除，但新一輪岩面呈孤立薄片與裸露矩形基座，樹根浮起、樹冠出現亮色橢球，森林遮擋和道路左彎仍不符。已退回樹林 Luna，並要求主 Luna 修正曲率。

同時發現 acceptance pose 被相機每幀更新覆蓋的問題，主 Luna 已修改為持續套用；該修正不代表相機已完成標定。截圖工具本身的 PASS 只代表有輸出圖片，需另檢查執行日誌與畫面。

## 全部 18 幀第一次固定版本驗收

18/18 個原生 Metal 截圖完成，1920×1080，執行日誌沒有腳本／載入錯誤。這是渲染完成率，不是視覺相符率；本輪沒有任何場景列為「符合本幀要求」。

| ID | 具體結論 |
|---|---|
| S01 | 餐廳與旅館量體已新增，但立面、屋頂比例、店面細節、街道密度及鏡頭構圖仍不符。 |
| S02 | 重大：植栽島覆蓋相機與道路，畫面主要成為亮綠地面；路口與大樹未正確呈現。 |
| S03 | 有跨路纜索／纜椅，但低樓、路牌群、花槽與寬廣交會鋪面缺失。 |
| S04 | 小屋與林帶未出現在原片對應視域，草坡側別、道路與遠山構圖不符。 |
| S05 | 已有左彎與右護欄，但谷地過平，主山形成不自然高牆、色彩及森林／草甸分區不符。 |
| S06 | 原片左前方主木屋與右側低屋頂未正確出現；作者把可見時間直接當物件縱向位置。 |
| S07 | 左側支路與主農舍缺失，山谷變成高牆，屋舍與電桿位置不符。 |
| S08 | 右側低實體牆側別符合部分描述，但缺密林與左切坡，山牆遮掉原片開口。 |
| S09 | 左石牆與右護欄側別已建立，但路線過直、牆段重複接縫明顯，缺近景樹群。 |
| S10 | 左護欄與右切面側別部分符合；岩面過平像混凝土、缺自然裂面和冠層遮蔭。 |
| S11 | 森林已有增加，但白色多幹樹重複，右側被不應連續的平岩牆覆蓋，山景開口不足。 |
| S12 | 有貼坡路廊，但彎道過緩、右岩坡過平，林冠與地面明暗不符。 |
| S13 | 左岩面側別與左彎已有改善，但岩壁仍像拉伸直牆，缺自然輪廓與右側密集樹冠。 |
| S14 | 重大：山側／谷地側與原片相反；右護欄存在，但道路、冠層和遠山開口不符。 |
| S15 | 左護欄右切坡側別部分符合，但缺貼路突出岩角和相應彎道，切面過平。 |
| S16 | 右側 50 標誌未在主視域出現，谷地被樹與錯向坡面遮住，遠山和下方屋舍不足。 |
| S17 | 重大：木棚和藍牌在主車道內，原因是 ±1 側別被當成公尺偏移；左右住屋配置不符。 |
| S18 | 重大：護欄橫跨支路入口，牌群／低樓未出現在側看鏡頭，支路鋪面與路口不符。 |

已將上述缺失分別退回三位 Luna。原始提交與其檔案雜湊保存在 `export/saisies/review/all18_v2/`；後續修正不覆蓋這批證據。

獨立幾何／巡覽檢查：全長 14,800m、起點估算 1,608m、末段最後可讀約 689m；自動鏡頭可到達全程終點，烘焙場景載入後有 0 個生成腳本。一次程序同時建立來源與烘焙場景的 headless 檢查在退出時仍有 Dummy renderer 資源警告；上述原生 18 次截圖未出現同類警告，不將該警告隱藏為完全乾淨的測試。


## 第二次固定版本：發現回歸，停止批次

來源快照與日誌保存在 `export/saisies/review/all18_v3/`。S01–S09 原生截圖成功，S10/S11 有 Metal `timeout waiting for fence`，S12/S13 無有效圖，故停止後續批次，不以不完整或失敗截圖作為驗收通過依據。

- S02 植栽島已移出道路，該項遮擋已解決；整體路口比例、前後建物及山景仍不符。
- S03 新增左樓與交會鋪面，但路牌／花槽、建築尺度與背景仍需修正。
- S04 草坡左右仍相反；S06/S07 屋舍已出現在視域，但可見面是大面白牆，與原片木屋窗面不符。
- S05 新山體仍是光滑淡綠面；S08–S10 更出現大型山體底面覆蓋天空，屬嚴重穿模，已退回。
- S10 起的 GPU 逾時伴隨葉片三份幾何與透明材質修改，要求移除重複幾何並修正 alpha cutout；因果仍需修正後的原生重測確認。
- 近路坡面在 uphill side 切換處突然接合，出現垂直矩形端面，要求沿路徑平滑過渡。

本輪仍無符合本幀要求的場景。以上缺失已分別交回原開發 Luna，原片參考與判定標準不因實作困難而放寬。


## 第三次固定版本：18 幀正常渲染，視覺退修

`export/saisies/review/all18_v4/` 保存完整 18/18 原生截圖、六張對照索引與來源雜湊；日誌無 GPU／腳本／載入錯誤。root 已查看六張索引及 S01/S05/S08/S13/S17/S18 原尺寸圖片。

已確認修復：入口花台不再遮路、末段房屋與牌群不在車道內、S04/S14 山谷側別修正、S08/S09 懸空巨大山體消失、森林 GPU 逾時消失。仍未達到影片相符標準。

本輪退修：

- S01 店面仍像大封板，缺可辨識窗框、招牌、支柱和遮陽棚結構。
- S05 對面主山移到畫面右側，前方仍過空，缺原片森林與草甸分區。
- 闊葉樹在 LOD 簡化後變成近乎裸枝，不能代表影片夏季密林；要求沿冠層重建葉片群。
- S17/S18 斜屋頂中心高度算錯，屋簷懸空，要求修正高度並封山牆；片尾支路不得使用碎石鋪面。
- S06/S07 白牆／木屋可見面、S08/S10–S15 岩面輪廓、S09 彎道、S16 谷地開口與屋舍等仍有差異；這些保留在最終退修清單，不能因消除技術錯誤而判通過。

樹木效能的單一變因測試：同一台 M4 Pro、同一 S13，v2 原版 PASS；v2 僅替換新版樹木時 GPU fence timeout／黑圖；新版加入低面樹木 LOD 與 shadow proxy 後，v4 全 18 視點均正常輸出。此結果確認回歸與樹木變更相關，尚不等於全線 FPS 保證。LOD 方法參照 [Godot 官方 ImporterMesh 文件](https://docs.godotengine.org/en/stable/classes/class_importermesh.html)，實際面數以本專案驗證工具輸出為準。


## 前輪整合驗收｜2026-10-17｜all18_v5

主代理重新凍結來源，完成 18/18 個 1920×1080 原生 Metal 截圖；日誌沒有腳本／載入／GPU fence 錯誤。已查看六張完整對照索引，並檢視起點、山谷、森林岩壁、限速牌、住屋與片尾的原尺寸提交。來源雜湊、逐次日誌與渲染結果保存在 `export/saisies/review/all18_v5/`。

最新修復已確認：闊葉樹恢復葉片、S17/S18 屋頂接牆、片尾支路改柏油、店面增加窗框、重大遮路與山體覆蓋天空消失。這些只解決部分缺失，不能代替場景內容相符。

| ID | 最新原片／Godot | 主代理判定與待修 |
|---|---|---|
| S01 | [開啟對照](../export/saisies/review/all18_v5/S01_comparison.png) | **需修正**：店面已增加窄窗框與遮陽棚，但餐廳立面比例、招牌／露台、旅館遮擋、沿街密度及前方林山仍不符。 |
| S02 | [開啟對照](../export/saisies/review/all18_v5/S02_comparison.png) | **需修正**：植栽島已不遮路，樹木恢復有葉；但石砌島形、道路繞島路口、右樓尺度、花槽與後方街區／山景仍不符。 |
| S03 | [開啟對照](../export/saisies/review/all18_v5/S03_comparison.png) | **需修正**：有跨路纜索及設施，已補左樓與交會鋪面；左樓過大、路牌群與花槽位置、纜椅投影和背景林山仍不符。 |
| S04 | [開啟對照](../export/saisies/review/all18_v5/S04_comparison.png) | **需修正**：右高左低側別已修正；左側小屋頂、右側連續針葉林及林緣、道路彎曲與遠山構圖仍不足。 |
| S05 | [開啟對照](../export/saisies/review/all18_v5/S05_comparison.png) | **需修正**：左彎與右外彎護欄存在，垂直矩形換坡端面已緩和；主山仍偏右且過低，缺深谷、覆林山面與草甸分區。 |
| S06 | [開啟對照](../export/saisies/review/all18_v5/S06_comparison.png) | **需修正**：左側屋舍已可見，但呈大面白牆而非木造窗面；右側低於道路的屋頂群缺失，道路下坡和背景山體不符。 |
| S07 | [開啟對照](../export/saisies/review/all18_v5/S07_comparison.png) | **需修正**：左側上坡屋、支路和右側低屋已建立，但可見立面、支路開口、錯層尺寸與谷地山形仍不符。 |
| S08 | [開啟對照](../export/saisies/review/all18_v5/S08_comparison.png) | **需修正**：右側低實體護牆側別正確，天空不再被山體底面覆蓋；左切坡像整片平面，森林包覆、冠層遮蔭和前方山景開口仍不符。 |
| S09 | [開啟對照](../export/saisies/review/all18_v5/S09_comparison.png) | **需修正**：左石牆右金屬欄側別正確；原片右彎仍過直，牆段接縫／石塊尺度重複，樹冠及坡形不足。 |
| S10 | [開啟對照](../export/saisies/review/all18_v5/S10_comparison.png) | **需修正**：左護欄右岩切側別正確；岩面仍像連續貼圖直牆，缺自然裂面、突出輪廓與上緣植被，樹冠和路面陰影不符。 |
| S11 | [開啟對照](../export/saisies/review/all18_v5/S11_comparison.png) | **需修正**：闊葉樹已恢復葉片且針闊葉可區分，但樹冠尺度／排列人工、右側仍有過長平牆，缺原片乾黃土坡及不規則森林開口。 |
| S12 | [開啟對照](../export/saisies/review/all18_v5/S12_comparison.png) | **需修正**：有貼坡道路與兩側林木；原片繞坡角的彎度不足，右坡仍近乎平牆，冠層與斑駁樹影不符。 |
| S13 | [開啟對照](../export/saisies/review/all18_v5/S13_comparison.png) | **需修正**：左岩壁及左彎存在，闊葉裸枝回歸已修復；葉片過大且冠形重複，岩壁仍平直拉伸、缺裂面與右側密冠遮擋。 |
| S14 | [開啟對照](../export/saisies/review/all18_v5/S14_comparison.png) | **需修正**：左高右低與右護欄已修正；道路過直、樹冠高度／密度與遠山開口、光影仍不符。 |
| S15 | [開啟對照](../export/saisies/review/all18_v5/S15_comparison.png) | **需修正**：左護欄右切坡側別存在；缺突出岩角及相應轉彎遮擋，平牆和重複樹形仍明顯。 |
| S16 | [開啟對照](../export/saisies/review/all18_v5/S16_comparison.png) | **需修正**：右側紅框標誌已新增；50字與上牌辨識度不足，右谷地的草地／低處屋舍及對面山體構圖仍缺。 |
| S17 | [開啟對照](../export/saisies/review/all18_v5/S17_comparison.png) | **需修正**：房屋、木棚與藍牌已移出車道且可見，屋頂懸空已修正；房型／屋頂色、綠籬、藍牌投影、出入口及山谷開口仍不符。 |
| S18 | [開啟對照](../export/saisies/review/all18_v5/S18_comparison.png) | **需修正**：保留側看方向，房屋／亭／牌群可見且屋頂接合，護欄不再橫跨支路；道路交會形狀、標線、建築尺度、牌面與後方巨大森林山體仍不符。 |

目前整體仍是可巡覽的環境雛形。主要差異集中在路線曲率／空間配置、建築專屬外觀、森林冠層尺度與分布、天然岩壁幾何，以及對面覆林山體與谷地深度。不能只靠增加物件數量或微調色值達到原片相符。

可編輯烘焙場景已更新：`export/saisies/SaisiesEnvironment_v2.scn`，約 24MB。獨立載入檢查得到 3,342 nodes、3,005 MeshInstance3D、223 MultiMeshInstance3D、1 道路碰撞形體、0 個節點腳本；headless Dummy renderer 退出仍有資源回收警告，並未列為完全乾淨的測試。該檔是最新待修版本，尚未視覺驗收通過。

地景 Luna 的最後追加回合曾因用量限制中斷；已寫入的變更仍由主代理納入本次凍結來源，重新通過 v2 山體安全走廊檢查並完成原生截圖。剩餘視覺差異如上，不宣稱已由開發者修復。


<a id="latest-v7"></a>
## 最新整合驗收｜2026-10-17｜all18_v7

本輪由Luna實作、root以原片／文字及原生畫面驗收。凍結來源完成18/18張1920×1080 Metal圖片；七項headless驗證通過，macOS憑證系統訊息另行記錄，未將它隱藏為零訊息。來源場景18次原生圖片日誌無腳本／載入／GPU錯誤。主代理已查看全部六張對照索引及重點原尺寸圖片，**0/18符合完整本幀要求，全部維持退修**。

已確認的局部修復：餐廳寬山牆朝街道、農舍四面窗面／木牆、S06坡側和低屋位置、斜坡基座及煙囪接合、葉片實際尺度與材質UV契約、遠山退出近相機道路走廊、展示相機與固定驗收pose一致。正常巡覽沿18個人工估算pose平順插值；未精密標定、沒有GPS/DEM校正。

S13原始岩面拼接方案在v6／v7預覽中仍有懸浮薄片與上緣漂浮，已拒收並撤回；本版採連續五層岩壁，天然裂面細節仍未通過。技術測試曾把少數點接觸誤當整個可見前緣接地，已移除該方案的假陽性assertion，保留拒收圖片供追查。

| ID | 原片／Godot | 最新判定與待修 |
|---|---|---|
| S01 | [開啟對照](../export/saisies/review/all18_v7/S01_comparison.png) | **需修正**：寬山牆朝向、棚柱與店面層次已有修正；餐廳比例／木陽台、旅館遮擋、右街花槽／木護欄、連續街屋與背景林山仍不符。 |
| S02 | [開啟對照](../export/saisies/review/all18_v7/S02_comparison.png) | **需修正**：植栽島未遮路、葉片尺度改善；島形與路口平面、右側木樓尺度、花槽及背景山景仍不符。 |
| S03 | [開啟對照](../export/saisies/review/all18_v7/S03_comparison.png) | **需修正**：纜索與纜椅存在；左樓過大、牌群與交會鋪面、右側設施及遠山缺乏原片的相對位置和層次。 |
| S04 | [開啟對照](../export/saisies/review/all18_v7/S04_comparison.png) | **需修正**：右高左低側別維持，仍缺影片中的連續針葉林、正確的小屋頂投影與遠山；草坡和樹群配置過簡化。 |
| S05 | [開啟對照](../export/saisies/review/all18_v7/S05_comparison.png) | **需修正**：左彎及右護欄存在，近相機灰山體穿模已移除；主山仍偏右且輪廓被截切，谷地過空，森林／草甸分區與山稜未還原。 |
| S06 | [開啟對照](../export/saisies/review/all18_v7/S06_comparison.png) | **需修正**：左高右低、木造窗面、灰屋頂及右側低屋已呈現，基座和煙囪已接合；主屋過大／過近、屋頂群不足，遠處樹群接地、坡下深度和對面林山仍不符。 |
| S07 | [開啟對照](../export/saisies/review/all18_v7/S07_comparison.png) | **需修正**：左上坡木屋、右低灰頂和地基已修正；支路平面、房屋前後層次、屋頂群、電桿與對面森林山體仍不符。 |
| S08 | [開啟對照](../export/saisies/review/all18_v7/S08_comparison.png) | **需修正**：右低護牆及左切坡側別符合部分描述，未出現天空山體穿模；左坡過平、近路樹冠不足，森林包覆與前方山景開口不符。 |
| S09 | [開啟對照](../export/saisies/review/all18_v7/S09_comparison.png) | **需修正**：左石牆／右護欄存在，柱體直立；原片右彎仍過弱，石牆分段接縫與材質尺度重複，冠層遮蔽和天然坡形不足。 |
| S10 | [開啟對照](../export/saisies/review/all18_v7/S10_comparison.png) | **需修正**：左護欄／右岩切存在，葉片尺寸及色澤已改；岩切仍像長牆，缺原片的裂面、植被和斑駁樹影，道路透視仍有差異。 |
| S11 | [開啟對照](../export/saisies/review/all18_v7/S11_comparison.png) | **需修正**：闊葉群恢復小葉且色澤改善，針闊葉可分辨；冠形與排列仍人工，右坡土岩分區、森林開口和山景不足。 |
| S12 | [開啟對照](../export/saisies/review/all18_v7/S12_comparison.png) | **需修正**：貼坡林道與兩側森林存在；彎度、右坡不規則輪廓、林冠包覆與明暗仍不符。 |
| S13 | [開啟對照](../export/saisies/review/all18_v7/S13_comparison.png) | **需修正**：彎道出口高度較接近原片、右側密冠遮擋及小葉已改善；退回漂浮岩塊方案後保留連續岩壁，天然裂面／突出岩角仍不足，樹冠排列與光影不符。 |
| S14 | [開啟對照](../export/saisies/review/all18_v7/S14_comparison.png) | **需修正**：左高右低、右護欄存在；彎道曲率、樹冠形態、林間視野和遠山輪廓仍不符。 |
| S15 | [開啟對照](../export/saisies/review/all18_v7/S15_comparison.png) | **需修正**：左護欄／右切坡側別正確；突出岩角、隨岩角繞行的彎度、自然切面和林冠遮蔭仍未還原。 |
| S16 | [開啟對照](../export/saisies/review/all18_v7/S16_comparison.png) | **需修正**：右側紅框標誌存在但葉片遮擋牌面；右谷地應有的視野、低處屋舍與對面山體不足，森林仍過於連續。 |
| S17 | [開啟對照](../export/saisies/review/all18_v7/S17_comparison.png) | **需修正**：屋、棚、藍牌已在車道外且屋頂接牆；屋型／屋頂色、綠籬及出入口、架空線和山谷開口仍不符。 |
| S18 | [開啟對照](../export/saisies/review/all18_v7/S18_comparison.png) | **需修正**：側看鏡頭、支路、屋／亭／牌群存在，護欄未橫跨入口；道路交會及標線、牌面與建築尺度、後方巨大森林山體仍不符。 |

烘焙版固定S13原生效能抽查：120幀、1920×1080，平均20.95ms（約47.7 FPS），p95 26.57ms。僅此固定視點與本機Apple M4 Pro，未宣稱全線FPS。

可編輯烘焙場景已更新為此凍結版本：約24.6 MiB，3507 nodes、3161 MeshInstance3D、229 MultiMeshInstance3D、1碰撞形體、0個節點腳本。烘焙／獨立載入日誌保存在本次review目錄；headless日誌中的平台／資源警告與原生畫面結果分開記錄。

原生讀回發現 headless／Dummy 烘焙雖有 MultiMesh 節點數量，樹木實例資料仍遺失，該產物及空森林的效能數字已拒收。最終改用 native Metal 烘焙；S13讀回的森林與來源畫面一致，平均RGB絕對差約0.56/255（僅比較Godot來源／烘焙產物，並非原片相符率）。烘焙工具新增 headless 攔截，負向測試確認輸出檔checksum不變。烘焙載入測試在退出時，Dummy及native均仍有資源回收錯誤／警告，未列為完全乾淨的測試，細節見 `artifact_validation.json` 與日誌。

剩餘主工作是原片專屬建築和街道密度、主山與谷地的整體形狀、自然林冠分布，以及天然岩面和彎道的相互遮擋；增加細節數量不能取代這些空間配置修正。

## 獨立地理場景抽驗｜2026-10-18｜round8_geo_final

新增的地理場景以公開道路與高程作空間基底，與保留 v2 分別驗收。root 已逐張查看 S01/S03/S05/S08/S09/S13 原片對照；**0/6 通過**，其他12個視點尚未對此地理版本驗收。六張原生渲染與全線斜向空照正常，六項 headless 技術檢查通過；樹木／護欄另有 native GPU transform 讀回，均不代表內容相符。

| 原片／地理場景 | 退修重點 |
|---|---|
| [S01](../export/saisies/review/round8_geo_final/S01_comparison.png) | 建物仍白模，專屬店面、木陽台、旅館遮擋與右側花槽缺失。 |
| [S03](../export/saisies/review/round8_geo_final/S03_comparison.png) | 纜椅、支柱、牌群、寬路口鋪面與花槽缺失。 |
| [S05](../export/saisies/review/round8_geo_final/S05_comparison.png) | 山谷方向初步接近；近路樹木、電桿、房屋及山形／色調不符，護欄相對路面偏低。 |
| [S08](../export/saisies/review/round8_geo_final/S08_comparison.png) | 森林路段變成開闊谷地，高左坡、稀疏樹冠、低實體護牆缺失。 |
| [S09](../export/saisies/review/round8_geo_final/S09_comparison.png) | 左石牆缺失，右彎投影、樹群與坡面不符，護欄偏低。 |
| [S13](../export/saisies/review/round8_geo_final/S13_comparison.png) | 岩壁缺失，森林成列、近路冠層不足、山谷過度暴露。 |

[全線空照](../export/saisies/review/round8_geo_final/aerial_oblique.png) 可檢查真實道路平面與山谷位置；橙色路線為暫時檢視標示。[六幀機讀報告](../export/saisies/review/round8_geo_final/visual_review.json) 保存此獨立版本判定。下一輪依 [第九輪分工](saisies_revision_round9.md) 優先修正 S08／S13 近路高程與樹冠，再驗護欄高度。


## 地理場景最新抽驗｜2026-10-18｜round9_canopy_final

root 固定來源完成 S08/S13/S05/S09 四張1920×1080 Metal截圖，**0/4通過完整本幀要求**；其他14個視點未對本輪版本重驗。七項headless技術檢查及8941棵樹／1772梁／1781柱的原生GPU定位與方向讀回通過，macOS CA訊息另記。額外FPS取樣未完成，不宣稱已驗證流暢度。

| 原片／Godot | 判定 |
|---|---|
| [S08](../export/saisies/review/round9_canopy_final/S08_comparison.png) | 近路冠層與樹影增加；仍太開闊、高左坡不符、右低護牆缺失。 |
| [S13](../export/saisies/review/round9_canopy_final/S13_comparison.png) | 右冠層遮谷改善；左岩壁缺失、彎道偏直、樹冠重複。 |
| [S05](../export/saisies/review/round9_canopy_final/S05_comparison.png) | 護欄相對柏油高度改善；左彎、房屋／電桿、主山輪廓色調仍不符。 |
| [S09](../export/saisies/review/round9_canopy_final/S09_comparison.png) | 護欄高度改善；左石牆缺失，原片開闊草坡被過密針葉樹侵占，退修林緣。 |

[機讀驗收](../export/saisies/review/round9_canopy_final/visual_review.json)、[四張對照索引](../export/saisies/review/round9_canopy_final/four_view_comparisons.jpg)、[本輪記錄](saisies_revision_round9.md)、[下一輪待修規格](saisies_revision_round10.md)。原18張影片參考及v2烘焙未變；R9維持獨立實驗場景。

## R10：2026-10-18 最新地理場景抽查

[五張原片對照](../export/saisies/review/round10_integrated/five_view_comparisons.jpg)、[逐幀判定](../export/saisies/review/round10_integrated/visual_review.json)：**0/5視覺通過**。9/9技術檢查與原生GPU接地／護欄檢查通過；岩壁、樹根及部分林緣有實作，但與原片仍有明顯差距。S12路段對應不符應先修，S08／S09護牆缺失、S13岩層人工感與林木卡面、S14森林與開口不符。詳見[本輪紀錄](saisies_revision_round10.md)、[下一包](saisies_revision_round11.md)。Luna本輪交付後遇用量上限，下一包尚未執行。

原18影格及文字不變，既有v2烘焙不變；R8空照不代表R10森林。技能案例只歸納流程，不宣稱場景重建成功。


## 第十一輪固定版（2026-10-18）

[最新五張原片對照](../export/saisies/review/round11_reviewed/five_view_comparisons.jpg)、[逐幀判定](../export/saisies/review/round11_reviewed/visual_review.json)：**0/5視覺通過**，補充326／334秒亦0/2。S09已補低石牆、草坡細節與右林遮擋，但左坡太陡、木屋缺失、樹冠與護欄外觀不符；其餘四視點仍有結構差異。7/7原生圖片、4/4本輪技術檢查及GPU檢查通過，不代表相符。正式時間錨點保留；334秒四個yaw灰模皆未解決投影問題，地理單位膨脹已排除。參見[本輪詳細紀錄](saisies_revision_round11.md)與[下一包](saisies_revision_round12.md)。
