import SwiftUI

@main
struct MergenSampleApp: App {

    // Проверяем наличие license.json в бандле один раз при запуске.
    // Если файл не найден — показываем дружелюбный экран вместо краша.
    private let hasLicense: Bool = {
        Bundle.main.url(forResource: "license", withExtension: "json") != nil
    }()

    var body: some Scene {
        WindowGroup {
            if hasLicense {
                QuickstartView()
            } else {
                NoLicenseView()
            }
        }
    }
}
