# 地理場景房屋退步修正

2026-10-18。使用者在30km/h巡覽指出房屋與前版差異過大。root核對tour started.png、原片S01與round7_retained/S01，確認R11geo僅啟用OSM輪廓白模，未整合v2已存在的餐廳、旅館、木屋、店面及花槽。這是整合缺口，不能稱房屋已完成。

## 本輪範圍

Luna復用v2房屋幾何，新增geo village/props子類，接到共享地理Route與實際Landscape三角形；原v2與所有影片參考保留。先處理0–560m街道，保留左餐廳的大山牆、兩層店面／木陽台、後方深色低坡頂旅館、右灰頂木屋及中景村屋。暫不把v2舊chairlift位置一起搬入。

另一Luna處理GeoBuildings：用WORLDXZ實際polygon交集只排除重複OSM房屋，保留其他輪廓與來源；背景房屋補材質及基本門窗，不能整片刪除。新樹木／道路／地形／相機不在本包範圍。

## 驗收

root以R11固定源碼為基底，只覆蓋本包檔案，避免混入未完成R12時間錨點工作。先相同1920×1080拍S01、S02、S03與0m開始視角；兩版本同樣移除森林／路側設施與近路細節，這是房屋聚焦比較，不代表完整場景。確認房型與展示細節後再檢查整合版。

接地必須取實際mesh，排除重複須有交集證據。S01看左右建築、屋頂、陽台、招牌／棚線、街道遮擋；S02看村屋延伸與路口；S03查看背景建築回歸。任何比對仍不符均記退修，不以材質／窗數或技術PASS當整幀通過。

## R13 恢復基準實拍

固定來源 `/tmp/saisies_round13_houses_integrated`：R11穩定基底加6個房屋來源檔與UID，215個檔案hash及持久source_bundle已保存於 `export/saisies/review/round13_houses_integrated`。相同版本完成769地形網格村莊、實際地形＋authored-village背景房屋兩項驗證；237間背景房屋、3個有polygon交集的重複被排除，實際mesh牆／屋頂錯誤法線0/0。34份參考及78個材質hash不變，既有v2烘焙hash不變。

房屋聚焦4張與完整場景4張（S01/S02/S03/T0）都完成1920×1080原生截圖。完整圖保存於 `export/saisies/review/round13_houses_full`，原片對照及 `visual_review.json` 獨立於先前18張與R11的5張驗收紀錄。

S01餐廳、後方旅館、右木屋、陽台／招牌／花槽可辨識地恢復，未見樹穿入這些前景建物。S02左上大片空白外牆、右橘色通用兩層木屋仍錯；S03與T0也有空白背牆。已退回Luna分別處理多面外牆及Intersection_Lodge層數／廊台。完整畫面0/3通過；T0為補充巡覽視角，不另計原片驗收。

狀態：恢復基準保留，Luna細化進行中。道路投影、地形坡面、森林冠層與房屋配置仍需後續比對，不以本次細節恢復當作影片相符。


另補抽原片frame0（PTS0，24000/1001fps），PNG/hash/ffmpeg showinfo保存於恢復基準目錄 `source_T0_*`。原片0秒是向左看的餐廳近景，當前巡覽0m則正向看街道、餐廳較遠；這包含起始相機朝向／位置校正不足，不能僅靠房屋貼材質解決，本包不偷偷搬地標補償。S01原片5秒與T0不是同一個camera pose。


## R13 房屋細化固定版

`export/saisies/review/round13_houses_refined`保存第二個固定版本：R11基底＋已復原村莊，再覆蓋最後的GeoBuildings／GeoVillage及各自verifier。215個來源檔完整hash與source_bundle、實拍工具均保存。

Luna確定S02空白大牆為OSM `way/187382115`（La Lazette）。舊實作只選一面放窗，改為各合理外牆（edge≥2.5m且地面至簷高≥1.8m）至少一列窗，以公平分配限制總量，避免先到先得耗盡配額。實際窗的底／頂必須介於該面mesh地面與屋簷之間。該建物16面、48窗；另一大建物 `way/187381980` 31面、78窗。兩者高度7.0m／6.2m仍是default_estimate，外牆設計為補足背景的推估，不能當精確影片測量。

S02 `Intersection_Lodge`保留anchor333m／lateral−11.2m及原footprint，改成2.42m奶油底層＋兩個2.42m深木樓層、兩層外廊與白簷線。root審查退回了1.04m小門的尺度錯誤，最終門體2.0m、門框2.1m、底層窗1.1m，verifier直接讀BoxMesh尺寸。房屋聚焦原生probe已確認三層和外廊可見，未因此移動道路或地標。

固定版兩項headless複驗PASS，完整場景4/4原生1920×1080實拍完成且沒有未處理錯誤。root逐張看過S01/S02/S03/T0與未改動來源，保留本輪房屋細節修正；完整畫面0/3，補充T0為0/1，仍需退修。S01中景村屋／屋頂順序與森林山脊不符；S02左公寓量體、路口投影、中央低商店缺失；S03來源是纜車路口旁小咖啡館，但現station看到長直路與大型住宅，應先校正route-time與地標位置。不得僅加窗就稱房屋與影片相符。

下一包先用相鄰原片和road-only探針校正起點與村落道路投影／時間映射，再依正確視點修S02左房群和中央低店、S03咖啡館與纜車地標。成果與退修項目見 `export/saisies/review/round13_houses_refined/visual_review.json`，原片並排見各ID的 `_comparison.png`。原有18幀與R11五視點紀錄不改，另新增house_review避免覆蓋。
