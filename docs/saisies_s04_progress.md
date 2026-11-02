# 最新指示：先處理樹木分布（R33完成）

使用者最新指定樹木分布優先。本輪已完成100–120秒林帶與草甸開口單項；既有125–135秒道路待辦保留，以下歷史優先順序不覆蓋此新指示。

使用者要求彎道相似性夠高，再處理景觀，景觀以樹木分布為重點。此輪只做道路／草坡灰模與時間錨點／視角診斷，不新增樹木或其他細節。90–135秒每5秒共10張精確原片已抽取，120秒與既有S04影格pixel一致，見export/saisies/review/round30_s04_bends/source_manifest.json與bend_brief.json。連續彎序須一起驗收；不能用一張yaw或密林遮擋掩蓋錯誤彎形。

# S04 · 開闊草甸與林緣 · 已進入來源／現況核對

S03已依使用者指定範圍結案。維持root分析與原生驗收、Luna實作，一次一項，約80%即可；人物、車與HUD排除。

## 已完成起始工作

- 段落01:20–02:15；主驗收frame2877，PTS2879877/24000，119.994875秒。
- 來源video/saisies_analysis/acceptance/S04_f002877.png未修改，SHA見round29_s04_intake/source_brief.json。
- 用R28固定324來源／48資產的原生Metal擷取目前S04，FOV77°，相機(726.19196,-123.06221,-1451.10974)。既有120秒地理checkpoint約1826.886m，屬估計，沒有GPS或精確校準。
- R28右坡樹組在S04關閉，S04的ON/OFF畫面完全一致。當前圖僅為修改前基準，未對S04實作改善。

## 第一個工作

先核對道路緩彎與左右草坡大形。原片有開闊亮綠草甸、左側低屋頂／孤立針葉樹、右側上坡連續針葉林。現況彎口較偏右、路肩帶過寬，左側小屋缺少相應投影、右林形態與比例也不合。

先用便宜route-only／灰模對照檢查約105、120、135秒的時間錨點與彎序，保留S01–S03；不要先大量加樹掩蓋道路／視角問題。道路與草坡骨架確認後，再逐項做左側小屋、孤立樹、右側林緣。01:45大型白牆設施與02:15短林段，需各自相鄰影格驗收，不能宣稱本張120秒圖涵蓋全段。

原片／現況對照：export/saisies/review/round29_s04_intake/review.html；固定版與相機：capture.json；全案handoff：docs/saisies_scene_handoff.json。不要再執行歷史S03待辦，除非使用者重新指定。

## R30：彎道優先的第一輪診斷已完成

- 原片90–135秒每5秒抽取，10張完整1920×1080，120秒與既有主幀像素一致。
- Luna交付route-only探針與獨立時間候選；root用固定R28的324來源/48資產加探針快照，原生Metal擷取10張基準、10張候選及3張補充視點。日誌無SCRIPT ERROR/ERROR，尺寸全數相同。
- 相位候選改善110秒左彎、115秒右彎、125秒右彎的可見彎向，但彎口遠近與急緩仍不相符；**道路尚未視覺通過，候選禁止正式整合**。相機固定roll0/lateral0，不能當作相機校準結果。
- 正式道路、相機與S03模組未由此輪修改；live geo_scene_map另有10月18日312–346秒既有相位整合差異，保留，不混入本輪R28探針。
- 下一個單項：先校正105–115秒連彎的彎口投影與彎形，並同看100秒進彎及120秒銜接；通過後再處理125–135秒，再進樹木分布。不要先加入景觀。
- 對照：export/saisies/review/round30_s04_bends/review.html；判定/截圖hash：acceptance.json；原片PTS/hash：source_manifest.json；兩種探針固定版：probe_work_project.json、candidate_work_project.json。

## R31：105–115秒連彎視角／進彎位置修正完成

Luna新增獨立S04完整場景wrapper，保留R28全部324來源與48資產，另加4來源，共328。相機改右側車道lateral−1.6、FOV58、高度1.67、俯角−8、roll0；105秒改1435m，110秒1540m、115秒1630m。這些是視覺估計，只用於局部review，未改正式GeoRoute/global checkpoint/樹或景物。root原生7組全解析度影格包含100、105、107.5、110、112.5、115、120秒，已確認左→右彎序對齊，彎口投影比基準改善。**這只完成局部視角修正，不是S04整段彎道通過。**

root在原生場景呼叫同一controller，以60Hz步進3096步驗證30km/h走完430m，51.6秒到1770m停止，單調、停住後位移0，最大每步旋轉0.173度／位置0.143m。這是控制器連續性模擬，不是FPS量測或實時錄影。launcher `export/saisies/review/round31_s04_linked_bends/run_review.py --tour` 可執行此段原生巡覽。

