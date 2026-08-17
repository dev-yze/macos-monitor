import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// 马卡龙色板（鲜艳，Material 400 色阶）。
enum Macaron {
    static let sakura = Color(hex: 0xEC407A)     // 樱花粉
    static let peach = Color(hex: 0xFFA726)      // 蜜桃橙
    static let cream = Color(hex: 0xFFCA28)      // 奶油黄
    static let mint = Color(hex: 0x66BB6A)       // 薄荷绿
    static let sky = Color(hex: 0x42A5F5)        // 天空蓝
    static let lavender = Color(hex: 0xAB47BC)   // 薰衣草紫
    static let rose = Color(hex: 0xEF5350)       // 玫瑰
    static let coral = Color(hex: 0xFF7043)      // 珊瑚橙

    /// 每核使用率色阶（低 → 高）。
    static func coreUsage(_ usage: Double) -> Color {
        switch usage {
        case ..<0.5: return mint
        case ..<0.8: return cream
        default: return rose
        }
    }
}

/// 马卡龙胶囊标签（深字 + 柔和彩底，保证可读性）。
struct MacaronBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color(hex: 0x4A3B40))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.22), in: Capsule())
    }
}
