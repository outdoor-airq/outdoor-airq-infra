# Panel teknik notlari
Bu dosya, Grafana panellerinin **neden oyle kuruldugunu** anlatir: hangi esik neye gore
secildi, hangi tuzak kasten kapatildi, hangi olcum ne zaman yapildi.

Neden ayri dosya: Grafana'daki `description` alani ℹ ikonunda gorunen KULLANICI metnidir.
Oraya bakan kisi "bu sayi ne, ne zaman endiselenmeliyim" ogrenmek ister; muhendislik
gerekcesi o metni okunmaz hale getiriyordu. Panellerdeki aciklamalar artik yalnizca sade
dil; gerekce burada.

Panel eklerken/degistirirken bu dosyayi da guncelle -- gerekcenin panelden ayri durmasinin
tek riski budur.

## outdoor-airq — Veri
`dashboards/outdoor-airq-veri.json`

### [1] Son verinin yasi
*stat*

max(measured_at) ile simdi arasindaki fark. Esikler backend /health ile ayni mantikta: 3 saati asarsa akis durmus sayilir. COALESCE(...,99999) SART: bos tabloda max() NULL doner, NULL yayilir ve panel 'No data' gosterip taban rengi olan YESILDE kalirdi -- yani /health 503 derken bu panel saglikli gorunurdu. WHERE measured_at <= now() de /health ile ayni gerekce: saati ileri kaymis tek istasyon yasi sifirlar.

### [2] Rapor veren istasyon (3 saat)
*stat*

Son 3 saatte olcum gonderen BENZERSIZ istasyon sayisi -- `stations` tablosundaki toplam degil. Fark onemli: tablo birikimlidir, satir silinmez, bu yuzden toplam sayi kapsamin daralmasini gizler. Sistem 2026-08-12'de Marmara'ya genisletilince istasyon 21'den 100'e cikti; kapsam daralirsa (or. WAQI kotasi) veri akmaya devam eder ve /health yine 'ok' der, ama BU sayi duser. Trendi asagidaki panelde.

### [4] Anomali
*stat*

Canli EMA tespitleri (aqi_anomalies). Backfill kaynakli olanlar filtered_readings'te, burada degil.

### [5] Istasyon bazinda AQI
*timeseries*

WAQI saatlik yayin yaptigi icin cizgiler saat basi kirilir; ara noktalarin olmamasi veri kaybi degil.

### [6] Her istasyonun son olcumu (son 7 gun)
*table*

7 gunluk pencere SART: zaman kosulu olmadan DISTINCT ON tum hypertable'i tarayip global siralama yapar ve panel 1 dakikada bir kosar. Tablo surekli buyudugu icin (SIM backfill'iyle 118 bin satiri gecti) sinirsiz sorgu zamanla agirlasir. 7 gun, en uzun makul veri kesintisini bile kapsar.

### [7] Kapsam trendi — saatlik rapor veren istasyon
*timeseries*

Kapsam daralmasinin gorunur oldugu tek yer. /health tazelige bakar: istasyonlarin cogu sessizce dusse bile kalan birkaci veri gonderdigi surece 'ok' der. Anlamli bir esik gecmise gore TREND ister (istasyon sayisi WAQI'ye bagli ve kendiliginden oynuyor -- 13.08 sabahi 97'den 100'e cikti, kod degismeden), o yuzden esik endpoint'e degil buraya ait. Cizgide surekli bir dusus = kapsam sorunu (WAQI kotasi, publisher hatasi, sinir kutusu degisimi).

SON 3 SAAT BILEREK HARIC. WAQI'nin ingest gecikmesi ~2 saate kadar cikiyor, yani saatlik bir kova ancak ~2 saat sonra tamamlaniyor; olculdu (13.08 07:43'te): tamamlanmis kovalar 88-89 iken dolmakta olan 06:00 kovasi 74 gosteriyordu. Dislanmasaydi grafik SUREKLI sahte bir dususle biterdi -- tam da yakalamak istedigimiz sinyalin taklidi. Bedeli: trend 3 saat gecikmeli, ki surekli kapsam daralmasini gormek icin yeterli. Anlik deger icin ustteki stat paneli.