相機release已改保存local position/rotation/scale，避免transform分解；首版保留在pre_release_fix。重驗S02 pixel exact；S01/S03視覺穩定，但仍有極小render/數值差，0..255平均差0.0118/0.2001，不宣稱像素完全一致。全部324基底source hash維持相同。日誌無SCRIPT ERROR/ERROR，20張native capture皆1920×1080；verification.json保存hash與量測。

下一個單項改為 **105–110秒左彎外側鋼護欄／曲線邊界**：原片右外側有明顯鋼護欄，目前缺少，會直接影響彎形的辨識。加上輪廓後再判斷是否還需改半徑／曲率，接著125–135秒，其後才進樹木分布。仍不展開新景物細節。

對照與判定：export/saisies/review/round31_s04_linked_bends/review.html、acceptance.json；固定版work_project.json/source_bundle/source_snapshot.json；來源PTS/hash在source_manifest.json。

## R32：左彎外側鋼護欄單項完成

Luna新增獨立guardrail wrapper，保留R31全部328來源／48資產，加4來源共332。右側（route-left負號）1450–1575m、柏油邊外0.45m，63段完整3D方向W護梁／43根世界Y直立柱，2個MultiMesh。柱腳取S04局部實際SaisiesGeoTerrain三角形，無DEM／錯XZ fallback；柱體在梁後外移0.10m，柱頂比梁頂低0.04m。護梁截面厚度方向深0.08m、高0.30m，灰銀霧面；僅梁面不接收陰影，以排除薄片自身陰影斑點，仍投射地面陰影。這些為場景視覺估計，不是GPS或測量尺寸。

root固定版原生Metal20張OFF/ON（7個S04＋S01–S03），最終固定相機擷取、OFF/ON位姿完全相同。全部328基底source hash不變，7張原片hash／PTS保留。GPU instance origin誤差0；柱直立誤差0；梁與路線3D方向dot最小0.999711；172個柱底角對實際可見terrain／shoulder mesh clearance−0.05393..−0.02607m，全數埋入，無浮空或採樣失敗。梁頂對獨立實際asphalt三角形0.78739..0.81347m。S01/S02/S03 OFF/ON均pixel exact。最終native無SCRIPT ERROR/ERROR或leak。

root視覺判定：105秒前方出現、107.5/110秒右外側近景延伸，方向與基本外觀符合本項約80%目標，**護欄單項通過；不等於S04整幀／彎道全段通過。** 原片camera roll與目前0仍不同，路徑、草坡、遠山與森林沒有因本輪通過而升格。下一個單項是125–135秒連彎的相位、彎口位置與轉彎幅度，完成道路後才進樹木分布。

首兩版退修分別保留pre_profile_fix（過深亮面／helper leak）、pre_post_shadow_fix（柱頭穿梁／自陰影斑點）。pre_camera_hold_capture另記capture-only修正：原控制器逐幀重寫相機造成最大1float ULP(7.63e−6m)差，最終配對時pause controller，只在換視點直接apply_video_time，未修改產品pose。

對照export/saisies/review/round32_s04_guardrail/review.html；acceptance.json為視覺判定，verification.json為技術／hash／回歸；capture.json保存native資料。run_review.py --tour可在30km/h巡覽既有100–120秒對應430m段；本輪未重新量測FPS。


## R33：100–120秒樹木分布與草甸開口單項完成

依使用者最新指示先做森林。Luna新增獨立forest wrapper、腳本/uid與JSON，共4來源；固定版336來源/48資產，全部332個R32 source hash維持相同。沿路線固定世界位置布置5區，實際845株針葉樹，3個MultiMesh：A核心400、A林緣60、B核心301、B林緣76、左坡小群8。右彎內側1575–1685m、80m內保留開口，LOD僅1200–2100m station啟用，無刪除或遮蔽舊林。路線、相機、地形、護欄和時間錨點保持R32。

root原生Metal擷取7個S04視點各OFF/ON及S01–S03回歸共20張1920×1080。原片7幀hash/PTS保留；配對相機固定且完全一致。845株全部GPU origin與直立誤差0，離獨立XZ路線中心最近24.9975m。獨立實際地形三角形抽查9株、36個surface0 indexed wood-root低點，clearance−0.17310..−0.000195m，miss0，無浮空；這是代表樣本，不是845株全根部檢驗。S01/S02/S03 OFF/ON均pixel exact；最終日誌無SCRIPT ERROR/ERROR/leak。

