# Piko Anndea Auto Builds

[![CI](https://github.com/Hipsebek2020/piko-anndea-auto-bulids/actions/workflows/ci.yml/badge.svg)](https://github.com/Hipsebek2020/piko-anndea-auto-bulids/actions/workflows/ci.yml)

**Automatyczne buildy Twitter/X z patchami Piko + modyfikacje Anndea (Morphe) + ReVanced YouTube.**

## ✨ Główne funkcje
- Codzienne automatyczne buildy
- Patchowane APK YouTube (ReVanced / anddea)
- Twitter/X z Piko / Morphe
- Gotowe APK bez roota
- Optymalizacja rozmiaru

## 📥 Pobierz najnowsze APK
→ [Releases](https://github.com/Hipsebek2020/piko-anndea-auto-bulids/releases)

## 🚀 Budowanie

### Ręcznie na GitHub
1. Idź do **Actions**
2. Wybierz workflow **Build Modules**
3. Kliknij **Run workflow**

### Lokalnie
```bash
git clone https://github.com/Hipsebek2020/piko-anndea-auto-bulids.git
cd piko-anndea-auto-bulids
chmod +x build.sh
./build.sh
```

## ⚙️ Konfiguracja
Edytuj pliki:
- `config.toml` — główna
- `config.piko.toml` — Twitter/X
- `config.youtube.toml` — YouTube

## ⚠️ Ważne
**Keystore nie jest już w repozytorium** – dodaj własny `ks.keystore` lokalnie.

## Credits
- [crimera/piko](https://github.com/crimera/piko)
- anddea / Morphe
- j-hc (template)

## Licencja
GPL-3.0