import SwiftUI

#Preview("Verified Result") {
    StockpileResultScreenView(model: .mockVerified)
}

#Preview("Review Result") {
    StockpileResultScreenView(model: .mockReviewOnly)
}

#Preview("Review Result Narrow Demo") {
    StockpileResultScreenView(
        model: .mockReviewOnly,
        style: .presentation
    )
    .frame(width: 390, height: 844)
}

#Preview("Review Result Narrow Phone") {
    StockpileResultScreenView(
        model: .mockReviewOnly,
        style: .presentation
    )
    .frame(width: 375, height: 812)
}

#Preview("Blocked Result") {
    StockpileResultScreenView(model: .mockBlocked)
}
