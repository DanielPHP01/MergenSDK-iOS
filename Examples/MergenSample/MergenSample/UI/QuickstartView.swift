//
//  QuickstartView.swift — полный минимальный флоу Mergen SDK (SwiftUI).
//
//  Сценарий: скан лицевой стороны → скан обратной стороны → верификация →
//  экран результата (или ошибки) → «Сканировать заново».
//
//  Как использовать:
//  1. Скопируйте этот файл в свой проект.
//  2. Добавьте license.json (выдаётся Mergen под ваш bundle id) в ресурсы таргета.
//  3. Добавьте NSCameraUsageDescription в Info.plist.
//  4. Покажите QuickstartView() — например, как корневой view приложения.
//
//  Требования: iOS 16+, пакет Mergen подключён через SPM (см. руководство, раздел 2).
//

import SwiftUI
import Mergen

struct QuickstartView: View {

    // ── Состояние флоу ────────────────────────────────────────────────────────
    // Простая машина из пяти шагов. SwiftUI сам пересоздаёт экраны при смене шага.
    enum Step {
        case scanFront               // открыт сканер лицевой стороны
        case scanBack                // открыт сканер обратной стороны
        case verifying               // идёт верификация (спиннер)
        case result(VerifyResult)    // итог верификации
        case error(String)           // ошибка SDK — готовый текст для пользователя
    }

    @State private var step: Step = .scanFront

    // Результат скана лицевой стороны храним до конца флоу:
    // он нужен и для verify, и для гейта поколения на обратной стороне.
    @State private var frontScan: MergenScanResult?

    // ── Лицензия ─────────────────────────────────────────────────────────────
    // MergenSDK.loadLicense() читает license.json из главного бандла.
    // Без валидной лицензии движок не инициализируется.
    private let license = MergenSDK.loadLicense() ?? ""

    var body: some View {
        Group {
            switch step {
            case .scanFront:
                scanScreen(side: .front, title: "Сканируйте лицевую сторону")
            case .scanBack:
                scanScreen(side: .back, title: "Сканируйте обратную сторону")
            case .verifying:
                verifyingScreen
            case .result(let result):
                resultScreen(result)
            case .error(let message):
                errorScreen(message)
            }
        }
        .onAppear {
            // Прогрев движка и ML-моделей — первое открытие камеры и первый
            // verify проходят без паузы на инициализацию. Повторные вызовы —
            // no-op, поэтому onAppear безопасен; в реальном приложении лучше
            // вызывать один раз в App.init (см. руководство, раздел 3.1).
            MergenSDK.preload(licenseKey: license)
        }
    }

