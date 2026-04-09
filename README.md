# Hipsebek2020 / piko-anndea-auto-bulids

[![CI](https://github.com/Hipsebek2020/piko-anndea-auto-bulids/actions/workflows/ci.yml/badge.svg)](https://github.com/Hipsebek2020/piko-anndea-auto-bulids/actions/workflows/ci.yml)

Zautomatyzowany system budowania plików APK ReVanced i Piko dla aplikacji Android.

## 📋 Przegląd

Projekt ten automatyzuje proces budowania i aktualizacji patchowanych aplikacji Android, w szczególności:
- **YouTube** - z patchami ReVanced
- **Twitter/X** - z patchami Morphe

## ✨ Kluczowe funkcje

- **Automatyczne codzienne buildy** - system automatycznie sprawdza aktualizacje i buduje nowe wersje codziennie o 16:00 UTC
- **Tylko pliki APK** - gotowe do instalacji bez potrzeby roota
- **Optymalizacja rozmiaru** - zoptymalizowane APK pod kątem rozmiaru
- **Kompatybilność** - nie wymaga roota, działa na wszystkich urządzeniach

## 🚀 Jak uruchomić build

### Ręczne uruchomienie budowania

Możesz ręcznie uruchomić budowanie aplikacji:

1. Przejdź do zakładki **Actions** w swoim repozytorium na GitHubie.
2. Wybierz workflow **Build Modules**.
3. Kliknij **Run workflow** i potwierdź przyciskiem **Run workflow**.

### Automatyczne buildy

Repozytorium jest skonfigurowane tak, aby automatycznie sprawdzać aktualizacje i budować nowe wersje codziennie o godzinie **16:00 UTC**.
Możesz to zmienić w pliku `.github/workflows/ci.yml`.

## ⚙️ Konfiguracja

Projekt używa plików TOML do konfiguracji budowania:

- **config.toml** - główna konfiguracja dla YouTube i Twitter/X
- **config.youtube.toml** - konfiguracja specyficzna dla YouTube
- **config.piko.toml** - konfiguracja specyficzna dla Twitter/X

Więcej informacji o konfiguracji znajdziesz w [`CONFIG.md`](./CONFIG.md).

## 🏗️ Budowanie lokalnie

### Na Termux

```bash
bash <(curl -sSf https://raw.githubusercontent.com/j-hc/revanced-magisk-module/main/build-termux.sh)
```

### Na Linux

```bash
git clone https://github.com/Hipsebek2020/piko-anndea-auto-bulids --depth 1
cd piko-anndea-auto-bulids
./build.sh
```

## 📦 Wspierane aplikacje

### YouTube (ReVanced)
- Wersja: automatyczna lub określona w config
- Architektura: arm64-v8a
- Patche: GmsCore support

### Twitter/X (Morphe)
- Wersja: automatyczna
- Architektura: arm64-v8a
- Patche: Bring back twitter

## 🔧 Funkcje

- Wsparcie dla wszystkich obecnych i przyszłych aplikacji ReVanced
- Budowanie plików APK bez roota
- Codzienne aktualizacje z najnowszymi wersjami aplikacji i patchy
- Optymalizacja APK pod kątem rozmiaru
- Obsługa Magisk i KernelSU (dla modułów)

## 📝 Źródło

Ten projekt jest forkiem [j-hc/revanced-magisk-module](https://github.com/j-hc/revanced-magisk-module), rozszerzonym o automatyzację buildów Piko.

## 📄 Licencja

Ten projekt jest objęty licencją GPL-3.0. Szczegóły znajdziesz w pliku [`LICENSE`](./LICENSE).
