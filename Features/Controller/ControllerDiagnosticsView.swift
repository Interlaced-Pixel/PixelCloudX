import SwiftUI

struct ControllerDiagnosticsView: View {
    @ObservedObject var service: ControllerInputService

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Controller input")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(CloudPalette.primaryText)
                    Text("Native Game Controller input detected by this Mac")
                        .font(.system(size: 13))
                        .foregroundStyle(CloudPalette.secondaryText)
                }

                Spacer()

                Button {
                    service.scanForWirelessControllers()
                } label: {
                    Label("Scan for controllers", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(QuietButtonStyle())
            }

            if service.controllers.isEmpty {
                ContentUnavailableView(
                    "No controller detected",
                    systemImage: "gamecontroller",
                    description: Text("Connect a controller over USB or Bluetooth, then scan again.")
                )
                .frame(maxWidth: .infinity, minHeight: 250)
                .background(CloudPalette.raised.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(service.controllers) { controller in
                            ControllerInputCard(controller: controller)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }

            HStack(spacing: 9) {
                Image(systemName: "info.circle")
                    .foregroundStyle(CloudPalette.accent)
                Text("Input is read locally for diagnostics. Xbox session transport is not connected.")
                    .foregroundStyle(CloudPalette.secondaryText)
            }
            .font(.system(size: 11))
        }
        .padding(26)
        .frame(minWidth: 620, minHeight: 470)
        .background(CloudPalette.panel)
    }
}

private struct ControllerInputCard: View {
    let controller: ControllerInputSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 11) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(CloudPalette.accent)
                    .frame(width: 42, height: 42)
                    .background(CloudPalette.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(CloudPalette.primaryText)
                    Text(controller.profile)
                        .font(.system(size: 11))
                        .foregroundStyle(CloudPalette.secondaryText)
                }

                Spacer()

                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CloudPalette.accent)
            }

            if controller.pressedButtons.isEmpty {
                Text("Press a button or move a stick to see live input.")
                    .font(.system(size: 11))
                    .foregroundStyle(CloudPalette.secondaryText)
            } else {
                HStack(spacing: 7) {
                    ForEach(controller.pressedButtons, id: \.self) { button in
                        Text(button)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(CloudPalette.ink)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(CloudPalette.accent, in: Capsule())
                    }
                }
            }

            HStack(spacing: 18) {
                StickReadout(title: "Left stick", state: controller.leftStick)
                StickReadout(title: "Right stick", state: controller.rightStick)
                StickReadout(title: "D-pad", state: controller.dpad)
            }

            HStack(spacing: 12) {
                TriggerReadout(title: "LT", value: controller.leftTrigger)
                TriggerReadout(title: "RT", value: controller.rightTrigger)
            }

            if !controller.otherAxes.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading) {
                    ForEach(controller.otherAxes) { axis in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(axis.name)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(CloudPalette.secondaryText)
                            Text(String(format: "%+.2f", axis.value))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(CloudPalette.primaryText)
                                .monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(17)
        .background(CloudPalette.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(CloudPalette.border, lineWidth: 1))
    }
}

private struct StickReadout: View {
    let title: String
    let state: ControllerStickState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CloudPalette.secondaryText)
            Text(String(format: "X %+.2f   Y %+.2f", state.x, state.y))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(CloudPalette.primaryText)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TriggerReadout: View {
    let title: String
    let value: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value))
                    .monospacedDigit()
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(CloudPalette.secondaryText)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(CloudPalette.border)
                    Capsule()
                        .fill(CloudPalette.accent)
                        .frame(width: geometry.size.width * CGFloat(min(max(value, 0), 1)))
                }
            }
            .frame(height: 5)
        }
    }
}