    // ── Экран сканирования (обе стороны) ─────────────────────────────────────
    // MergenScanView — готовый камерный сканер одной стороны: камера, рамка,
    // подсказки и автозахват внутри. onResult приходит один раз на главном
    // потоке, когда сторона успешно захвачена.
    private func scanScreen(side: MIDSide, title: String) -> some View {
        ZStack {
            MergenScanView(
                side:          side,
                license:       license,
                configuration: scanConfig(side: side),
                onResult:      { scan in onScanDone(side: side, scan: scan) }
            )
            .ignoresSafeArea()

            // Небольшой баннер-подсказка сверху — какую сторону ждём.
            VStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(.top, 24)
                Spacer()
            }
        }
    }

    // Конфигурация движка. Ключевая часть — гейт стороны/поколения:
    // сканер физически не примет не ту сторону (рамка подсветит ошибку),
    // вместо того чтобы вернуть неверный результат.
    private func scanConfig(side: MIDSide) -> MergenScannerConfig {
        MergenScannerConfig {
            $0.enforceSideMatch = true      // включить гейт стороны
            $0.liveVersionProbe = true      // мгновенная реакция рамки (красная/зелёная)
            $0.scanSpeed        = .normal   // 3 кадра стабилизации — баланс скорости/надёжности
            if side == .front {
                $0.expectedSide = .front
            } else {
                $0.expectedSide = .back
                // Гейт поколения: обратная сторона обязана быть того же
                // поколения макета (2008/2017/2025), что и уже отсканированная
                // лицевая — защита от подмены стороны другим документом.
                // Если лицевая пришла без распознанного поколения — гейт
                // работает только по стороне.
                if let generation = frontScan?.generation?.rawValue {
                    $0.expectedGeneration = generation
                }
            }
        }
    }

    private func onScanDone(side: MIDSide, scan: MergenScanResult) {
        if side == .front {
            frontScan = scan
            step = .scanBack
        } else {
            guard let front = frontScan else {
                // Защита от рассинхронизации — начинаем сначала.
                step = .scanFront
                return
            }
            verify(front: front, back: scan)
        }
    }

    // ── Верификация ──────────────────────────────────────────────────────────
    // MergenSDK.verify — единственная точка входа. Для двух камерных сканов SDK
    // сначала выполняет мгновенную сверку уже распознанных данных (<1 мс) и
    // только при неубедительном итоге запускает полный OCR-прогон. Клиенту об
    // этом знать не нужно — просто передайте обе стороны.
    private func verify(front: MergenScanResult, back: MergenScanResult) {
        step = .verifying
        Task {
            do {
                let result = try await MergenSDK.verify(
                    front:   .scan(front),
                    back:    .scan(back),
                    license: license
                )
                step = .result(result)
            } catch {
                // MergenError.userMessage — готовая русская строка для показа
                // пользователю (лицензия отсутствует, движок не поднялся и т.д.).
                // Не парсите error.localizedDescription — это девелоперский текст.
                let message = (error as? MergenError)?.userMessage
                    ?? error.localizedDescription
                step = .error(message)
            }
        }
    }

    // ── Вариант с галереей ───────────────────────────────────────────────────
    // Любую сторону можно передать фотографией вместо камерного скана —
    // достаточно заменить .scan(...) на .image(...):
    //
    //     let result = try await MergenSDK.verify(
    //         front:   .image(frontPhoto),   // UIImage из галереи (MergenSideInput.image)
    //         back:    .scan(backScan),      // можно смешивать с камерными сканами
    //         license: license
    //     )
    //
    // Для выбора фото в SDK есть готовый MergenPhotoPicker (обёртка PHPicker) —
    // см. руководство, раздел «Верификация по фото».

    // ── Экран ожидания ───────────────────────────────────────────────────────
    private var verifyingScreen: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.5)
            Text("Проверка документа…")
                .font(.headline)
            Text("Обычно занимает несколько секунд")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── Экран результата ─────────────────────────────────────────────────────
    private func resultScreen(_ result: VerifyResult) -> some View {
        VStack(spacing: 20) {
            // status.isSuccess = true для .verified (MRZ подтверждён) и
            // .verifiedVisual (только визуальная сверка сторон).
            Image(systemName: result.status.isSuccess
                  ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(result.status.isSuccess ? .green : .red)

            Text(statusLabel(result.status))
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)

            // Текст вердикта от SDK (заполнен при неуспехе) — можно показывать как есть.
            if let message = result.message, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Главные значения после MRZ-сверки: номер документа и ПИН.
            // Пустая строка = поле недоступно (не распознано / нет на этой версии карты).
            VStack(alignment: .leading, spacing: 10) {
                if !result.verifyId.isEmpty {
                    fieldRow(label: "Номер документа", value: result.verifyId)
                }
                if !result.verifyPin.isEmpty {
                    fieldRow(label: "ПИН", value: result.verifyPin)
                }
                // Пер-сторонняя диагностика: что именно не так с конкретной стороной.
                if let issue = result.frontIssue {
                    fieldRow(label: "Лицевая сторона", value: issueLabel(issue, expected: "лицевая"))
                }
                if let issue = result.backIssue {
                    fieldRow(label: "Обратная сторона", value: issueLabel(issue, expected: "обратная"))
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

            Button("Сканировать заново") { restart() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    // ── Экран ошибки ─────────────────────────────────────────────────────────
    private func errorScreen(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundColor(.orange)
            Text(message)                       // уже готовый пользовательский текст
                .multilineTextAlignment(.center)
            Button("Сканировать заново") { restart() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    private func restart() {
        frontScan = nil
        step = .scanFront
    }

    // ── Строка «лейбл + значение» для экрана результата ──────────────────────
    private func fieldRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.title3, design: .monospaced).weight(.bold))
        }
    }

    // ── Локализация статусов и диагнозов ─────────────────────────────────────
    private func statusLabel(_ status: VerifyStatus) -> String {
        switch status {
        case .verified:       return "Подтверждено"
        case .verifiedVisual: return "Подтверждено (визуально, без MRZ)"
        case .failedFront:    return "Лицевая сторона не распознана"
        case .failedBack:     return "Обратная сторона не распознана"
        case .failed:         return "Не подтверждено"
        case .unknown:        return "Нет данных"
        @unknown default:     return "Нет данных"
        }
    }

    private func issueLabel(_ issue: VerifySideIssue, expected: String) -> String {
        switch issue {
        case .wrongSide:     return "Ожидается \(expected) сторона"
        case .notRecognized: return "Сторона не распознана"
        @unknown default:    return "Сторона не распознана"
        }
    }
}
