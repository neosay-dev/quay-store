<h1 align="center">Quay Store</h1>

<p align="center">
  <b>Sideload-стор для iPhone: свои источники, подпись и установка прямо на телефоне, без компьютера.</b>
</p>

<p align="center">
  <a href="https://github.com/neosay-dev/quay-store/releases/latest"><b>Скачать</b></a> ·
  <a href="#установка"><b>Установка</b></a> ·
  <a href="#свой-источник"><b>Свой источник</b></a> ·
  <a href="https://github.com/neosay-dev/quay-store/issues"><b>Сообщить об ошибке</b></a>
</p>

<p align="center">
  <a href="https://github.com/neosay-dev/quay-store/releases/latest"><img src="https://img.shields.io/github/v/release/neosay-dev/quay-store?label=%D1%80%D0%B5%D0%BB%D0%B8%D0%B7&color=E87236" alt="Последний релиз"></a>
  <img src="https://img.shields.io/badge/iOS-16%2B-black" alt="iOS 16+">
  <a href="https://github.com/neosay-dev/quay-store/actions/workflows/ios.yml"><img src="https://github.com/neosay-dev/quay-store/actions/workflows/ios.yml/badge.svg?branch=main" alt="Сборка"></a>
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT">
</p>

## Что умеет

- **Свои источники.** Формат AltStore и SideStore (его же читают Feather и ESign). Встроенных источников нет. Ссылки `altstore://` и `sidestore://` открываются в Quay.
- **Репозитории GitHub.** Ссылка на репозиторий → его релизы с `.ipa`. За репозиторием можно следить как за источником.
- **Бесплатный Apple ID.** Подпись на 7 дней. Продление кнопкой, в фоне или действием «Обновить подписи» в «Командах». Quay продлевает и сам себя.
- **Свой сертификат.** `.p12` + `.mobileprovision`. iOS ставит приложения сама через `itms-services`, без LocalDevVPN и pairing file.
- **Pairing file без компьютера** (iOS 27+): сопряжение из Настройки → Режим разработчика. Поддержан RPPairing для iOS 26.4 и новее.
- **Несколько аккаунтов.** Apple ID и сертификаты с переключением. Сертификат Apple ID можно выгрузить в `.p12` со своим паролем.
- **Твики.** `.dylib` встраивается в приложение перед подписью и остаётся при продлении.
- **Обновления.** Находит новую версию и пересобранный файл с тем же номером (sha256, ID ассета GitHub, ETag). Уведомляет об обновлениях и о конце подписи.
- **Anisette-серверы.** Публичный список SideStore с проверкой задержки и автопереключением.
- **Прочее.** Логи установки, тема и цвет акцента, экспорт и импорт настроек.

## Установка

1. Скачай `QuayStore-<версия>.ipa` из [релизов](https://github.com/neosay-dev/quay-store/releases/latest).
2. Поставь его через iLoader, SideStore, Feather или Sideloadly.
3. Открой Quay и пройди первую настройку. Первый вопрос: есть ли у тебя свой сертификат.
   - **Свой сертификат:** выбери `.p12` и `.mobileprovision`, больше ничего не нужно.
   - **Apple ID:** понадобятся LocalDevVPN из App Store и pairing file. На iOS 27 его можно сделать прямо в Quay, на старых версиях — экспортом из iLoader.

Quay обновляет себя сам из своего источника. Его же можно добавить в SideStore или AltStore:

```
https://github.com/neosay-dev/quay-store/releases/latest/download/source.json
```

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
- `featuredApps` — что показывать в «Избранном». Сам Quay туда ничего не добавляет.
- Старый формат AltStore с `version` и `downloadURL` прямо в приложении тоже читается. Совместимость проверяется тестами на настоящих источниках AltStore, SideStore, SideStore Community и Quark.

## Как устроено

| Часть | Что внутри |
|---|---|
| `core/` | Rust: источники, GitHub, обновления, anisette, `.ipa` и твики, связь с устройством (lockdown и RPPairing), подпись, локальная раздача для `itms-services` |
| `ios/` | SwiftUI-приложение |
| `uniffi-bindgen/` | генератор Swift-обёрток ядра |
| `tools/make_source.py` | источник самого Quay Store |

Подпись и установку делают [isideload](https://github.com/nab138/isideload) и [idevice](https://github.com/jkcoxson/idevice) (обе MIT).

**Своим сертификатом** Quay ставит приложения так же, как Feather в режиме «semi-local»:
- `.ipa` раздаётся с самого телефона;
- https-манифест отдаёт сервер, по умолчанию `api.palera.in` (его можно сменить в настройках);
- серверу уходят только bundle ID, название и версия.

## Сборка

Мак не нужен: всё собирает GitHub Actions (`.github/workflows/ios.yml`).

1. Тесты Rust-ядра на Linux.
2. Ядро как статическая библиотека для iPhone.
3. Swift-обёртки (UniFFI).
4. Xcode-проект (XcodeGen) → `.ipa` без подписи.

Тег `v<версия>` выпускает релиз с `.ipa` и `source.json`.

## Лицензия

MIT
