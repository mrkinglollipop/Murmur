import ActivityKit
import SwiftUI
import WidgetKit

struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.isRecording ? "mic.fill" : "pause.fill")
                    .foregroundStyle(Color(red: 0.847, green: 0.353, blue: 0.188))
                Text(context.state.label)
                    .font(.headline)
                Spacer()
                if context.state.isRecording {
                    Text(context.state.startedAt, style: .timer)
                        .monospacedDigit()
                        .font(.headline)
                }
            }
            .padding(16)
            .activityBackgroundTint(Color.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isRecording ? "mic.fill" : "pause.fill")
                        .foregroundStyle(Color(red: 0.847, green: 0.353, blue: 0.188))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isRecording {
                        Text(context.state.startedAt, style: .timer)
                            .monospacedDigit()
                            .font(.caption.weight(.semibold))
                    } else {
                        Text(context.state.label)
                            .font(.caption.weight(.semibold))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.label)
                    .font(.subheadline.weight(.semibold))
                }
            } compactLeading: {
                Image(systemName: context.state.isRecording ? "mic.fill" : "pause.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.847, green: 0.353, blue: 0.188))
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Image(systemName: context.state.isRecording ? "mic.fill" : "pause.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.847, green: 0.353, blue: 0.188))
            }
        }
    }
}
