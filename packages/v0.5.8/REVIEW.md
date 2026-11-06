# TibiaSP v0.5.8 — polskie komunikaty

Zakres: tlumaczenie komunikatow pomocnika PowerShell oraz wlasnych logow Lua.
Polskie komunikaty zachowuja styl dotychczasowego launchera (ASCII).
Protokol komend, identyfikatory, odpowiedzi READY/SAVE_DONE/ERROR, klucze JSON,
warunki wykonania i wywolania Dockera pozostaja bez zmian.

Launcher WPF jest bajtowo taki sam jak w v0.5.7. Instalator zachowuje mechanizmy
backup/rollback; aktualizuje numer wersji i liste dopuszczalnych hashy.
Nie dokonano zmian danych gry ani kodu AI, staminy lub wyposazenia.

W trakcie testu v0.5.7 na Windows uzytkownik potwierdzil juz instalacje,
prawidlowy status zatrzymania, start bazy/gry z READY, logowanie i zapis
z dopasowanym SAVE_DONE. Zatrzymanie tez zakonczylo sie SAVE_DONE,
SHUTDOWN_ACCEPTED i SUKCES o 22:49:22; baza pozostala uruchomiona.
Ponowny odczyt polozenia postaci po restarcie pozostaje do sprawdzenia.

Walidacja v0.5.8: parser PowerShell; porownanie struktury AST pomocnika
(3250 wezlow bez zmian; zmienione wylacznie 74 teksty diagnostyczne);
33 testy Lua, 18 testow instalatora/rollbacku i 6 operacji integracyjnych
rzeczywistego pomocnika/Lua z atrapami uslug przeszly poprawnie.
ZIP zbudowano istniejacym kodem CI dwa razy do identycznych bajtow.