### [8] Verinin gelme suresi — medyan (son 24 sa)
*stat*

Istasyonun olcum damgasi (measured_at) ile satirin BIZIM tabloya dustugu an (ingested_at) arasindaki fark. Zincirin tamami buna dahil: WAQI'nin kendi yayinlama gecikmesi + publisher'in 5 dakikalik cekim araligi + MQTT + Flink. BU PANEL ISLENME SURESI DEGILDIR -- zincirin paylari OLCULDU (18.08):
  WAQI'nin kendi yayinlama gecikmesi : ~40 dk'lik medyanin neredeyse tamami. Dogrudan API'ye soruldu, bizim hattimiz devre disiyken WAQI'nin verisi 60,8 dk bayatti.
  publisher cekim araligi            : 0-5 dk (POLL_SECONDS=300)
  MQTT + Flink + veritabanina yazma  : 0,0 sn. Publisher'in yayin log damgasi ile ingested_at ayni saniye cikti (6 istasyonda tekrarlandi).
Yani panel 'bizim hattimiz yavas mi' degil 'elimizdeki veri ne kadar bayat' sorusunu olcuyor; yuksek deger gorunce once WAQI'ye bakilir, hatta degil.

OLCULEN SAGLIKLI TABAN (13-16.08, kesinti oncesi): p50 34,9 dk / p90 87,5 / p95 99,8 / p99 110,6 / max 118,7. Tavanin ~2 saat olmasi dogal: WAQI degeri saat basina damgaliyor ama saat icinde yayinliyor, uzerine 5 dakikalik cekim araligi biniyor.

