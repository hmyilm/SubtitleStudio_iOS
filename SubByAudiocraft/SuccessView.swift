import SwiftUI

// İşlem tamamlandığında gösterilen kutlama ekranı
struct SuccessView: View {
    let onNewVideo: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundColor(.green)
            }

            Text("Videon Hazır! 🎉")
                .font(.system(.title2, design: .rounded))
                .fontWeight(.bold)
                .foregroundColor(.white)

            Text("Altyazılı videon galerine kaydedildi.\nHemen paylaşabilirsin.")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            Button("Yeni Video Oluştur", action: onNewVideo)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .padding(.horizontal, 16)
        .card()
    }
}
