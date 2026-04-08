# Cel Projektu

## Przegląd
Projekt **Hipsebek2020 / piko-anndea-auto-bulids** to zautomatyzowany system budowania plików APK ReVanced i Piko dla aplikacji Android.

## Główny Cel
Automatyzacja procesu budowania i aktualizacji patchowanych aplikacji Android, w szczególności:
- YouTube
- Twitter(x)

## Kluczowe Funkcje
- **Automatyczne codzienne buildy** - system automatycznie sprawdza aktualizacje i buduje nowe wersje codziennie o 16:00 UTC
- **Tylko pliki APK** - gotowe do instalacji bez potrzeby roota
- **Optymalizacja rozmiaru** - zoptymalizowane APK pod kątem rozmiaru
- **Kompatybilność** - nie wymaga roota, działa na wszystkich urządzeniach

## Technologie
- GitHub Actions do automatyzacji budowania
- Konfiguracja przez pliki TOML (config.toml, config.piko.toml, config.youtube.toml)
- Wsparcie dla budowania lokalnego (Termux, Linux)

## Repozytorium Źródłowe
Projekt jest forkiem [j-hc/revanced-magisk-module](https://github.com/j-hc/revanced-magisk-module), rozszerzonym o automatyzację buildów Piko.