⚠ BU PANEL TAM DURMAYI YAKALAMAZ. Gecikme yalnizca GELEN satirlar icin hesaplanabilir; hic satir gelmezse panel kirmiziya donmez, BOSALIR. 16.08 05:00 - 18.08 06:30 arasinda WAQI ~49 saat yanit vermedi ve o donemde bu panelde hicbir veri yoktu. Tam durmanin gostergesi 'Son verinin yasi' kutusudur; burasi veri AKARKEN olusan bozulmayi gosterir (WAQI yavaslamasi, cekim araliginin buyumesi, Flink'te birikme).

Esik gerekcesi: saglikli medyan ~35 dk. 60 dk (iki kati) 'bir sey degisti' demek, 120 dk ise WAQI'nin dogal tavaninin ustu, yani gercek bir bozulma.

BASLIK NEDEN BU: iki kez degisti. Once "Yutma gecikmesi" idi -- "yutma" bizim eylemimiz oldugu icin "bizim islememiz ne kadar suruyor" diye okundu (olculdu: bizim payimiz 0,0 sn). Sonra "Gelen verinin yasi" denendi -- bu sefer kutu 1'deki "Son verinin yasi" ile karisti, cunku o SIMDIYE gore olcuyor, bu ise GELDIGI ANA gore. "Gelme suresi"nde fiilin faili verinin kendisi (veri gelir, kimse getirmez), yani kimseyi isaret etmiyor ve "yas" kelimesiyle de cakismiyor.

### [9] Verinin gelme suresi — p95 (son 24 sa)
*stat*

Istasyonun olcum damgasi (measured_at) ile satirin BIZIM tabloya dustugu an (ingested_at) arasindaki fark. Zincirin tamami buna dahil: WAQI'nin kendi yayinlama gecikmesi + publisher'in 5 dakikalik cekim araligi + MQTT + Flink. BU PANEL ISLENME SURESI DEGILDIR -- zincirin paylari OLCULDU (18.08):
  WAQI'nin kendi yayinlama gecikmesi : ~40 dk'lik medyanin neredeyse tamami. Dogrudan API'ye soruldu, bizim hattimiz devre disiyken WAQI'nin verisi 60,8 dk bayatti.
  publisher cekim araligi            : 0-5 dk (POLL_SECONDS=300)
  MQTT + Flink + veritabanina yazma  : 0,0 sn. Publisher'in yayin log damgasi ile ingested_at ayni saniye cikti (6 istasyonda tekrarlandi).
Yani panel 'bizim hattimiz yavas mi' degil 'elimizdeki veri ne kadar bayat' sorusunu olcuyor; yuksek deger gorunce once WAQI'ye bakilir, hatta degil.

OLCULEN SAGLIKLI TABAN (13-16.08, kesinti oncesi): p50 34,9 dk / p90 87,5 / p95 99,8 / p99 110,6 / max 118,7. Tavanin ~2 saat olmasi dogal: WAQI degeri saat basina damgaliyor ama saat icinde yayinliyor, uzerine 5 dakikalik cekim araligi biniyor.

⚠ BU PANEL TAM DURMAYI YAKALAMAZ. Gecikme yalnizca GELEN satirlar icin hesaplanabilir; hic satir gelmezse panel kirmiziya donmez, BOSALIR. 16.08 05:00 - 18.08 06:30 arasinda WAQI ~49 saat yanit vermedi ve o donemde bu panelde hicbir veri yoktu. Tam durmanin gostergesi 'Son verinin yasi' kutusudur; burasi veri AKARKEN olusan bozulmayi gosterir (WAQI yavaslamasi, cekim araliginin buyumesi, Flink'te birikme).

Esik gerekcesi: saglikli p95 ~100 dk ve olculmus en yuksek deger 118,7. 120 dk bu tavanin hemen ustu; 165 dk ise backend /health'in 180 dakikalik bayatlama esigine yaklastigimiz nokta, yani /health 'ok' demeyi birakmadan once uyarmis oluruz.

BASLIK NEDEN BU: iki kez degisti. Once "Yutma gecikmesi" idi -- "yutma" bizim eylemimiz oldugu icin "bizim islememiz ne kadar suruyor" diye okundu (olculdu: bizim payimiz 0,0 sn). Sonra "Gelen verinin yasi" denendi -- bu sefer kutu 1'deki "Son verinin yasi" ile karisti, cunku o SIMDIYE gore olcuyor, bu ise GELDIGI ANA gore. "Gelme suresi"nde fiilin faili verinin kendisi (veri gelir, kimse getirmez), yani kimseyi isaret etmiyor ve "yas" kelimesiyle de cakismiyor.

### [10] Verinin gelme suresi — saatlik p50 / p95
*timeseries*

Istasyonun olcum damgasi (measured_at) ile satirin BIZIM tabloya dustugu an (ingested_at) arasindaki fark. Zincirin tamami buna dahil: WAQI'nin kendi yayinlama gecikmesi + publisher'in 5 dakikalik cekim araligi + MQTT + Flink. BU PANEL ISLENME SURESI DEGILDIR -- zincirin paylari OLCULDU (18.08):
  WAQI'nin kendi yayinlama gecikmesi : ~40 dk'lik medyanin neredeyse tamami. Dogrudan API'ye soruldu, bizim hattimiz devre disiyken WAQI'nin verisi 60,8 dk bayatti.
  publisher cekim araligi            : 0-5 dk (POLL_SECONDS=300)
  MQTT + Flink + veritabanina yazma  : 0,0 sn. Publisher'in yayin log damgasi ile ingested_at ayni saniye cikti (6 istasyonda tekrarlandi).
Yani panel 'bizim hattimiz yavas mi' degil 'elimizdeki veri ne kadar bayat' sorusunu olcuyor; yuksek deger gorunce once WAQI'ye bakilir, hatta degil.

OLCULEN SAGLIKLI TABAN (13-16.08, kesinti oncesi): p50 34,9 dk / p90 87,5 / p95 99,8 / p99 110,6 / max 118,7. Tavanin ~2 saat olmasi dogal: WAQI degeri saat basina damgaliyor ama saat icinde yayinliyor, uzerine 5 dakikalik cekim araligi biniyor.

⚠ BU PANEL TAM DURMAYI YAKALAMAZ. Gecikme yalnizca GELEN satirlar icin hesaplanabilir; hic satir gelmezse panel kirmiziya donmez, BOSALIR. 16.08 05:00 - 18.08 06:30 arasinda WAQI ~49 saat yanit vermedi ve o donemde bu panelde hicbir veri yoktu. Tam durmanin gostergesi 'Son verinin yasi' kutusudur; burasi veri AKARKEN olusan bozulmayi gosterir (WAQI yavaslamasi, cekim araliginin buyumesi, Flink'te birikme).

Iki cizgi: p50 tipik durumu, p95 kuyrugu gosterir. Ikisinin ARASI acilirsa sorun genel degil belirli istasyonlardadir; ikisi BIRLIKTE yukselirse kaynak (WAQI) ya da hat genelinde yavaslama vardir. Kova ekseni ingested_at, yani 'ne zaman geldi'; measured_at kullanilsaydi gec gelen satirlar gecmise yazilir ve trend kendini geriye donuk duzeltirdi.

BASLIK NEDEN BU: iki kez degisti. Once "Yutma gecikmesi" idi -- "yutma" bizim eylemimiz oldugu icin "bizim islememiz ne kadar suruyor" diye okundu (olculdu: bizim payimiz 0,0 sn). Sonra "Gelen verinin yasi" denendi -- bu sefer kutu 1'deki "Son verinin yasi" ile karisti, cunku o SIMDIYE gore olcuyor, bu ise GELDIGI ANA gore. "Gelme suresi"nde fiilin faili verinin kendisi (veri gelir, kimse getirmez), yani kimseyi isaret etmiyor ve "yas" kelimesiyle de cakismiyor.

### [11] Verinin gelme suresi — istasyon bazinda (saatlik medyan)
*timeseries*

Ust taraftaki ozet paneller (medyan / p95) TUM istasyonlari kapsar ve secicden ETKILENMEZ -- genel resim her zaman ayakta kalsin diye. Bu iki panel ise ustteki "İstasyon" seciciye bagli: varsayilan "All", tek istasyon secilince yalnizca ona iner.

Secici ada gore degil ID'ye gore calisir. Olculdu: son 7 gunde 115 farkli istasyon ADI ama 104 farkli ID var; bazi istasyonlarin adi zaman icinde degismis. Ada gore secilseydi tek istasyon iki secenege bolunur ve ikisi de eksik veri gosterirdi.

Her istasyon bir cizgi. Tumu acikken kalabalik gorunur; lejantta bir ada tiklamak ya da ustteki seciciden istasyon secmek asil kullanim sekli. Cizgilerin BIRLIKTE yukselmesi kaynak (WAQI) kaynaklidir; TEK bir cizginin ayrilmasi o istasyona ozgudur.

BASLIK NEDEN BU: iki kez degisti. Once "Yutma gecikmesi" idi -- "yutma" bizim eylemimiz oldugu icin "bizim islememiz ne kadar suruyor" diye okundu (olculdu: bizim payimiz 0,0 sn). Sonra "Gelen verinin yasi" denendi -- bu sefer kutu 1'deki "Son verinin yasi" ile karisti, cunku o SIMDIYE gore olcuyor, bu ise GELDIGI ANA gore. "Gelme suresi"nde fiilin faili verinin kendisi (veri gelir, kimse getirmez), yani kimseyi isaret etmiyor ve "yas" kelimesiyle de cakismiyor.

### [12] Istasyon bazinda gecikme siralamasi (son 24 sa)
*table*

Ust taraftaki ozet paneller (medyan / p95) TUM istasyonlari kapsar ve secicden ETKILENMEZ -- genel resim her zaman ayakta kalsin diye. Bu iki panel ise ustteki "İstasyon" seciciye bagli: varsayilan "All", tek istasyon secilince yalnizca ona iner.

Secici ada gore degil ID'ye gore calisir. Olculdu: son 7 gunde 115 farkli istasyon ADI ama 104 farkli ID var; bazi istasyonlarin adi zaman icinde degismis. Ada gore secilseydi tek istasyon iki secenege bolunur ve ikisi de eksik veri gosterirdi.

En yavastan hizliya siralı. Hangi istasyona bakacagini bilmeden once BURAYA bakilir, sonra ustteki seciciden o istasyon secilir. "Olcum" sutunu ONEMLI: az satirli bir istasyonun p50'si guvenilmezdir (2-3 olcumun medyani tesadufe acik) ve ayrica dusuk sayi kendi basina bir sinyaldir -- o istasyon veri gondermiyor demektir.

### [13] En uzun veri boslugu (30 gun)
*stat*

Son 30 gunun en uzun kesintisi. COALESCE(...,0) SART: hic bosluk yoksa max() NULL doner, panel 'No data' gosterip taban rengi olan YESILDE kalirdi -- yani 'olculemedi' ile 'sorun yok' ayni goruntuyu verirdi (ayni tuzak panel 1'de de vardi). Bosluk = ardisik iki olcum saati arasinda 1 saatten fazla fark. Kaynak raw_readings; measured_at istasyonun kendi damgasi oldugu icin bu, WAQI'den veri GELMEDIGI donemleri gosterir. Panel zaman seciciden bagimsiz olarak son 30 gune bakar (timeFrom), cunku panonun varsayilan araligi 24 saat ve iki gunluk bir kesinti orada hic gorunmezdi. Devam eden kesintiyi de yakalamak icin seriye now()-3sa eklenir; 3 saat toleransi WAQI'nin kendi yayin gecikmesi (~40 dk medyan) yuzunden sahte bosluk uretmemek icin, ve backend /health'in bayatlama esigiyle ayni.

### [14] Bosluk sayisi (30 gun)
*stat*

Son 30 gunda kac ayri kesinti yasandi. Suresi degil ADEDI olcer: bir sure kisa ama sik tekrarlayan kesinti, tek uzun kesinti kadar onemli bir isaret olabilir (or. DNS cozumleme kararsizligi). Bosluk = ardisik iki olcum saati arasinda 1 saatten fazla fark. Kaynak raw_readings; measured_at istasyonun kendi damgasi oldugu icin bu, WAQI'den veri GELMEDIGI donemleri gosterir. Panel zaman seciciden bagimsiz olarak son 30 gune bakar (timeFrom), cunku panonun varsayilan araligi 24 saat ve iki gunluk bir kesinti orada hic gorunmezdi. Devam eden kesintiyi de yakalamak icin seriye now()-3sa eklenir; 3 saat toleransi WAQI'nin kendi yayin gecikmesi (~40 dk medyan) yuzunden sahte bosluk uretmemek icin, ve backend /health'in bayatlama esigiyle ayni.

### [15] Veri bosluklari (30 gun)
*table*

Her kesinti bir satir: en son veri ne zaman geldi, ne zaman tekrar basladi, arada kac saat gecti. En yeniden eskiye siralanir. Bosluk = ardisik iki olcum saati arasinda 1 saatten fazla fark. Kaynak raw_readings; measured_at istasyonun kendi damgasi oldugu icin bu, WAQI'den veri GELMEDIGI donemleri gosterir. Panel zaman seciciden bagimsiz olarak son 30 gune bakar (timeFrom), cunku panonun varsayilan araligi 24 saat ve iki gunluk bir kesinti orada hic gorunmezdi. Devam eden kesintiyi de yakalamak icin seriye now()-3sa eklenir; 3 saat toleransi WAQI'nin kendi yayin gecikmesi (~40 dk medyan) yuzunden sahte bosluk uretmemek icin, ve backend /health'in bayatlama esigiyle ayni.

### [16] Son anomali ne zaman

*stat*

BILEREK RENKSIZ. Bu panelin esikli/renkli olmasi yanlis bir zihinsel model kurar: anomali
CIKMAMASI iki farkli seyin gostergesi olabilir -- tespit bozuktur ya da hava sakindir --
ve bu tablo ikisini ayirt EDEMEZ. Olculdu (20.08): veri sorunsuz akarken 07.08 22:56 ->
09.08 07:18 arasi 32,4 saat ve 09.08 16:36 -> 12.08 15:35 arasi 71 saat hic anomali
cikmadi (o pencerelerde sirasiyla 649 ve 1315 olcum geldi, yani hat calisiyordu). Bir
esik konsaydi ya surekli yanlis alarm verirdi ya da (60+ saat gibi) hicbir ise yaramazdi.

COALESCE YOK -- panel 1 ve 13'ten farkli olarak burada bos sonuc DOGRU cevaptir. Oralarda
NULL "olculemedi"yi gizliyordu; burada hic anomali olmamasi gercekten bilgi yoklugu degil,
"henuz anomali yok" demek.

Tespitin calisip calismadiginin gostergesi bu panel degil, "Son verinin yasi" kutusudur:
anomali tespiti Flink job'inin icinde HER OLCUM icin satir ici kosuyor (AnomalySink.java),
yani olcum akiyorsa tespit de kosuyordur.

### [17] Son 24 saatte anomali

*stat*

Esikler olculmus dagilima gore: gunluk anomali sayisi tipik olarak 2-30 arasinda (07-19.08
gozlemi). 40 ve 70 esikleri bu bandin ustunu isaretliyor. 18.08'de 79 anomali gorulmustu ve
bunun 15'i iki gunluk kesintiden sonraki ILK TAM SAATTE cikti -- taban bayatladigi icin
normal degerler bile sapmis gorundu. Bu yuzden esikler kirmiziya degil turuncuya kadar
gidiyor: yuksek sayi "hata" degil "bak" demek.

### [18] Gunluk anomali sayisi (siddete gore)

*timeseries*

Yigilmis cubuk; severity Flink tarafinda ayriliyor (WARNING %30-50 sapma, CRITICAL %50
ustu -- olculen aralik 30,12-183,17). Renkler sabitlendi (WARNING sari, CRITICAL kirmizi)
cunku Grafana'nin otomatik seri renkleri sorgu sirasina gore degisir ve iki siddet birbirine
karisirdi.

Eksen detected_at, measured_at DEGIL: soru "ne zaman tespit ettik", "olcum ne zamandi"
degil. measured_at kullanilsaydi gec gelen satirlar gecmise yazilir ve grafik kendini geriye
donuk degistirirdi.

timeFrom 30d: panonun varsayilan araligi 24 saat, o pencerede gunluk trend gorunmez.

### [19] Istasyon bazinda anomali (son 7 gun)

*table*

Yukari/Asagi kirilimi ONEMLI ve deviation_pct'ten cikarilamaz -- o sutun ISARETSIZ (olculdu:
30,12 - 183,17, hepsi pozitif). Yon icin actual_aqi ile expected_aqi karsilastiriliyor.
Genel dagilim (20.08): 146 yukari / 90 asagi.

Yon bilgisi tani koymaya yariyor: kesinti sonrasi taban bayatlamasi tipik olarak ASAGI
sapma uretir (eski kirli ortalamaya karsi bugunun temiz havasi olculur), gercek kirlilik
olayi ise YUKARI. Tek basina kesin degil ama tabloda birlikte okununca ayirt edici.

"Son anomali" sutunu, listenin basindaki istasyonun hala mi sorun cikardigini yoksa gecmiste
mi kaldigini gosterir.

## outdoor-airq — Makine
`dashboards/outdoor-airq-makine.json`

### [1] Bos disk (/) — BU KUTU, guvenilir
*stat*

Gercek dosya sistemi okunuyor, sanallastirmadan etkilenmiyor. df -h ile dogrulandi. Docker imajlari diski sessizce doldurur (infra#4).

### [3] CPU kullanimi — PROXMOX ANA MAKINESI (bu kutu degil)
*timeseries*

node_cpu_seconds_total sanallastirilmiyor; tum fiziksel sunucuyu olcuyor. Bu kutunun kendi kullanimi icin `docker stats`. rate() ile sayacin turevi aliniyor: sayac surekli artar, anlamli olan artis hizidir.

### [4] Yuk ortalamasi — PROXMOX ANA MAKINESI (bu kutu degil)
*timeseries*

lxcfs loadavg sanallastirmasi Proxmox'ta varsayilan olarak kapali; deger tum fiziksel sunucunun yuku.
