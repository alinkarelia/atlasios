# Контракт интеграции с семейным архивом

Источник: Git `531f36191c01fd7b62f7f4da01e54ff3b89aafcd`. Пути ниже относительны корню исходников. Это описание существующего кода, не утверждение о работающем внешнем сервере. Точные валидаторы и тесты имеют приоритет над сокращёнными примерами.

## Что передавать разработчику

| Файлы | Зачем |
|---|---|
| Весь `Server/`, кроме `node_modules/`, `dist/`, `data/`, `.env` и рабочих секретов | Fastify/Node 24+, SQLite-схема v4, реальные маршруты, зависимости и тесты |
| `Server/src/app.ts`, `auth.ts`, `domain.ts`, `store.ts` | Авторизация, роли, проектная область, синхронизация метаданных и неизменяемые ревизии |
| `Server/src/materials.ts`, `Server/MATERIAL_TRANSFER.md`, `Server/test/materials.integration.test.ts` | Приём настоящих бинарных файлов, смещения, хеши, завершение и права |
| `Server/src/collaboration.ts`, `collaboration-geometry.ts`, `Server/test/collaboration.test.ts` | План, свидетельства съёмки, регистрация и жизненный цикл задания |
| `Server/test/fixtures/collaborative-swift.json` | 8 реальных экспортов синтетических Swift-планов, 182 ячейки; проверка совместимости JSON и буквального хеша границы |
| Весь `Packages/AtlasCore/` | Зависимости DTO; особенно `Domain.swift`, `FieldTransfer.swift`, `FieldTransferQueue.swift`, `FieldTransferDigest.swift`, `CollaborativeSurvey.swift`, `FragmentRegistration.swift`, `Export.swift`, `VectorMetadataExport.swift` |
| `Apps/iOS/Adapters/TeamService.swift`, `FieldTransferTransport.swift`, `FieldTransferCoordinator.swift`, `FieldTransferAssembler.swift`, `FieldDeliveryPassport.swift` | Вход, Keychain, область отправки, ручная/автоматическая очередь, подготовка настоящего комплекта |
| `Apps/iOS/Adapters/ProjectJournalExport.swift`, `CollaborativeSurveyStore.swift`, `FragmentAssemblyStore.swift`, `FragmentMeshAssemblyExporter.swift`, `NamedSourceExport.swift` | Сохранение точных журналов и исходников, локальная проверяемая производная, метаданные экспорта |
| `Apps/iOS/Adapters/Tests/FieldAssemblerChecks.swift`, `CollaborativeSurveyStoreChecks.swift`, `FragmentAssemblyChecks.swift`, `CollaborationExportChecks.swift` | Нативные проверки контрактов; это исходники проверок, не свидетельство полевой точности |
| `docs/COLLABORATIVE-MOSAIC.md`, `Server/README.md` | Возможности, ограничения, обработчик и эксплуатационная модель |

Приложение уже содержит транспорт оригинальных материалов. Автоматического сетевого обмена новыми планами/регистрациями не следует считать готовым только из наличия backend-маршрутов: нативные новые журналы сейчас можно сохранить/экспортировать/импортировать, а клиентскую синхронизацию требуется явно интегрировать.

## Авторизация и область данных

Все `/v1` операции, кроме регистрации/входа и специального старого Apple callback, используют `Authorization: Bearer <session>`. В образце сервера сессия — случайный 32-байтный токен в base64url (43 символа), в SQLite хранится его SHA256, срок — 30 дней. Права перечитываются на каждом запросе; UUID не является паролем. iOS сохраняет токен в Keychain, требует HTTPS и не пересылает bearer по редиректу на другой адрес.

Проекты в этой реализации наследуют членство **организации**; отдельной таблицы прав на каждый проект нет. Роли: `owner`, `admin`, `manager`, `surveyor`, `reviewer`, `viewer`. Создание плана/переназначение/запуск обработчика — owner/admin/manager; загрузка, свидетельства, предложения связей и создание задания — также surveyor; решение по регистрации — также reviewer. Если проект требует независимой проверки, автор предложения не может сам его одобрить. Отзыв членства немедленно блокирует доступ.

