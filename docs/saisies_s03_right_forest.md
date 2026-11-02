# S03 右側山坡林帶

依使用者指示略過標線，不再排入後續工作。root分析／原生驗收、Luna實作；本輪只改善右側中遠坡森林分布。來源frame1798、PTS1799798/24000（74.991583秒）；固定station930m、FOV77°、1920×1080。約80%為工作目標，沒有計算相似度分數。

第一版樹群太靠近道路，形成整齊矩形苗圃，已退修。改從既有World/Forest authored positions選擇固定相機右前方、距離450m以上的樹位作錨點，生成不規則斑塊。最終原生結果為12個anchors、374棵新樹（296針葉／78闊葉），使用6個共享MultiMesh；保留下坡草甸、小屋、道路出口與所有舊林木。原生數據為交付依據，與headless候選數量不同。

右坡超出S01局部地面快取範圍，接地改讀SaisiesGeoTerrain完整ArrayMesh的實際三角形，套用global transform、建立ROI bins並做barycentric插值。S01 overlay有有效三角形時取較高值；DEM不作接地通過依據。高落差點跳過，避免深埋。root另從顯示地形建獨立三角形快取，抽查72個經nativeGPU transform轉換的surface0 indexed木質底部點，clearance為−0.41768至−0.04000m，沒有正值。初次獨立QA曾誤把S01範圍外的最近頂點fallback當成同XZ地面而報出50m埋深，已排除fallback與不匹配XZ；退修記錄保留此診斷修正。

相機距S03中心420m內顯示新林帶，樹位生成另用2500m範圍，兩者分離。修正過擴大的camera gate及誤用430m MultiMesh距離裁切；最終MM visibility_range_end=0，由明確相機gate控制整組顯示。S03啟用、S01/S02停用，未測全程連續切換。

304個固定來源與48個資產雜湊驗證，R23既有299個來源未改。48資產包括原6關鍵資產及42樹模型／材質來源，本輪已納入launcher驗證。374個原生GPU transform全部finite、位置與records誤差0、世界垂直誤差0。完成主圖、真實2m側移及從原視點附近觀察林帶的52°近看圖，四份日誌無錯誤／警告。

S01、S02各2073600像素及S03左側x0–780/y0–600區域468000像素的OFF/ON回歸圖全部逐像素相同。原有左林、房屋及路側物件保持畫面一致。

本項改善保留，完整S03未通過。新林帶仍較原片疏、輪廓不同，部分原本規律樹列仍可見；沒有改地形與相機來強行對齊。未量測載入時間或FPS，未跑全程。下一項只處理右坡遠景屋群的位置與外觀。

對照：`export/saisies/review/round24_s03_right_forest/review.html`；詳細驗收、GPU／木根樣本、回歸及固定來源在同目錄。固定啟動：`tools/run_saisies_s03_right_forest_review.command`；`--s03-right-forest-off`顯示關閉基準。
