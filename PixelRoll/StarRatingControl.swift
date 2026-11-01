import SwiftUI

struct StarRatingControl: View {
    @Binding var rating: Int
    @Binding var rejected: Bool
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 3 : 6) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    rating = rating == value && !rejected ? 0 : value
                    if rating > 0 { rejected = false }
                } label: {
                    Image(systemName: rating >= value ? "star.fill" : "star")
                        .foregroundStyle(rating >= value ? Color.yellow : Color.secondary)
                        .font(.system(size: compact ? 15 : 21))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(value) \(value == 1 ? "star" : "stars")")
                .accessibilityValue(rating == value ? "Selected" : "")
                .help("\(value) \(value == 1 ? "star" : "stars") — click again to clear")
            }
            Divider().frame(height: 18).padding(.horizontal, 3)
            Button {
                rejected.toggle()
                if rejected { rating = 0 }
            } label: {
                Image(systemName: rejected ? "xmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(rejected ? Color.red : Color.secondary)
                    .font(.system(size: compact ? 17 : 23))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reject Photo")
            .accessibilityValue(rejected ? "Rejected" : "Not rejected")
            .help(rejected ? "Clear rejection" : "Reject photo")
        }
    }
}