При встраивании в сайт оставьте его действующую авторизацию. Нужна явная таблица соответствия его пользователей/групп и контрактных UUID/ролей. Не принимайте выбранные телефоном `actorID`, организацию или автора загрузки за авторизованную личность. В импортированном плане `worker.id` — локальная идентичность сотрудника; `workerMappings:[{workerID,userID}]` обязана связать каждого с отдельным настоящим разрешённым аккаунтом. Прототип содержит старые необязательные billing-модули; новые collaboration-маршруты сами подписку не требуют. Не переносите старую монетизацию в бесплатный семейный архив: не подключайте commerce/IAP-маршруты и paywall. Сохраните весь исходный модуль для проверяемости комплекта, но адаптер сайта должен предоставлять бесплатные требуемые функции.

## Проекты и метаданные

- `POST /v1/auth/register`: `{email,password,displayName,organizationName}`; `POST /v1/auth/login`: `{email,password}`; `POST /v1/auth/logout`.
- `GET /v1/me`; `GET /v1/organizations`; `GET /v1/organizations/:organizationID/members`.
- `GET /v1/projects[?organizationID=UUID]`; `POST /v1/projects`: `{id?,organizationID,name,kind,coordinateReference,notes?,requiresIndependentReview?}`.
- CRS: `{wgs84:{}}` либо `{localMeters:{frameID:UUID}}`; валидатор также принимает явный `type`. Поддерживаемые `kind`: `cemetery`, `building`, `objectScan`, `site`.
- `GET /v1/projects/:projectID`; `PATCH` туда же требует `baseRevision`.
- CRUD метаданных — `features`, `tasks`, `workorders`; ревизии и синхронизация: `POST /v1/projects/:projectID/sync/push` с массивом `operations` (максимум 50), `GET .../sync/pull`. Схемы операций находятся в `domain.ts`, существующий клиент — `TeamService.swift`.

## Настоящие файлы: приём и возобновление

Все пути далее относительно `/v1/projects/:projectID`.

| Метод и путь | Запрос / смысл |
|---|---|
| `POST materials` | Полный `FieldTransferManifest` v1: `schemaVersion,id,projectID,title,createdAt,timeZoneIdentifier,utcOffsetSeconds,device?,materials[],assets[]` |
| `GET materials/:captureID` | Статус, неизменяемый манифест, `uploadedBytes` каждого файла |
| `PUT materials/:captureID/assets/:assetID?offset=N` | 1–1048576 настоящих байтов, `Content-Type: application/octet-stream` |
| `POST materials/:captureID/finalize` | `{}`; каждый физический файл проверяется по размеру/SHA256; затем `complete` |
| `GET materials?limit=100&offset=0` | Только полные комплекты; страницы до 200 |
| `GET materials/:captureID/assets/:assetID?offset=N&length=1048576` | Защищённый бинарный диапазон полного файла; весь скачанный файл нужно проверить по SHA256 |
| `DELETE materials/:captureID` | Отмена незавершённого комплекта; завершённые оригиналы неизменяемы |

`captureID` в пути материалов обозначает **ID комплекта** (`manifest.id`). В `AssemblySource.captureID` и свидетельстве съёмки это **ID исходной съёмки** (`material.sourceEntityID`). Не смешивайте эти разные значения. `asset.materialID` связывает файл с элементом `materials[]`; `asset.sha256` — хеш точных байтов, не имени файла.

Текущий код поддерживает material kind `video` и asset kind `originalVideo`; ориентируйтесь на actual enums в `materials.ts`/`FieldTransfer.swift`, если старая таблица в `MATERIAL_TRANSFER.md` их не перечисляет.

После потери ответа повторяют тот же неизменяемый комплект и получают серверное смещение. Повтор одинакового диапазона безопасен; другие байты или пропуски дают 409. Повреждённый полный хеш даёт 422 и сбрасывает один файл для повторной передачи. Только исходный загрузчик с действующими правами дописывает/финализирует незавершённый комплект; завершённый доступен разрешённым читателям проекта. Автор загрузки не доказывает авторство старой фотографии.

