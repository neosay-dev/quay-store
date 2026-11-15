# Quay Store

Sideload-стор для iPhone. Свои источники, подпись прямо на телефоне (бесплатный Apple ID или свой сертификат) и установка без компьютера.

- **Источники** в формате AltStore / SideStore (их же читают Feather и ESign). Встроенных нет: добавляешь свои.
- **GitHub**: ссылка на репозиторий → его релизы с `.ipa`. За репозиторием можно следить как за источником.
- **Подпись**: бесплатный Apple ID (7 дней, продление одной кнопкой или через «Команды») или свой `.p12` + `.mobileprovision`.
- **Anisette-серверы**: публичный список SideStore с проверкой задержки и автопереключением.
- **Обновления**: новая версия или тот же номер, но пересобранный файл (sha256 / ID ассета / ETag). Уведомления.
- **Первая настройка**: версия iOS, режим разработчика, LocalDevVPN, pairing file, проверка связи, вход.

## Установка

1. Скачай `QuayStore-<версия>.ipa` из [релизов](https://github.com/neosay-dev/quay-store/releases/latest).
2. Поставь его через iLoader, SideStore или Sideloadly.
3. Пройди первую настройку в приложении.

Дальше Quay обновляет себя сам из собственного источника:
`https://github.com/neosay-dev/quay-store/releases/latest/download/source.json`

## Свой источник

Файл `source.json` где угодно по HTTPS (например, `raw.githubusercontent.com`). Версии идут от новой к старой.

```json
{
  "name": "Мои приложения",
  "identifier": "com.example.source",
  "subtitle": "Порты и моды для iPhone",
  "iconURL": "https://example.com/icon.png",
  "website": "https://github.com/you",
  "tintColor": "#B9A4FF",
  "featuredApps": ["com.example.app"],
  "apps": [
    {
      "name": "App",
      "bundleIdentifier": "com.example.app",
      "developerName": "you",
      "subtitle": "Одна строка о приложении",
      "localizedDescription": "Подробное описание.",
      "iconURL": "https://example.com/app.png",
      "tintColor": "#B9A4FF",
      "category": "games",
      "screenshots": ["https://example.com/1.jpg"],
      "versions": [
        {
          "version": "1.0.1",
          "buildVersion": "12",
          "date": "2026-11-15T12:00:00Z",
          "localizedDescription": "Что нового",
          "downloadURL": "https://github.com/you/app/releases/download/v1.0.1/App-1.0.1.ipa",
          "size": 123456789,
          "sha256": "64 hex-символа",
          "minOSVersion": "16.0"
        }
      ],
      "appPermissions": {
        "entitlements": ["com.apple.developer.kernel.increased-memory-limit"],
        "privacy": { "NSCameraUsageDescription": "Зачем камера" }
      }
    }
  ],
  "news": []
}
```

- `sha256` необязателен. С ним Quay проверяет скачанный файл и точно видит пересборку с тем же номером версии.
- Без `sha256` пересборку видно по смене ссылки или размера.
- Старый формат AltStore с `version` и `downloadURL` прямо в приложении тоже читается.

## Сборка

Мак не нужен: всё собирает GitHub Actions (`.github/workflows/ios.yml`).

1. Тесты Rust-ядра на Linux.
2. Ядро как статическая библиотека для iPhone.
3. Swift-обёртки (UniFFI).
4. Xcode-проект (XcodeGen), `.ipa` без подписи.

Тег `v<версия>` выпускает релиз с `.ipa` и `source.json`.

| Часть | Что внутри |
|---|---|
| `core/` | Rust: источники, GitHub, обновления, anisette, `.ipa`, устройство, подпись |
| `ios/` | SwiftUI-приложение |
| `uniffi-bindgen/` | генератор Swift-обёрток |
| `tools/make_source.py` | источник самого Quay Store |

Подпись и установку делают [isideload](https://github.com/nab138/isideload) и [idevice](https://github.com/jkcoxson/idevice) (обе MIT).

## Лицензия

MIT
