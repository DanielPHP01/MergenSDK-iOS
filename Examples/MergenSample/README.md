# Mergen SDK — iOS Sample

Минимальный пример интеграции Mergen SDK для сканирования удостоверений личности КР.
Демонстрирует полный флоу: скан лицевой → скан обратной → верификация → результат.

---

## Требования

- Xcode 16 или новее
- iOS Deployment Target: **16.0**
- Доступ к приватному репозиторию `github.com/DanielPHP01/MergenSDK-iOS` (git-credentials
  должны быть настроены — GitHub token в Keychain или SSH-ключ)

---

## Как открыть

1. Откройте `MergenSample.xcodeproj` в Xcode.
2. При первом открытии Xcode автоматически резолвит SPM-пакет:
   - `https://github.com/DanielPHP01/MergenSDK-iOS.git` — exact version `2.3.0`
3. Дождитесь завершения резолва (статус-бар «Fetching...»).

---

## Куда положить license.json

Файл `license.json` выдаётся командой Mergen под ваш Bundle ID (`com.mergen.sample.ios` для
этого примера, но перед распространением замените на свой идентификатор).

Шаги:
1. Перетащите `license.json` в Xcode на группу `MergenSample` (не в подпапку).
2. В диалоге убедитесь, что стоит галочка **Add to target: MergenSample**.
3. Пересоберите — приложение запустит сканер вместо экрана-инструкции.

Если файла нет — приложение показывает дружелюбный экран с пошаговой инструкцией,
а не крашится.

---

## Структура проекта

```
MergenSample/
├── App/
│   └── MergenSampleApp.swift   — @main; проверяет наличие license.json
└── UI/
    ├── QuickstartView.swift    — полный флоу сканирования и верификации
    └── NoLicenseView.swift     — экран-заглушка при отсутствии лицензии
```

---

## SPM-зависимость (информация для CLI-сборки)

SDK подключён как `XCRemoteSwiftPackageReference` в `project.pbxproj`:

```
repositoryURL = "https://github.com/DanielPHP01/MergenSDK-iOS.git"
requirement   = { kind = exactVersion; version = "2.3.0"; }
```

Для сборки из командной строки (резолв происходит автоматически при наличии прав):

```bash
xcodebuild \
  -project MergenSample.xcodeproj \
  -scheme MergenSample \
  -destination "generic/platform=iOS Simulator" \
  build
```

---

## Заметки

- `OTHER_LDFLAGS` оставлен как `$(inherited)` — SDK v2.3 статически линкует все
  зависимости внутри xcframework, явные `-l`-флаги больше не нужны.
- `NSCameraUsageDescription` прописан в build settings (`INFOPLIST_KEY_NSCameraUsageDescription`).
- `DEVELOPMENT_TEAM = M548762Z4N` — замените на свой перед отправкой в TestFlight.