Пределы: JSON манифеста 1 МиБ; 1000 материалов/2048 файлов; файл 512 МиБ; комплект 1 ГиБ; 100 незавершённых комплектов на организацию. Текущая резервируемая квота файлов — по умолчанию 8 ГиБ, настраивается сервером. Это технические пределы, не платные тарифы. Большие обследования передаются несколькими комплектами. Исходники приватны; в прототипе каталоги 0700/файлы 0600. Хранилище нельзя публиковать как static web directory. Нынешние файловые блокировки рассчитаны на один процесс: для нескольких инстансов сайта нужны согласованные блокировки/транзакции или объектное хранилище.

## План, CAS и свидетельства

- `GET collaboration`: текущий план, реальные сотрудники и признак наличия обработчика.
- `POST collaboration/plan`: `{operationID,baseRevision:0,plan,workerMappings,sourceBoundaryJSON}`. `plan` — настоящий новый `CollaborativeSurveyPlan` v1, его собственная `revision=0`, свидетельства/история пусты. Серверная оболочка получает `revision=1`.
- `sourceBoundaryJSON` — **точная UTF-8 строка** исходного `FeatureGeometry`, закодированного Swift JSONEncoder с sortedKeys. Её буквальный SHA256 должен равняться `plan.sourceBoundarySHA256`. Нельзя заново сериализовать числа другим языком и подставить изменённый хеш. `serverCanonicalBoundarySHA256` — отдельный серверный хеш семантического JSON, не замена оригинального.
- Сервер заново проверяет CRS, WGS84→локальную проекцию (радиус до 5 км), полную сетку положительных площадей без отверстий, внутренние точки, крайние ячейки, компоненты и исходное распределение. Максимум 20000 ячеек, 64 сотрудника; шаг 1–500 м. Площади остаются плановыми оценками, не геодезической сертификацией.
- `POST collaboration/assignments`: `{operationID,baseRevision,cellIDs,workerID,eventID,timestamp}`.
- `POST collaboration/evidence`: `{operationID,baseRevision,evidence,source?}`. Структура evidence определена в `CollaborativeSurvey.swift`; source для съёмки: `{packageID,assetID,captureID,sourceSHA256,frameID?}`.
- `GET collaboration/plan/revisions?afterRevision=0&limit=50`; `GET collaboration/plan/revisions/:revision`; `GET collaboration/evidence?offset=0&limit=50`.

Для правки нужен **текущий номер серверной оболочки**, не самостоятельный номер локального плана. Устаревший `baseRevision` даёт 409 `revision_conflict`; повтор идентичного `operationID` не создаёт дубль; другой запрос с тем же ID — `operation_mismatch`. Текущий API добавляет свидетельства по одному; не заменяет весь накопленный план локальным JSON. Импорт старого офлайн-журнала требует явного отображения аккаунтов и согласования с текущей версией.

`gpsWalk` означает только проход; `captureObserved` требует настоящий финализированный исходник, SHA256 и явный footprint; `operatorVerified` — проверку полноты с причиной и ссылками на пригодные наблюдения. `operatorMapped` — ручное утверждение области, а `registeredCapture` из другой системы требует одобренную связь точного исходника с сеткой. Позднее пришедшее старое требование `needsRescan` не исчезает от новой даты: его нужно явно разрешить проверкой. Крайние ячейки требуют `boundaryReviewed`. Перекрытие участка коллеги разрешено, авторство сохраняется.

## Регистрация и обработчик

- `POST registrations`: `{operationID,candidate:{id,source,target,transform,controls,checkPoints,gravityConstraint?,proposedAt}}`; `GET registrations`.
- Exact source: `{packageID,assetID,captureID,frameID,sourceSHA256,sourceVersion:1,unit:"meters"}`. В этом upload-контракте поддерживается только версия ссылки 1; версия изменённого локального исходника не должна молча переписываться в 1. Нужны новые точные данные или расширение контракта.
- `transform`: `{rotation:[9 чисел по строкам],translation:{x,y,z}}`, `target=R*source+t`. Поворот правильный, без отражения/масштаба; метры должны быть установлены по происхождению данных.
- Контроль: 3–64 физических соответствия; GPS-only отклоняется. Минимальная база 0,25 м, синус треугольника 0,01; остатки fit ≤0,10 м, RMS ≤0,05 м. Минимум одна отдельная проверочная точка; её остатки ≤0,15 м/RMS ≤0,10 м. При известных вертикалях можно проверить гравитацию, предел до 5°. Операторское одобрение отдельно; числа не устанавливают абсолютную точность датчика.
- `POST registrations/:registrationID/decisions`: `{operationID,baseRevision,verdict:"approved"|"rejected",note}`.
- `POST assemblies`: `{operationID,id,kind,sources,target}`, `kind`: `registeredScene|orthomosaic|photoTour`. 1–128 точных источников; target — один из них; все комплекты завершены.
- `GET assemblies`; `GET assemblies/:jobID`; `POST assemblies/:jobID/refresh` и `/process`: `{operationID,baseRevision}`.

