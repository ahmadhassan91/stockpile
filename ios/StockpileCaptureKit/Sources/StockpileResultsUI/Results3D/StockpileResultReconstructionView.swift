import SceneKit
import SwiftUI
import StockpileDesignSystem

struct StockpileResultReconstructionCard: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let reconstruction: StockpileResultReconstruction
    let tone: StockpileStatusTone
    let style: StockpileResultScreenStyle

    @State private var selectedMode: StockpileResultViewerMode

    init(
        reconstruction: StockpileResultReconstruction,
        tone: StockpileStatusTone,
        style: StockpileResultScreenStyle
    ) {
        self.reconstruction = reconstruction
        self.tone = tone
        self.style = style
        _selectedMode = State(initialValue: reconstruction.defaultMode)
    }

    var body: some View {
        StockpileCard(appearance: style == .presentation ? .elevated : .outlined) {
            VStack(alignment: .leading, spacing: cardSpacing) {
                ReconstructionHeader(
                    summary: reconstruction.summary,
                    tone: tone,
                    style: style
                )

                ReconstructionModePicker(
                    selectedMode: $selectedMode,
                    modes: StockpileResultViewerMode.inspectionModes,
                    style: style
                )

                ReconstructionViewport(
                    reconstruction: reconstruction,
                    mode: selectedMode,
                    style: style
                )

                ReconstructionModeSummaryBar(
                    mode: selectedMode,
                    reconstruction: reconstruction,
                    style: style
                )

                ReconstructionMetricsGrid(
                    reconstruction: reconstruction,
                    mode: selectedMode,
                    style: style
                )
            }
        }
    }

    private var cardSpacing: CGFloat {
        switch style {
        case .presentation:
            return StockpileSpacing.small
        case .operational:
            return horizontalSizeClass == .compact ? StockpileSpacing.small : StockpileSpacing.medium
        }
    }
}

private struct ReconstructionHeader: View {
    let summary: String
    let tone: StockpileStatusTone
    let style: StockpileResultScreenStyle

