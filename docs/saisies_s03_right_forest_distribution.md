# S03 右坡森林分布 · R28／S03指定範圍結案

使用者只選S03審查表第5項，其他全部略過，完成後轉S04。Luna實作、root分析與原生驗收；本輪改善保留，S03依使用者指定範圍結案，沒有宣稱整幀逐像素相似。

來源S03_f001798.png，frame1798、PTS1799798/24000、74.991583秒；固定station930m/FOV77°/1920×1080，來源未修改。

R24按screen.x排序再挑前12個錨點，讓右端空缺較大。R28繼承既有實際GeoTerrain三角形／樹根校正／MultiMesh管線，重新均衡16錨點，以不規則重疊樹群取代原374棵生成組；新版900棵、6組MultiMesh，距相機515.47..1370.23m。camera gate420m、placement range2500m、renderer end=0分開保留。原World/Forest、左林和其他場景物件不變。

原生主圖／2m側移／固定方向近看完成。林帶更連續，前緣疏密與高低不規則，保留草甸開口；最右端仍有約150px開闊坡面，密度與原片仍有差異，依約80%工作目標保留。

900個GPU原點與MultiMesh transform誤差0、直立誤差0。18棵／72個實際最低木質頂點，用未修改R24的GeoTerrain三角形採樣器獨立核對，落於地表下0.040..0.520m，抽樣無懸空。324個固定來源／48個資產雜湊通過，R27的319個來源相同。最終ON/OFF日誌無腳本錯誤；S01、S02、S04各2073600像素一致，S03左側(0,0,780,600)亦完全一致。

預檢修正OFF強制顯示舊樹的gate問題：改為requested_visible且原R24 gate啟用才顯示。修改前source保留source_bundle_gate_preflight，最終重新凍結後完成原生回歸。未量測FPS、載入時間或全程巡覽。

使用者略過：路面材質、草坡質感、左林、咖啡館朝向比例、天空光照、出口位置、低牆護欄輪廓；先前略過標線、右坡遠景屋群、遠山；現有小設施保留、露台木欄杆不再排入。除非使用者重新指定，不重開S03項目。

對照：export/saisies/review/round28_s03_right_forest_distribution/review.html；範圍：user_scope.json；驗收：acceptance.json；重驗：python3 export/saisies/review/round28_s03_right_forest_distribution/verify_evidence.py；啟動tools/run_saisies_s03_right_forest_distribution_review.command，OFF旗標--s03-right-forest-distribution-off。

已轉S04，來源與現況：export/saisies/review/round29_s04_intake/review.html。全案當前狀態見docs/saisies_scene_handoff.json。