Проверяется связность графа и противоречие циклов (>0,15 м переноса/>1° поворота). Общий projectID или соседние GPS-координаты не дают общего frameID. Состояния задания: `queued`, `running`, `waitingForRegistration`, `ready`, `failed`. Одобрение, отозванное во время обработки, блокирует ready; после обработки позднее изменение связей показывается как `resultReviewRequired`.

Действующий обработчик внедряется **серверным кодом** через `buildApp({assemblyProcessor})`; `src/index.ts` его по умолчанию не устанавливает. Задание может стоять queued с `processor_unconfigured`, но `/process` без адаптера возвращает 503. `readyForProcessor` — готовность привязки, не готовая мозаика и не доказательство покрытия всего участка.

`AssemblyProcessor.process(context)` обязан полностью прочитать **каждый** источник через `context.readSource(source)` (поток до 1 МиБ, проверка настоящего SHA256). Ответ: `{outputSources,sourceManifestHashes,targetFrameID,method}`. Производные — отдельные финализированные приватные комплекты того же проекта в целевой системе; их физические байты повторно проверяются. Отсутствующие/подменённые файлы, только текст ИИ или непроверенная ссылка не дают ready. При аварии сохраняется failed и история попыток; оригиналы неизменны.

Эта рамка не содержит автоматической фотограмметрии/ICP, x0-воркера или готового сайта. Для x0 сначала установить реально поддерживаемые RGB/depth/pose/mesh-входы, единицы, результаты, ограничения памяти и модель ошибок. Секрет API — только серверная переменная/секретное хранилище. Телефон использует личный токен сотрудника.

## Часы и экспорт

| Контракт | Время |
|---|---|
| `FieldTransferJSON` / manifest / GeoTag | Целые миллисекунды Unix epoch |
| Локальные `team-plan.json`, `assembly.json`; DTO evidence/assignment.timestamp | Foundation Date: секунды с 2001-01-01T00:00:00Z |
| API registration.proposedAt | Целые миллисекунды Unix epoch |
| Серверные createdAt/updatedAt регистраций, планов, задач | ISO UTC строки |

Сохраните `capturedAt`, `endedAt`, `importedAt`, серверное получение отдельно; неизвестное время/точность/система остаются неизвестными. Локальные журналы находятся в `Captures/Collaboration/<projectUUID>.team-plan.json` и `.assembly.json`. `ProjectJournalExport.swift` добавляет точные байты, пути и SHA256 в экспортный паспорт/assistant-index. Учтите, что ссылки на файл коллеги могут присутствовать без самого файла: перед обработкой нужно получить и проверить соответствующий оригинал.

## Проверка интеграции

Исходная подтверждённая база: `npm ci`, `npm run check`, `npm test` в `Server/` на Node 24+: **84/84**, включая 18 новых collaboration-проверок. Это локальная серверная проверка. После переноса нужны отдельные проверки действующей авторизации сайта, изоляции проектов, повторов/обрыва передачи, сохранения метаданных, CAS, неверных хешей, отсутствующего обработчика и настоящих производных. Для Git-коммита этого комплекта также прошла полная CI [38414711616](https://github.com/alinkarelia/atlasios/actions/runs/38414711616): все 6 заданий, по 18 UI-тестов на iOS 18.5/26.2. Ручная проверка 72 изображений ещё ожидается; выпуск 0.7 пока не опубликован. Полевые измерения и работа пяти реальных телефонов этими проверками не подтверждены.