    var body: some View {
        Group {
            if style == .presentation {
                VStack(alignment: .leading, spacing: StockpileSpacing.xSmall) {
                    Text("3D review")
                        .font(StockpileTypography.caption.font.weight(.semibold))
                        .foregroundStyle(tone.theme.accent.color)

                    headerText
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: StockpileSpacing.medium) {
                        headerText

                        Spacer(minLength: 0)

                        StockpileBadge("Interactive model", tone: tone)
                    }

                    VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                        headerText

                        StockpileBadge("Interactive model", tone: tone)
                    }
                }
            }
        }
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: style == .presentation ? StockpileSpacing.xxxSmall : StockpileSpacing.small) {
            Text(style == .presentation ? "Inspect the model before release" : "3D inspection")
                .font(style == .presentation ? StockpileTypography.callout.font.weight(.semibold) : StockpileTypography.sectionTitle.font)
                .foregroundStyle(StockpilePalette.ink.color)

            Text(style == .presentation ? summary : "Inspect the pile before you release, review, or recapture this run.")
                .font(StockpileTypography.callout.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)
                .fixedSize(horizontal: false, vertical: true)

            if style != .presentation {
                Text(summary)
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ReconstructionModeSummaryBar: View {
    let mode: StockpileResultViewerMode
    let reconstruction: StockpileResultReconstruction
    let style: StockpileResultScreenStyle

    var body: some View {
        let theme = mode.tone.theme

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: StockpileSpacing.medium) {
                leadingContent(theme: theme)

                Spacer(minLength: StockpileSpacing.medium)

                metricCluster(theme: theme)
            }

            VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                leadingContent(theme: theme)
                metricCluster(theme: theme, alignment: .leading)
            }
        }
        .padding(style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (style == .presentation ? StockpilePalette.surface.color.opacity(0.78) : theme.background.color.opacity(0.72)),
            in: RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
                .stroke(
                    style == .presentation ? StockpilePalette.border.color.opacity(0.55) : theme.accent.color.opacity(0.12),
                    lineWidth: 1
                )
        )
    }

    private func leadingContent(theme: StockpileStatusTheme) -> some View {
        HStack(alignment: .top, spacing: StockpileSpacing.small) {
            Image(systemName: mode.systemImage)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.accent.color)

            VStack(alignment: .leading, spacing: StockpileSpacing.xxxSmall) {
                Text(mode.title.uppercased())
                    .font(StockpileTypography.caption.font.weight(.semibold))
                    .foregroundStyle(theme.accent.color)

                Text(mode.headline)
                    .font(StockpileTypography.callout.font.weight(.semibold))
                    .foregroundStyle(StockpilePalette.ink.color)

                Text(mode.detail)
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func metricCluster(
        theme: StockpileStatusTheme,
        alignment: HorizontalAlignment = .trailing
    ) -> some View {
        VStack(alignment: alignment, spacing: StockpileSpacing.xxxSmall) {
            Text(mode.metricValue(in: reconstruction))
                .font(StockpileTypography.sectionTitle.font)
                .foregroundStyle(StockpilePalette.ink.color)

            Text(mode.metricLabel.uppercased())
                .font(StockpileTypography.caption.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)

            Text(mode.metricNote(in: reconstruction))
                .font(StockpileTypography.caption.font)
                .foregroundStyle(theme.accent.color)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ReconstructionModePicker: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var selectedMode: StockpileResultViewerMode
    let modes: [StockpileResultViewerMode]
    let style: StockpileResultScreenStyle

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: chipMinimumWidth),
                spacing: StockpileSpacing.small,
                alignment: .leading
            )
        ]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: StockpileSpacing.small) {
            ForEach(modes, id: \.self) { mode in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        selectedMode = mode
                    }
                } label: {
                    ReconstructionModeChip(
                        mode: mode,
                        isSelected: mode == selectedMode,
                        style: style
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var chipMinimumWidth: CGFloat {
        switch style {
        case .presentation:
            return 120
        case .operational:
            return horizontalSizeClass == .compact ? 120 : 136
        }
    }
}

private struct ReconstructionModeChip: View {
    let mode: StockpileResultViewerMode
    let isSelected: Bool
    let style: StockpileResultScreenStyle

    var body: some View {
        let theme = mode.tone.theme

        return HStack(spacing: StockpileSpacing.xSmall) {
            Image(systemName: mode.systemImage)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? theme.accent.color : StockpilePalette.mutedInk.color)

            Text(mode.title)
                .font(
                    style == .presentation
                        ? StockpileTypography.caption.font.weight(.semibold)
                        : StockpileTypography.callout.font.weight(.semibold)
                )
                .foregroundStyle(StockpilePalette.ink.color)
        }
        .padding(.horizontal, style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium)
        .padding(.vertical, style == .presentation ? StockpileSpacing.xSmall : StockpileSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? theme.background.color : StockpilePalette.surface.color,
            in: Capsule()
        )
        .overlay(
            Capsule()
                .stroke(
                    isSelected ? theme.accent.color.opacity(0.28) : StockpilePalette.border.color,
                    lineWidth: 1
                )
        )
    }
}