視覺判定：105/110秒右坡由疏樹列補成密林，115秒大草甸保留且左上草坡小群可見，120秒右側森林向前延伸。**基本分布單項依使用者約80%目標收斂通過；沒有計算相似度數字，也不表示整幀/整段S04通過。** 林緣輪廓、樹形、色調與既有林帶的接合仍有差異。原片roll與review的0不同，草坡/道路/遠山亦未由本輪升格通過。125–135秒未在此輪評核。

原生退修證據保留：pre_distribution_retune（115左群不明顯、120前方林帶不足）、pre_left_projection_fix（左群落在彎道消失點）、pre_left_distance_fix（位置正確但過近過高）。最後用只載入路線資料的固定姿態投影，選左群1710–1740m、lateral135–170m，再原生重驗。pre_snapshot_fix記錄root初次freeze漏帶腳本，已修正，不是產品錯誤。

對照：export/saisies/review/round33_s04_forest/review.html；acceptance.json為單項視覺判定，verification.json為hash/接地/GPU/回歸。run_review.py --tour可30km/h巡覽既有100–120秒430m段；本輪未量測FPS或重做載入效能。下一段先核對125–135秒連彎與森林銜接，待使用者指示，一次一項。


## R34：後段連彎相位收尾；後續改整段批次建議

使用者在開發中指出10秒一包效率不足，要求建議。root提出依完整地景段落60–120秒（密集連彎30–60秒）批次：整段來源規格、route-only骨架、整包景物、每10–15秒代表幀及彎頂/轉換點、最終一次凍結驗收。當前已發包R34先收尾，不再展開細部小修；後續範圍待使用者指示。

Luna新增4來源，共340來源/48資產；R33全部336來源hash不變。獨立controller繼承R31 pose實作，暫停既有控制器，local anchors保留100–120秒，新125/130/135=1830/1890/1950m。沒有修改道路幾何、正式checkpoint、地形或樹木。這些為時間相位視覺估計，非GPS。

root先用13個station道路探針FOV58/lateral−1.6，再補抽127.502375秒(frame3057,PTS3060057/24000)及132.507375秒(frame3177,PTS3180177/24000)，確認右彎頂→左彎序。原先1850/1920/2000候選在135秒太早變直，未選用。最終僅一次完整原生擷取22張，6個來源視點120/125/127.5/130/132.5/135秒。新相位改善125過早左彎、130/135過早直路，但130–135護欄及左側密林缺口明顯，整段場景不能通過。

30km/h控制器以60Hz模擬1296步走180m、21.6秒至1950m，單調、停止位移0，maxstep0.14248m、maxrotation0.26834度。此為連續性模擬，非FPS或實時影片。S01–S03對R33完全pixel exact。100/110/120舊新設定相同但有subpixel渲染差異，0..255平均channel delta0.08979/0.14340/0.11292，最大相機位移0.00013733m，release110平均0.18175，不宣稱pixel exact。R31 anchors恢復一致；native無SCRIPT ERROR/ERROR/leak。

對照export/saisies/review/round34_s04_late_bends/review.html；source_manifest保留6張來源PTS/hash，verification保存全部量測，acceptance分開記錄相位改善與景物缺口。建議下一批以S04整個80–135秒的林緣→入林與護欄銜接整合，一次審查，避免再每10秒開一輪。


## R35整合批次交付與全線工作範圍擴大

R35最後固定346來源/48資產，全部340個R34source hash不變。8個原片關鍵幀及22張原生OFF/ON，新增399針葉樹/3組MultiMesh，右鋼護欄1855–1942m/2組。實際GPU origin及直立誤差0；36個代表木根低點−0.14904..−0.00766m、miss0；護欄柱腳−0.04862..−0.03136m、miss0，梁頂對actualasphalt0.78823..0.81157m。柱梁方向dot至少0.998351。最終actualasphalt查詢用道路多邊形邊內0.30m，排除首版4cm查詢在彎道拼接出現2個miss；非產品修改。

最終版同process以真實delta 30km/h完整跑1030→1950m共920m，wall110.557秒、2991觀察幀、單調，停下後位移0；非FPS benchmark。S01–S03 OFF/ON pixel exact。首版pre_transition_fix保留：左近林過早、125秒護欄太近；一次整合退修左林後移40m/護欄起點+20m。

後段入林/護欄整合改善，但80–95秒高草坡/近林與source仍不同；未宣稱S04全段80%通過。使用者最新再要求加大跨度朝發行，不再逐段停審，下一包已擴為全路線release candidate，三個Luna分別森林/路側地標/整合快啟動。完整範圍與門檻見docs/saisies_release_plan.md。R35對照在export/saisies/review/round35_s04_batch/review.html；R36是最新工作目錄。
