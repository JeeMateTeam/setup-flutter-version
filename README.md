# setup-flutter-version

[![Test Action](https://github.com/JeeMateTeam/setup-flutter-version/actions/workflows/test-action.yml/badge.svg?branch=dev)](https://github.com/JeeMateTeam/setup-flutter-version/actions/workflows/test-action.yml)

GitHub Action composite réutilisable qui bascule un **clone git Flutter existant** vers une version résolue via le manifest officiel. Compatible Linux, macOS et Windows (runners GitHub-hosted et self-hosted).

> Cette action **ne télécharge pas** le SDK Flutter. Elle suppose qu’un clone git est déjà présent sur le runner (image Docker, runner self-hosted, etc.).

## Prerequisites

Le SDK Flutter doit être un **clone git** (répertoire `.git` présent). Installation recommandée :

```bash
git clone https://github.com/flutter/flutter.git -b stable "${FLUTTER_ROOT}"
git -C "${FLUTTER_ROOT}" fetch --tags --force
export PATH="${FLUTTER_ROOT}/bin:${PATH}"
```

Sans clone git valide, l’action échoue avec un message explicite (pas d’installation automatique en v1).

## Usage

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6

      # Flutter doit déjà être installé en clone git sur le runner
      - uses: JeeMateTeam/setup-flutter-version@v1
        id: flutter
        with:
          version: '3.44.0'   # exact, mineure (3.44) ou majeure (3)
          channel: stable     # stable ou beta
          precache: true
          precache-platforms: android,ios,web

      - run: flutter --version
      - run: flutter pub get
```

### Exemple matrix multi-versions

```yaml
strategy:
  matrix:
  include:
    - version: '3.44.0'
      channel: stable
    - version: '3.44'
      channel: stable
    - version: '3'
      channel: stable
steps:
  - uses: JeeMateTeam/setup-flutter-version@v1
    with:
      version: ${{ matrix.version }}
      channel: ${{ matrix.channel }}
```

## Inputs

| Input | Requis | Défaut | Description |
|-------|--------|--------|-------------|
| `version` | oui | — | Version demandée : exact (`3.44.0`), mineure (`3.44` → dernier patch), majeure (`3` → dernier `3.x.x`) |
| `channel` | non | `stable` | Canal : `stable` ou `beta` |
| `flutter-root` | non | auto | Chemin du SDK si déjà installé |
| `precache` | non | `true` | Exécuter `flutter precache` après le switch |
| `precache-platforms` | non | `android,ios,web` | Plateformes à precache (filtrées selon l’OS) |

## Outputs

| Output | Description |
|--------|-------------|
| `version` | Version Flutter résolue (semver complète, ex. `3.44.0`) |
| `flutter-root` | Chemin du SDK effectivement utilisé |
| `channel` | Canal utilisé |

## Comportement

### 1. Résolution de version

Interroge le manifest officiel :

- Linux : `releases_linux.json`
- macOS : `releases_macos.json`
- Windows : `releases_windows.json`

Base URL : `https://storage.googleapis.com/flutter_infra_release/releases/` (ou `FLUTTER_STORAGE_BASE_URL`).

Filtre par canal, résout semver (exact / `X.Y` / `X`), échoue si aucune release trouvée.

### 2. Détection du SDK

Ordre de priorité :

1. Input `flutter-root` (si `bin/flutter` existe)
2. Variable `FLUTTER_ROOT`
3. `which flutter` / `where flutter` → remonte au root
4. Chemins courants : `/opt/flutter`, `%LOCALAPPDATA%\flutter`, `C:\flutter`, etc.

Validation : le SDK doit contenir un répertoire `.git`.

### 3. Bascule de version (hybride CLI + git)

| Étape | Action |
|-------|--------|
| Canal | `flutter channel <channel> --cache-artifacts=false` si nécessaire |
| Tête de canal | `flutter upgrade --force` si la version résolue est la tête du canal |
| Version pinée | `git fetch --tags --force` puis `git checkout <hash> -f` (fallback tag) |
| Sync | `flutter doctor --suppress-analytics` |
| Vérification | `flutter --version --machine` comparé à la version résolue |
| Precache | `flutter precache` avec les plateformes applicables |

> `flutter downgrade` ne accepte pas de version cible ; il n’est pas utilisé.

### 4. Precache par OS

| Plateforme | Linux | macOS | Windows |
|------------|-------|-------|---------|
| android | oui | oui | oui |
| ios | — | oui | — |
| web | oui | oui | oui |
| windows | — | — | oui |
| linux | oui | — | — |
| macos | — | oui | — |

## Self-hosted runners

- Définir `FLUTTER_ROOT` ou passer `flutter-root` explicitement
- Pour Docker : monter un volume avec un clone git persistant (`/opt/flutter`)
- L’action configure `safe.directory` pour git si nécessaire
- Idempotente : re-exécution avec la même version = no-op rapide si déjà sur le bon commit

## Troubleshooting

### « not a git clone »

Le SDK provient probablement d’une archive zip sans `.git`. Réinstallez via `git clone` (voir Prerequisites).

### Windows : « Filename too long »

```powershell
git config --system core.longpaths true
```

Installez Flutter dans un chemin court (ex. `C:\flutter`).

### Miroirs Chine

```yaml
env:
  FLUTTER_STORAGE_BASE_URL: https://storage.flutter-io.cn
```

## License

MIT — voir [LICENSE](LICENSE).