private struct ReconstructionViewport: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let reconstruction: StockpileResultReconstruction
    let mode: StockpileResultViewerMode
    let style: StockpileResultScreenStyle

    var body: some View {
        let theme = mode.tone.theme

        return VStack(alignment: .leading, spacing: style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium) {
            ZStack(alignment: .topLeading) {
                SceneView(
                    scene: StockpileResultSceneKitRenderer.makeScene(
                        reconstruction: reconstruction,
                        mode: mode
                    ),
                    options: [.allowsCameraControl, .autoenablesDefaultLighting]
                )
                .frame(height: viewportHeight)
                .clipShape(RoundedRectangle(cornerRadius: StockpileCornerRadius.card))

                LinearGradient(
                    colors: [
                        Color.clear,
                        StockpilePalette.ink.color.opacity(0.05),
                        StockpilePalette.ink.color.opacity(0.14)
                    ],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: StockpileCornerRadius.card))
                .allowsHitTesting(false)

                StockpileBadge(mode.title, tone: mode.tone)
                    .padding(style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium)
                    .allowsHitTesting(false)
            }

            viewportOverlay(theme: theme)
        }
        .background(StockpilePalette.elevatedSurface.color, in: RoundedRectangle(cornerRadius: StockpileCornerRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
                .stroke(theme.accent.color.opacity(0.16), lineWidth: 1)
        )
    }

    private var overlayInstruction: String {
        if style == .presentation {
            return "Use the mode buttons to inspect the current trust signal."
        }

        return "\(mode.title) highlights the trust signal to inspect next."
    }

    @ViewBuilder
    private func viewportOverlay(theme: StockpileStatusTheme) -> some View {
        if style == .presentation {
            HStack(alignment: .top, spacing: StockpileSpacing.small) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.accent.color)

                VStack(alignment: .leading, spacing: StockpileSpacing.xxxSmall) {
                    Text(mode.headline)
                        .font(StockpileTypography.callout.font.weight(.semibold))
                        .foregroundStyle(StockpilePalette.ink.color)

                    Text(overlayInstruction)
                        .font(StockpileTypography.caption.font)
                        .foregroundStyle(StockpilePalette.mutedInk.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(StockpileSpacing.small)
            .background(
                StockpilePalette.surface.color.opacity(0.92),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .allowsHitTesting(false)
        } else {
            VStack(alignment: .leading, spacing: StockpileSpacing.small) {
                HStack(spacing: StockpileSpacing.xSmall) {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.accent.color)

                    Text(mode.headline)
                        .font(StockpileTypography.callout.font.weight(.semibold))
                        .foregroundStyle(StockpilePalette.ink.color)
                }

                Text(overlayInstruction)
                    .font(StockpileTypography.caption.font)
                    .foregroundStyle(StockpilePalette.mutedInk.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(StockpileSpacing.medium)
            .background(
                StockpilePalette.surface.color.opacity(0.92),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .allowsHitTesting(false)
        }
    }

    private var viewportHeight: CGFloat {
        switch style {
        case .presentation:
            return horizontalSizeClass == .compact ? 228 : 252
        case .operational:
            return horizontalSizeClass == .compact ? 244 : 286
        }
    }
}

private struct ReconstructionMetricsGrid: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let reconstruction: StockpileResultReconstruction
    let mode: StockpileResultViewerMode
    let style: StockpileResultScreenStyle

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: horizontalSizeClass == .compact ? 132 : 148),
                spacing: horizontalSizeClass == .compact ? StockpileSpacing.small : StockpileSpacing.medium,
                alignment: .top
            )
        ]
    }

    private var presentationColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: horizontalSizeClass == .compact ? 108 : 120), spacing: StockpileSpacing.small, alignment: .top),
            GridItem(.flexible(minimum: horizontalSizeClass == .compact ? 108 : 120), spacing: StockpileSpacing.small, alignment: .top)
        ]
    }

    var body: some View {
        if style == .presentation {
            LazyVGrid(columns: presentationColumns, alignment: .leading, spacing: StockpileSpacing.small) {
                ReconstructionMetricTile(
                    label: "Footprint",
                    value: reconstruction.footprintLabel,
                    note: "pile base footprint",
                    style: style
                )
                ReconstructionMetricTile(
                    label: "Peak",
                    value: reconstruction.peakHeightLabel,
                    note: "highest visible point",
                    style: style
                )
                ReconstructionMetricTile(
                    label: mode.metricLabel,
                    value: mode.metricValue(in: reconstruction),
                    note: mode.metricNote(in: reconstruction),
                    style: style
                )
            }
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: StockpileSpacing.medium) {
                ReconstructionMetricTile(
                    label: "Footprint",
                    value: reconstruction.footprintLabel,
                    note: "pile base footprint",
                    style: style
                )
                ReconstructionMetricTile(
                    label: "Peak",
                    value: reconstruction.peakHeightLabel,
                    note: "highest visible point",
                    style: style
                )
                ReconstructionMetricTile(
                    label: mode.metricLabel,
                    value: mode.metricValue(in: reconstruction),
                    note: mode.metricNote(in: reconstruction),
                    style: style
                )
            }
        }
    }
}

private struct ReconstructionMetricTile: View {
    let label: String
    let value: String
    let note: String
    let style: StockpileResultScreenStyle

    var body: some View {
        VStack(alignment: .leading, spacing: StockpileSpacing.small) {
            Text(label.uppercased())
                .font(StockpileTypography.caption.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)

            Text(value)
                .font(StockpileTypography.sectionTitle.font)
                .foregroundStyle(StockpilePalette.ink.color)
                .minimumScaleFactor(0.75)

            Text(note)
                .font(StockpileTypography.callout.font)
                .foregroundStyle(StockpilePalette.mutedInk.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(style == .presentation ? StockpileSpacing.small : StockpileSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (style == .presentation ? StockpilePalette.surface.color.opacity(0.78) : StockpilePalette.surface.color),
            in: RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StockpileCornerRadius.card)
                .stroke(
                    style == .presentation ? StockpilePalette.border.color.opacity(0.55) : StockpilePalette.border.color,
                    lineWidth: 1
                )
        )
    }
}
