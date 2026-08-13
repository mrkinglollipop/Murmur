import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct DictationLiveActivity: Widget {
    private let coral = Color(red: 0.847, green: 0.353, blue: 0.188)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationAttributes.self) { context in
            HStack(alignment: .center, spacing: 16) {
                islandTitle(recording: context.state.isRecording, size: 20)
                Spacer(minLength: 8)
                islandButtons(size: 48)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .activityBackgroundTint(Color.black.opacity(0.92))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    islandTitle(recording: context.state.isRecording, size: 18)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Color.clear.frame(width: 8, height: 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    EmptyView()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Spacer()
                        islandButtons(size: 52)
                        Spacer()
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 6)
                }
            } compactLeading: {
                Image(systemName: context.state.isRecording ? "mic.fill" : "circle.fill")
                    .font(.system(size: context.state.isRecording ? 12 : 8, weight: .semibold))
                    .foregroundStyle(coral)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Image(systemName: context.state.isRecording ? "mic.fill" : "circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(coral)
            }
        }
    }

    private func islandTitle(recording: Bool, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Murmur")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
            Text(recording ? "Listening" : "On")
                .font(.system(size: size - 2, weight: .medium))
                .foregroundStyle(coral)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(recording ? "Murmur is listening" : "Murmur is on")
    }

    private func islandButtons(size: CGFloat) -> some View {
        HStack(spacing: 14) {
            Button(intent: EndSessionIntent()) {
                Image(systemName: "power")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Turn Murmur off")

            Button(intent: OpenMurmurIntent()) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: size, height: size)
                    .background(Circle().fill(.white))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Murmur")
        }
    }
}
