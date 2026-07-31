import SwiftUI

/// Экран, который показывается вместо сканера, когда license.json
/// отсутствует в ресурсах таргета. Не крашит приложение — помогает
/// разработчику сориентироваться что нужно сделать.
struct NoLicenseView: View {

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.doc.fill")
                .font(.system(size: 72))
                .foregroundColor(.orange)

            VStack(spacing: 8) {
                Text("Лицензия не найдена")
                    .font(.title2.weight(.bold))

                Text("Файл license.json не обнаружен в ресурсах приложения.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 12) {
                stepRow(number: "1", text: "Получите файл license.json у команды Mergen для вашего Bundle ID.")
                stepRow(number: "2", text: "Перетащите license.json в Xcode на группу вашего таргета.")
                stepRow(number: "3", text: "В диалоге выберите «Add to target: MergenSample».")
                stepRow(number: "4", text: "Пересоберите проект — этот экран исчезнет.")
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

            Spacer()
        }
        .padding(24)
    }

    private func stepRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.subheadline.weight(.bold))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .background(Color.accentColor, in: Circle())

            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    NoLicenseView()
}
