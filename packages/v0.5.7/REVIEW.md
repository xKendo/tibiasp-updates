# TibiaSP v0.5.7 — zakres poprawki i walidacja

Raport opisuje przygotowany kod i wykonane sprawdzenia. Publikację realizuje
istniejący workflow GitHub Actions; instalacja pozostaje przeznaczona dla
mechanizmu aktualizacji launchera. Nie wykonano zmian na komputerze użytkownika.

## Diagnoza

Przesłany log pokazuje zakończenie startu silnika na błędzie DNS
`Unknown MySQL server host 'database'`, przed uruchomieniem świata i obsługi
poleceń Lua. W tych uruchomieniach silnik nie mógł obsłużyć `SAVE_DONE`.
Inspekcja użytkownika wykazała `exited`, `restart=no`, `WorkDir=/app`.
Kolejny zrzut pokazał zatrzymane kontenery bazy i gry, z przypisaną wspólną
siecią `tibiasp-real860_default`. Zadanie `playerbot-setup` zakończone kodem
0 jest jednorazowym zadaniem i samo w sobie nie jest awarią.

W kodzie potwierdzono także niezależne problemy: rozpoznawanie gry po samej
nazwie na liście Docker, używanie tekstu interfejsu jako stanu, utratę części
linii logu, nieskorelowane odpowiedzi plikowe oraz bezwarunkowe przywracanie
`unless-stopped` po błędzie zamykania. Nie udowodniono, że ostatni z nich
wywołał historyczną niedostępność bazy.

## Zakres poprawki

- Trzy pliki: launcher, pomocnik PowerShell i event Lua. Wygląd WPF zachowany.
- Start wymaga istniejących kontenerów i zdrowej bazy. Nie tworzy nowej bazy,
  nie odtwarza jej kontenera i nie ponawia `playerbot-setup` ani SQL.
- Tylko zatrzymana gra może być odświeżona do już zbudowanego obrazu przez
  `compose up --no-deps --no-build --pull never --detach server` z tymczasowym
  wyłączeniem restartu. Działająca gra nie jest automatycznie restartowana.
- Gotowość eventu potwierdza `PING READY`. Każde polecenie i wynik launchera
  mają własny identyfikator. Pliki odpowiedzi są publikowane atomowo.
- Zatrzymanie wymaga potwierdzenia zapisu i poprawnego wyjścia gry; baza
  pozostaje uruchomiona. Pierwotna polityka restartu jest przywracana dopiero
  po potwierdzonej gotowości gry podczas jawnego kolejnego startu.
- Instalator sprawdza hashe znanych wersji, stan kontenera i brak aktywnej
  operacji. Wykonuje zweryfikowany backup i rollback. Rozpoznane stare pliki
  kanału są zachowane w backupie, zanim przy zatrzymanej grze zostaną wycofane
  z aktywnego kanału. Nieznane pliki lub wersje blokują instalację.

Nie zmieniono Compose, wolumenów, bazy, świata, kodu AI botów, staminy ani EQ.
Istniejące śledzone pliki repozytorium, w tym v0.5.6 i workflow, są niezmienione.

## Walidacja wykonana

- Lua: 33 testy rzeczywistego handlera w `texlua` z atrapą silnika.
- Launcher: parser i 58 asercji stanu, wyników i buforowania logów.
- Pomocnik: 23 testy izolowane w PowerShell 7.4.6.
- Instalator: 18 scenariuszy na kopiach, w tym odmowy, idempotencja,
  zmiana pliku podczas instalacji i cofanie częściowych zmian.
- Integracja: 6 operacji rzeczywistego pomocnika i Lua w osobnych procesach,
  z atrapą CLI Dockera i silnika; sprawdzono także ścieżki ze spacjami.
- Aktualizator: 42 asercje rzeczywistych funkcji i fragmentów workera,
  manifestu/ZIP-a, wywołania instalatora i obsługi wyniku. Nie uruchamiano
  głównego programu workera ani usług; ograniczenia Windows i stary błąd
  filtra nazw kontenerów zgłoszono oddzielnie od wyników pozytywnych.
- Istniejący kod CI zbudował ZIP dwa razy do identycznych bajtów. Zawartość,
  integralność ZIP i hashe payloadu są poprawne. Nie uruchomiono publikacji.

Powtarzalne sprawdzenia: `tests/save-status/run_checks.py`.

## Pozostałe sprawdzenia

Sprawdzono oba dostarczone pliki aktualizatora. Okno WPF przekazuje operacje
do `TibiaSP_UpdateWorker.ps1`. Worker sprawdza SHA-256 ZIP-a, bezpiecznie
rozpakowuje pliki, odczytuje zachowane pola `version`, `entrypoint` i
`backupFiles`, tworzy kopie i wywołuje `install.ps1 -TargetRoot` w osobnym
procesie. Sukces wymaga znacznika `TIBIASP_UPDATE_OK` oraz kodu 0, jeśli kod
jest dostępny. Dopiero potem zapisuje `installed.json`. Pakiet v0.5.7
spełnia ten kontrakt; adresu źródła ani sposobu instalacji nie zmieniono.

Istniejący worker sam rozpoznaje działającą grę po nazwie kontenera.
Instalator v0.5.7 ma dodatkową niezależną kontrolę etykiet i rzeczywistego
stanu, więc niestandardowa nazwa nie pozwala ominąć jego zabezpieczenia.
Worker nie wykonuje automatycznego rollbacku; zapewnia go nasz instalator.
Worker zawiera ścieżki i uruchamianie procesów specyficzne dla Windows.
Pełnej niezmodyfikowanej instalacji przez niego nie uruchomiono w Linuksie.
Potrzebne są jeszcze testy Windows PowerShell 5.1/WPF, Docker Desktop i
trwałości zapisu na kopii instalacji. `SAVE_DONE` potwierdza powrót z funkcji
zapisu Lua; referencyjny natywny silnik nie zgłasza przez jej wynik wszystkich
błędów zapisu danych. Test trwałości musi obejmować także dziennik silnika.

Pozostawione po błędzie `.request`/`.processing` nie są automatycznie
odtwarzane ani kasowane. Blokują kolejne polecenie do bezpiecznej diagnostyki.

Użytkownik upoważnił do automatycznej publikacji ukończonych poprawek przez
dotychczasowy workflow, bez dodatkowego pytania o akceptację każdego wydania.
